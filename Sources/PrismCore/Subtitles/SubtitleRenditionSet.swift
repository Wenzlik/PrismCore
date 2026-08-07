import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Every WebVTT subtitle rendition of one remux session: the embedded text
/// subtitle streams the demuxer already sees (and until phase 6 dropped) plus
/// any external files the host registered, each segmented onto the video's own
/// segment boundaries by a `WebVTTRenditionWriter`.
///
/// Owned by `HLSRemuxer` (it has the demuxer and the cut points) but reachable
/// from `PrismCoreSession`, which registers externals before `start()` and
/// reads `renditions` afterwards to sign the master playlist. The two touch it
/// from different threads, hence the lock — kept to the rendition list and the
/// registration list, the only state that crosses.
///
/// Bitmap subtitles (PGS / DVB / DVD) become renditions too, through on-device
/// OCR (`BitmapSubtitleDecoder` + `SubtitleOCR`) — lossy by design, but the
/// only form that rides PiP, AirPlay and the system menu. They stay reported
/// by `SourceProbe` as host-only so a host that wants pixel-accurate rendering
/// can still draw them itself; on a platform without Vision they are host-only
/// in practice as well.
final class SubtitleRenditionSet: @unchecked Sendable {

    /// Text subtitle codecs whose packets convert to WebVTT cues.
    /// `SourceProbe` classifies against the same set so the probe's verdict and
    /// the remuxer's behaviour can't drift.
    static let textCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_SUBRIP, AV_CODEC_ID_TEXT, AV_CODEC_ID_ASS, AV_CODEC_ID_SSA,
        AV_CODEC_ID_WEBVTT, AV_CODEC_ID_MOV_TEXT,
    ]

    /// Bitmap subtitle codecs, surfaced by the probe for the host overlay.
    /// Teletext lives here too — it decodes through libzvbi, which this build
    /// has no reason to carry.
    static let bitmapCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_HDMV_PGS_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE,
        AV_CODEC_ID_DVD_SUBTITLE, AV_CODEC_ID_XSUB, AV_CODEC_ID_DVB_TELETEXT,
    ]

    /// The bitmap codecs that additionally become OCR-fed renditions when the
    /// platform has Vision: the three with decoders in this build and real
    /// occurrence in libraries. XSUB is decodable but effectively extinct;
    /// teletext has no decoder here.
    static let ocrCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_HDMV_PGS_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE,
        AV_CODEC_ID_DVD_SUBTITLE,
    ]

    /// An external subtitle file the host registered before `start()`.
    struct ExternalFile {
        let url: URL
        let language: String?
        let name: String?
        let isForced: Bool
    }

    /// One rendition being produced.
    private struct Track {
        enum Converter {
            /// Text packets → cue text, directly.
            case text(TextSubtitleConverter.Kind)
            /// Bitmap packets → composition → OCR → cue text. Class-typed:
            /// the pending-cue lifecycle is mutable state.
            case bitmap(BitmapRenditionTrack)
            /// External file, converted up front — `ingest` never sees it.
            case preloaded
        }

        /// Input stream index, or `nil` for an external file.
        let inputIndex: Int32?
        /// Source time base, for packet timestamps (`nil` for externals: their
        /// cues are already in seconds).
        let timeBase: AVRational?
        let converter: Converter
        let writer: WebVTTRenditionWriter
    }

    /// The pending-cue lifecycle of one OCR-fed bitmap rendition.
    ///
    /// Bitmap subtitles are *event* streams: a composition appears at its own
    /// time and stays up until the stream says otherwise — an explicit end
    /// (DVD), the next composition, or a clear event (PGS's way). A cue can
    /// therefore only be written once its end is known, so exactly one sits
    /// open here between events. Segment flushes split it at the boundary
    /// (the tail re-opens into the next segment) so a long-standing
    /// composition can't outrun the playlist, and `maximumCueSeconds` caps a
    /// stream whose clear never comes.
    final class BitmapRenditionTrack {
        static let maximumCueSeconds = 10.0

        /// `nil` only in tests, which feed `process(_:)` directly.
        private let decoder: BitmapSubtitleDecoder?
        private let language: String?
        /// Injectable so the pending-cue lifecycle is testable without Vision
        /// in the loop; production is always `SubtitleOCR.recognize`.
        private let recognize: (CGImage, String?) -> String?
        private var pending: SubtitleCue?

        init(
            decoder: BitmapSubtitleDecoder?,
            language: String?,
            recognize: @escaping (CGImage, String?) -> String? = SubtitleOCR.recognize
        ) {
            self.decoder = decoder
            self.language = language
            self.recognize = recognize
        }

        /// Decode one packet; returns every cue whose end became known.
        func ingest(_ packet: UnsafeMutablePointer<AVPacket>) -> [SubtitleCue] {
            guard let decoder else { return [] }
            return process(decoder.decode(packet))
        }

        /// The pending-cue lifecycle itself, decoder-independent.
        func process(_ events: [BitmapSubtitleDecoder.Event]) -> [SubtitleCue] {
            var closed: [SubtitleCue] = []
            for event in events {
                if let open = pending {
                    // Whatever this event is, it ends what was showing.
                    closed.append(open.ending(at: min(event.startSeconds, open.start + Self.maximumCueSeconds)))
                    pending = nil
                }
                guard let image = event.image else { continue }
                // Recognition happens here, on the remux read loop — tens of
                // milliseconds per event, and events are sparse (a couple per
                // segment). A track whose composition defeats the recognizer
                // simply produces no cue.
                guard let text = recognize(image, language) else { continue }
                if let end = event.endSeconds {
                    closed.append(SubtitleCue(start: event.startSeconds, end: end, text: text))
                } else {
                    pending = SubtitleCue(
                        start: event.startSeconds,
                        end: event.startSeconds + Self.maximumCueSeconds,
                        text: text
                    )
                }
            }
            return closed
        }

        /// A segment boundary: the open cue is split — its first part becomes
        /// writable, its tail re-opens at the boundary so the next segment
        /// repeats it (standard segmented-VTT behaviour for spanning cues).
        func splitPending(at boundary: Double) -> SubtitleCue? {
            guard let open = pending, open.start < boundary else { return nil }
            let cappedEnd = min(boundary, open.start + Self.maximumCueSeconds)
            let head = open.ending(at: cappedEnd)
            pending = cappedEnd < boundary ? nil : SubtitleCue(start: boundary, end: open.end, text: open.text)
            return head
        }

        /// A seek. Pre-seek state must not leak: the open cue dies unwritten
        /// and the decoder forgets its epoch (until the next epoch start the
        /// stream may honestly produce nothing).
        func reanchor() {
            pending = nil
            decoder?.flush()
        }
    }

    private let outputDirectory: URL
    private let lock = NSLock()
    private var externalFiles: [ExternalFile] = []
    private var tracks: [Track] = []
    private var storedRenditions: [MasterPlaylistBuilder.SubtitleRendition] = []
    /// Set once the presentation origin is known; guards a flush that would
    /// otherwise print cues against origin 0.
    private var originSet = false

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    /// Renditions produced so far, in declaration order — what the caller feeds
    /// `MasterPlaylistBuilder`.
    var renditions: [MasterPlaylistBuilder.SubtitleRendition] {
        lock.withLock { storedRenditions }
    }

    /// Register an external `.srt` / `.vtt` file. Must happen before the remux
    /// starts; `PrismCoreSession` enforces that.
    func addExternalFile(_ file: ExternalFile) {
        lock.withLock { externalFiles.append(file) }
    }

    // MARK: - Setup

    /// Create a rendition per convertible source: embedded text streams first
    /// (in stream order), then registered external files. Returns the set of
    /// input stream indices whose packets `ingest` wants.
    @discardableResult
    func prepare(input: UnsafeMutablePointer<AVFormatContext>) throws -> Set<Int32> {
        var built: [Track] = []
        var descriptions: [MasterPlaylistBuilder.SubtitleRendition] = []

        for index in 0..<Int32(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[Int(index)] else { continue }
            let par = stream.pointee.codecpar.pointee
            guard par.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let language = avMetadataValue(stream.pointee.metadata, "language")

            let converter: Track.Converter
            if let kind = Self.kind(for: par.codec_id) {
                converter = .text(kind)
            } else if Self.ocrCodecs.contains(par.codec_id), SubtitleOCR.isAvailable,
                      let decoder = try? BitmapSubtitleDecoder(
                        codecpar: stream.pointee.codecpar, timeBase: stream.pointee.time_base
                      ) {
                // A bitmap track becomes a rendition through on-device OCR —
                // lossy by design (typography dies, text survives), but it is
                // the only form that rides PiP, AirPlay and the system menu.
                // A build without Vision, or a decoder this build lacks,
                // leaves the track host-only exactly as before.
                converter = .bitmap(BitmapRenditionTrack(decoder: decoder, language: language))
            } else {
                continue
            }

            let ordinal = built.count
            let writer = try WebVTTRenditionWriter(
                directory: outputDirectory.appendingPathComponent(Self.directoryName(ordinal), isDirectory: true)
            )
            built.append(
                Track(
                    inputIndex: index,
                    timeBase: stream.pointee.time_base,
                    converter: converter,
                    writer: writer
                )
            )
            descriptions.append(
                MasterPlaylistBuilder.SubtitleRendition(
                    name: avMetadataValue(stream.pointee.metadata, "title")
                        ?? language
                        ?? "Subtitles \(ordinal + 1)",
                    language: language,
                    uri: "\(Self.directoryName(ordinal))/index.m3u8",
                    isForced: stream.pointee.disposition & AV_DISPOSITION_FORCED != 0
                )
            )
        }

        for file in lock.withLock({ externalFiles }) {
            // A file that can't be read or holds no cues gets no rendition at
            // all: an empty rendition in the menu is worse than a missing one.
            guard let cues = Self.loadExternalCues(file.url), !cues.isEmpty else { continue }
            let ordinal = built.count
            let writer = try WebVTTRenditionWriter(
                directory: outputDirectory.appendingPathComponent(Self.directoryName(ordinal), isDirectory: true)
            )
            // The whole file is converted up front; segmentation then follows
            // the video boundaries exactly like an embedded track's, so the
            // rendition playlist lines up 1:1 with the variant.
            for cue in cues { writer.add(cue) }
            built.append(Track(inputIndex: nil, timeBase: nil, converter: .preloaded, writer: writer))
            descriptions.append(
                MasterPlaylistBuilder.SubtitleRendition(
                    name: file.name ?? file.language ?? "Subtitles \(ordinal + 1)",
                    language: file.language,
                    uri: "\(Self.directoryName(ordinal))/index.m3u8",
                    isForced: file.isForced
                )
            )
        }

        tracks = built
        lock.withLock { storedRenditions = descriptions }
        return Set(built.compactMap(\.inputIndex))
    }

    /// The presentation origin (first video PTS, in seconds). Every writer needs
    /// it before the first flush; see `WebVTTRenditionWriter` for what it means
    /// for `X-TIMESTAMP-MAP`.
    func setTimelineOrigin(seconds: Double) {
        guard !originSet else { return }
        originSet = true
        for track in tracks { track.writer.setTimelineOrigin(seconds: seconds) }
    }

    // MARK: - Production

    /// Convert one subtitle packet into cues. Packets for streams that aren't
    /// tracked (a codec we neither convert nor OCR) are ignored.
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) {
        let streamIndex = Int32(packet.pointee.stream_index)
        guard let track = tracks.first(where: { $0.inputIndex == streamIndex }) else { return }

        switch track.converter {
        case .preloaded:
            return
        case .bitmap(let bitmap):
            // Bitmap events carry their own AV_TIME_BASE-derived times; the
            // decoder needs the packet even when its pts is unset (PGS spreads
            // one composition over several packets).
            for cue in bitmap.ingest(packet) {
                track.writer.add(cue)
            }
        case .text(let kind):
            guard let timeBase = track.timeBase,
                  packet.pointee.pts != swift_AV_NOPTS_VALUE(),
                  let data = packet.pointee.data, packet.pointee.size > 0
            else { return }
            let payload = Data(bytes: data, count: Int(packet.pointee.size))
            guard let text = TextSubtitleConverter.cueText(from: payload, kind: kind) else { return }

            let tick = av_q2d(timeBase)
            let start = Double(packet.pointee.pts) * tick
            let duration = packet.pointee.duration > 0
                ? Double(packet.pointee.duration) * tick
                : WebVTTRenditionWriter.fallbackCueSeconds
            track.writer.add(SubtitleCue(start: start, end: start + duration, text: text))
        }
    }

    /// Cut every rendition on the video segment's own boundaries (source
    /// seconds), so segment N of a rendition covers segment N of the variant.
    func flushSegment(start: Double, end: Double) throws {
        for track in tracks {
            // An open bitmap cue splits at the boundary: its first part is
            // written into this segment, its tail re-opens into the next —
            // a composition standing longer than a segment must not vanish
            // from the playlist while it stands on screen.
            if case .bitmap(let bitmap) = track.converter,
               let head = bitmap.splitPending(at: end) {
                track.writer.add(head)
            }
            try track.writer.flushSegment(start: start, end: end)
        }
    }

    /// Planned mode on every rendition (see `WebVTTRenditionWriter`).
    func writePlannedVOD(durations: [Double]) throws {
        for track in tracks {
            try track.writer.writePlannedVOD(durations: durations)
        }
    }

    /// Demand-driven jump on every rendition.
    func reanchor(segmentIndex: Int, startSeconds: Double) {
        for track in tracks {
            if case .bitmap(let bitmap) = track.converter {
                bitmap.reanchor()
            }
            track.writer.reanchor(segmentIndex: segmentIndex, startSeconds: startSeconds)
        }
    }

    /// `EXT-X-ENDLIST` on every rendition playlist.
    func finish() throws {
        for track in tracks {
            try track.writer.finish()
        }
    }

    // MARK: - Helpers

    static func directoryName(_ ordinal: Int) -> String { "subs\(ordinal)" }

    /// Payload shape for a subtitle codec, or `nil` if it isn't text we
    /// convert.
    static func kind(for codecID: AVCodecID) -> TextSubtitleConverter.Kind? {
        switch codecID {
        case AV_CODEC_ID_SUBRIP, AV_CODEC_ID_TEXT: return .subrip
        case AV_CODEC_ID_ASS, AV_CODEC_ID_SSA: return .ass
        case AV_CODEC_ID_WEBVTT: return .webvtt
        case AV_CODEC_ID_MOV_TEXT: return .movText
        default: return nil
        }
    }

    /// Read and convert a whole sidecar file. The extension picks the parser;
    /// unknown extensions are tried as WebVTT and then SRT, because a sidecar
    /// served over HTTP often has no usable path extension at all.
    static func loadExternalCues(_ url: URL) -> [SubtitleCue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        switch url.pathExtension.lowercased() {
        case "vtt":
            return TextSubtitleConverter.cues(fromWebVTT: text)
        case "srt":
            return TextSubtitleConverter.cues(fromSRT: text)
        default:
            let asVTT = TextSubtitleConverter.cues(fromWebVTT: text)
            return asVTT.isEmpty ? TextSubtitleConverter.cues(fromSRT: text) : asVTT
        }
    }
}
