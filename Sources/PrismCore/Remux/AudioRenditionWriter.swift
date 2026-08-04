import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// One HLS **alternate audio rendition**: its own fMP4 segment writer, its own
/// media playlist, its own subdirectory (`audio0/index.m3u8`, `audio0/init.mp4`,
/// `audio0/seg00000.m4s`, …).
///
/// Why a rendition per track instead of muxing several audio traks into the
/// video's own segments: in-band alternates are only reachable through a
/// URI-less `EXT-X-MEDIA`, which HLS defines as "this rendition is inside the
/// variant" — one group, one muxed track, and AVFoundation gets no honest way to
/// switch. A demuxed rendition is the shape HLS was designed for: AVPlayer
/// fetches only the audio the user selected (a five-language MKV stops costing
/// five times the audio bandwidth), and each track keeps its own init segment,
/// which is what lets an AAC track and an AC3 track coexist at all.
///
/// The remuxer drives the cuts — this type never decides a boundary, it is told
/// one (see `cut(durationSeconds:)`), so every rendition is segmented on the
/// *video's* boundaries and the presentation stays comparable across renditions.
final class AudioRenditionWriter {

    /// Where the audio bits come from.
    let route: HLSRemuxer.AudioRoute
    /// What the probe said about the source track — the metadata the master
    /// playlist's `NAME` / `LANGUAGE` / `CHANNELS` come from.
    let track: AudioTrackInfo

    /// `audio0`, `audio1`, … — both the on-disk directory and the URI prefix.
    let directoryName: String
    private let ordinal: Int
    private let directory: URL

    private let writer = FMP4SegmentWriter()
    private let playlist: MediaPlaylistWriter
    private var bridge: AudioBridge?
    private var outputIndex: Int32 = 0
    private var segmentIndex = 0
    /// Boundary time that had no audio bytes to carry (see `cut`). Rolled into
    /// the next segment's `EXTINF` so the rendition's total duration keeps
    /// matching the video's.
    private var pendingDuration: Double = 0

    static let initFileName = "init.mp4"

    init(route: HLSRemuxer.AudioRoute, track: AudioTrackInfo, ordinal: Int, parent: URL) {
        self.route = route
        self.track = track
        self.ordinal = ordinal
        self.directoryName = "audio\(ordinal)"
        self.directory = parent.appendingPathComponent(directoryName, isDirectory: true)
        self.playlist = MediaPlaylistWriter(directory: directory, initFileName: Self.initFileName)
    }

    /// Create the rendition's directory, its muxer and — for a bridged track —
    /// its encoder. Must run before the master playlist is written: a bridged
    /// rendition's declared codec and channel count come from the encoder that
    /// only exists after this call.
    func open(input: UnsafeMutablePointer<AVFormatContext>) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let index = Int32(track.streamIndex)
        var plan: FMP4SegmentWriter.StreamPlan
        if route.mode == .bridge {
            let inStream = input.pointee.streams[Int(index)]!
            let audioBridge = try AudioBridge(
                codecpar: inStream.pointee.codecpar,
                timeBase: inStream.pointee.time_base,
                // mp4/mov is a global-header muxer: the encoder's extradata
                // belongs in codecpar, not in-band.
                globalHeader: true
            )
            bridge = audioBridge
            plan = .init(inputIndex: index, language: sourceLanguage) { outStream in
                try audioBridge.configure(outputStream: outStream)
            }
        } else {
            plan = .init(inputIndex: index, language: sourceLanguage)
        }

        _ = try writer.open(input: input, plan: [plan])
        outputIndex = writer.streamMap[track.streamIndex] ?? 0
    }

    func close() {
        bridge?.close()
        bridge = nil
    }

    /// Push one source packet for this track through copy or bridge.
    func write(_ packet: UnsafeMutablePointer<AVPacket>, sourceTimeBase: AVRational) throws {
        if let bridge {
            // Timestamps arrive in the source stream's base (the bridge's
            // decoder is configured for it) and come back out on the encoder's.
            try bridge.feed(packet) { encoded in
                try self.emit(encoded, from: bridge.timeBase)
            }
        } else {
            try emit(packet, from: sourceTimeBase)
        }
    }

    /// Flush the bridge's encoder tail. Only meaningful on EOF — a cancelled
    /// session is being torn down and the tail would be work for nobody.
    func flushBridge() throws {
        guard let bridge else { return }
        try bridge.flush { encoded in
            try self.emit(encoded, from: bridge.timeBase)
        }
    }

    /// Rescale onto this rendition's single output stream and mux.
    /// `sourceTimeBase` is the packet's own base — the input stream's for
    /// copied packets, the encoder's for bridged ones.
    private func emit(
        _ packet: UnsafeMutablePointer<AVPacket>,
        from sourceTimeBase: AVRational
    ) throws {
        guard let output = writer.context else { return }
        let outStream = output.pointee.streams[Int(outputIndex)]!
        av_packet_rescale_ts(packet, sourceTimeBase, outStream.pointee.time_base)
        packet.pointee.stream_index = outputIndex
        packet.pointee.pos = -1
        try writer.write(packet)
    }

    /// Cut a segment at the boundary the *video* just chose.
    ///
    /// `durationSeconds` is the video segment's own duration rather than the
    /// audio's measured span, and deliberately so: the two differ by whatever
    /// the container's interleave and the codec's frame size make them differ by
    /// (an AAC frame is 21 ms, an EAC3 frame 32 ms — neither divides a video
    /// boundary), and it is the *playlist arithmetic* that has to agree across
    /// renditions for AVPlayer to switch between them without drifting. The
    /// real sample times ride in the segments' own `tfdt`, which is what
    /// playback follows.
    func cut(durationSeconds: Double) throws {
        let (initSegment, media) = try writer.cutSegment()
        // The first cut mints the init segment; write it BEFORE the playlist
        // entry that references it.
        if let initSegment, !initSegment.isEmpty {
            try initSegment.write(
                to: directory.appendingPathComponent(Self.initFileName),
                options: .atomic
            )
        }
        guard !media.isEmpty else {
            // Nothing to carry for this boundary (audio lagging the video's
            // interleave at the head of the file, or a genuine gap). Skipping
            // the entry keeps the playlist free of zero-byte segments; the time
            // it covered joins the next one.
            pendingDuration += durationSeconds
            return
        }
        let file = String(format: "seg%05d.m4s", segmentIndex)
        try media.write(to: directory.appendingPathComponent(file), options: .atomic)
        try playlist.appendSegment(
            duration: max(0.001, pendingDuration + durationSeconds),
            file: file
        )
        pendingDuration = 0
        segmentIndex += 1
    }

    /// Final cut: whatever is buffered plus the trailer's tail bytes.
    func finish(durationSeconds: Double, endList: Bool) throws {
        let (initSegment, media) = try writer.cutSegment()
        if let initSegment, !initSegment.isEmpty {
            try initSegment.write(
                to: directory.appendingPathComponent(Self.initFileName),
                options: .atomic
            )
        }
        var finalSegment = media
        finalSegment.append(try writer.finish())
        if !finalSegment.isEmpty {
            let file = String(format: "seg%05d.m4s", segmentIndex)
            try finalSegment.write(to: directory.appendingPathComponent(file), options: .atomic)
            try playlist.appendSegment(
                duration: max(0.001, pendingDuration + durationSeconds),
                file: file
            )
            pendingDuration = 0
            segmentIndex += 1
        }
        if endList {
            try playlist.finish()
        }
    }

    // MARK: - Master playlist description

    /// Relative URI of this rendition's media playlist, as the master refers
    /// to it.
    var playlistURI: String { "\(directoryName)/index.m3u8" }

    /// The container's language tag, or `nil` when it has none. "und" is the
    /// container's way of saying it doesn't know, which is not a language tag —
    /// omitting it says the same thing without lying to the language-preference
    /// matcher.
    private var sourceLanguage: String? {
        track.language.flatMap { $0 == "und" || $0.isEmpty ? nil : $0 }
    }

    /// How this rendition is declared in the master playlist.
    func rendition(groupID: String, isDefault: Bool) -> MasterPlaylistBuilder.AudioRendition {
        MasterPlaylistBuilder.AudioRendition(
            groupID: groupID,
            name: renditionName,
            language: sourceLanguage,
            codecString: outputCodecString,
            channels: outputChannelCount.map(String.init),
            uri: playlistURI,
            isDefault: isDefault
        )
    }

    /// `NAME` is what the user picks from, so the container's own title wins;
    /// failing that the language, spelled out in the viewer's locale ("Czech",
    /// not "ces"); failing that an ordinal, which at least distinguishes the
    /// tracks from each other.
    private var renditionName: String {
        if let title = track.title, !title.isEmpty { return title }
        if let language = track.language, language != "und", !language.isEmpty {
            if let localized = Locale.current.localizedString(forLanguageCode: language) {
                return localized
            }
            return language
        }
        return "Audio \(ordinal + 1)"
    }

    /// The RFC 6381 tag for what this rendition actually *contains* — the
    /// source's codec when copying, the bridge's when bridging (never the
    /// source's: a bridged rendition carries EAC3, whatever it started as).
    private var outputCodecString: String? {
        switch route.mode {
        case .streamCopy:
            return MasterPlaylistBuilder.audioCodecString(
                forCodecName: track.codecName,
                profileName: track.profileName
            )
        case .bridge:
            return MasterPlaylistBuilder.audioCodecString(forCodecName: "eac3")
        }
    }

    /// `CHANNELS` — the bridge renegotiates the layout (a 7.1 source can leave
    /// as 5.1), so the encoder is the authority when one is in the path.
    private var outputChannelCount: Int? {
        switch route.mode {
        case .streamCopy:
            return track.channelCount > 0 ? track.channelCount : nil
        case .bridge:
            return bridge?.outputChannelCount
        }
    }
}
