import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Stream-copies one video stream plus **every viable audio stream** out of any
/// container libavformat can demux, into HLS-fMP4 on disk — segmenting with our
/// own `FMP4SegmentWriter` (the `hls` muxer is absent from MPVKit's libavformat
/// build; see that type's doc) and writing the playlists ourselves.
///
/// This is the v0 producer: it starts at the head of the source and runs to
/// EOF, growing EVENT playlists AVPlayer can start playing immediately.
/// Cuts happen only at video keyframes at-or-after each `segmentSeconds`
/// boundary, so every segment opens decodable on its own (what the playlist's
/// `EXT-X-INDEPENDENT-SEGMENTS` promises). Because it *stream-copies*, the
/// bits AVPlayer receives are the source's own: an EAC3+JOC (Atmos) track
/// stays object audio all the way to HDMI, and HDR metadata rides the
/// untouched HEVC bitstream.
///
/// Audio is the one place where "stream-copy" isn't the whole story: codecs
/// AVPlayer's fMP4 path can't take (TrueHD, DTS-HD MA, MP3, Opus, …) are routed
/// through `AudioBridge`, which decodes and re-encodes them to EAC3 so surround
/// survives (phase 3). Copyable audio never touches the bridge.
///
/// Text subtitles are carried too (phase 6), but never into the fMP4: their
/// packets go to `SubtitleRenditionSet`, which converts them to segmented WebVTT
/// renditions cut on these same boundaries. Bitmap subtitles are skipped — the
/// probe reports them so the host can draw its own overlay.
///
/// ## Two output shapes, and when each is used
///
/// - **Renditions** (the normal shape). The variant carries video only, and
///   each audio track becomes an HLS alternate rendition with its own segment
///   writer, playlist and subdirectory (`audio0/…`, `audio1/…`), wrapped by a
///   `master.m3u8`. This is what makes track switching possible at all: a
///   selectable audio group only exists in a master playlist.
/// - **Muxed** (the v0 shape, kept as the fallback). One audio track is muxed
///   into the video's own segments and the media playlist is served directly.
///   Used whenever a master playlist would be *dishonest or refused* — the
///   source has no derivable `CODECS` string (HEVC or H.264 with Annex-B
///   extradata), its dynamic range can't be declared to this display, or Dolby
///   Vision Profile 5 meets a non-DV display. Renditions live in the master, so
///   no master means the audio has to ride inside the variant or not at all;
///   falling back to v0's single muxed track is strictly better than serving
///   silence.
///
/// Not in v0 (by design, see README roadmap): demand-driven seeking, `hvcC`
/// normalization, P7→8.1 RPU conversion.
final class HLSRemuxer: @unchecked Sendable {

    /// How a selected audio stream reaches the output.
    enum AudioRouteMode: Equatable {
        /// Bits pass through untouched (AAC/AC3/EAC3/FLAC/ALAC, Atmos included).
        case streamCopy
        /// Decoded and re-encoded to EAC3 by `AudioBridge`.
        case bridge
    }

    struct AudioRoute: Equatable {
        let index: Int32
        let mode: AudioRouteMode
    }

    /// One audio stream as the routing decision sees it. Deliberately a plain
    /// value so the decision itself is pure and testable without a demuxer.
    struct AudioCandidate: Equatable {
        let index: Int32
        let codecID: AVCodecID
    }

    /// What the produced presentation looks like — decided once, before the
    /// first packet, because both the muxer layout and the served URL depend
    /// on it. See the type's doc for the reasoning.
    enum OutputShape: Equatable {
        /// Video-only variant plus one rendition per route, behind a master.
        case renditions([AudioRoute])
        /// v0: the one audio track (if any) muxed into the video's segments.
        case muxed(AudioRoute?)
    }

    enum Failure: Error {
        case noVideoStream
        /// The video codec can't ride AVPlayer's HLS-fMP4 pipeline (VP9,
        /// MPEG-2, …) — the caller should route this source to Prism/libmpv.
        case videoCodecNotNativelyPlayable(String)
    }

    static let masterPlaylistFileName = "master.m3u8"
    static let mediaPlaylistFileName = "index.m3u8"
    static let initFileName = "init.mp4"
    /// One audio group is enough: every rendition is an alternate of the same
    /// programme (see `MasterPlaylistBuilder` on why not one group per codec).
    static let audioGroupID = "aud"

    /// Codecs AVPlayer's HLS-fMP4 pipeline accepts via stream-copy.
    private static let copyableVideo: Set<AVCodecID> = [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC]
    /// Audio that can be stream-copied into fMP4 and decoded (or passed
    /// through) by the system. TrueHD/DTS need the phase-3 bridge.
    private static let copyableAudio: Set<AVCodecID> = [
        AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3,
        AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC,
    ]

    private let sourceURL: URL
    private let httpHeaders: [String: String]
    private let outputDirectory: URL
    /// Segment length target. 6 s is the HLS-classic default; the keyframe
    /// cadence decides the real cuts.
    private let segmentSeconds: Int
    /// Whether the display this session plays to is in (or can enter) the
    /// source's own dynamic range. See `PrismCoreSession` for why the default
    /// is `false`.
    private let displayIsHDRReady: Bool
    private let displayIsDolbyVisionCapable: Bool

    /// Set by `cancel()`; checked once per packet in the copy loop.
    private let cancelled = LockedFlag()

    /// The WebVTT subtitle renditions produced alongside the fMP4 (phase 6).
    /// Exposed so the session can register external files before the run and
    /// read the produced renditions for the master playlist.
    let subtitles: SubtitleRenditionSet

    init(
        sourceURL: URL,
        httpHeaders: [String: String] = [:],
        outputDirectory: URL,
        segmentSeconds: Int = 6,
        displayIsHDRReady: Bool = false,
        displayIsDolbyVisionCapable: Bool = false
    ) {
        self.sourceURL = sourceURL
        self.httpHeaders = httpHeaders
        self.outputDirectory = outputDirectory
        self.segmentSeconds = segmentSeconds
        self.subtitles = SubtitleRenditionSet(outputDirectory: outputDirectory)
        self.displayIsHDRReady = displayIsHDRReady
        self.displayIsDolbyVisionCapable = displayIsDolbyVisionCapable
    }

    func cancel() {
        cancelled.set()
    }

    /// Runs the whole demux → remux loop synchronously; call on a background
    /// task. Returns normally on EOF or cancellation, throws on setup/write
    /// failures.
    func run() throws {
        var input: UnsafeMutablePointer<AVFormatContext>?

        // HTTP(S) inputs carry the caller's headers (a Plex token, a WebDAV
        // authorization) on the demux connection itself.
        var openOptions: OpaquePointer?
        defer { av_dict_free(&openOptions) }
        if !httpHeaders.isEmpty {
            let headerBlob = httpHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
            av_dict_set(&openOptions, "headers", headerBlob, 0)
        }
        // Reconnect on dropped HTTP connections — the demuxer read side.
        av_dict_set(&openOptions, "reconnect", "1", 0)
        av_dict_set(&openOptions, "reconnect_streamed", "1", 0)

        let sourceSpec = sourceURL.isFileURL ? sourceURL.path : sourceURL.absoluteString
        try FFmpegError.check(
            avformat_open_input(&input, sourceSpec, nil, &openOptions),
            "avformat_open_input"
        )
        defer { avformat_close_input(&input) }
        guard let input else { throw Failure.noVideoStream }

        try FFmpegError.check(avformat_find_stream_info(input, nil), "avformat_find_stream_info")

        // The probe already reads everything both decisions below need — which
        // streams exist, what they are, whether they copy, their languages and
        // the video's HDR/DV signaling. Reuse it rather than re-deriving any of
        // it here (SourceProbe.describe works on our already-open context).
        let info = SourceProbe.describe(input: input)
        guard let videoTrack = info.video else { throw Failure.noVideoStream }
        guard videoTrack.copyability == .streamCopy else {
            throw Failure.videoCodecNotNativelyPlayable(videoTrack.codecName)
        }
        let videoIndex = Int32(videoTrack.streamIndex)

        // Subtitle renditions are set up before the muxer: their packets never
        // reach it (in-band timed text is not HLS-conformant — the prior art
        // tried and AVPlayer rejected the stream), they become WebVTT files
        // alongside the fMP4 segments.
        let subtitleStreams = try subtitles.prepare(input: input)

        let candidates = audioCandidates(input)
        let bestAudio = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        let routes = Self.routeAll(candidates: candidates, best: bestAudio >= 0 ? bestAudio : nil)

        // Can this source be honestly wrapped in a master playlist at all? The
        // answer decides the whole output shape, so it is settled before a
        // single muxer exists. `variant` here is the video half only; the
        // renditions are added once their encoders are up (a bridged rendition's
        // CHANNELS comes from the encoder), and they can't change the verdict —
        // every `SignalingError` is about the video.
        let videoVariant = makeVideoVariant(input: input, video: videoTrack)
        let masterIsPossible = videoVariant.map { (try? MasterPlaylistBuilder.build($0)) != nil } ?? false

        let shape: OutputShape = (!routes.isEmpty && masterIsPossible)
            ? .renditions(routes)
            : .muxed(Self.chooseAudio(candidates: candidates, best: bestAudio >= 0 ? bestAudio : nil))

        // MARK: Output setup

        var renditions: [AudioRenditionWriter] = []
        defer { renditions.forEach { $0.close() } }
        var muxedBridge: AudioBridge?
        defer { muxedBridge?.close() }
        var plan: [FMP4SegmentWriter.StreamPlan] = [.init(inputIndex: videoIndex)]

        switch shape {
        case .renditions(let routes):
            let byIndex = Dictionary(
                uniqueKeysWithValues: info.audioTracks.map { ($0.streamIndex, $0) }
            )
            for (ordinal, route) in routes.enumerated() {
                guard let track = byIndex[Int(route.index)] else { continue }
                let rendition = AudioRenditionWriter(
                    route: route,
                    track: track,
                    ordinal: ordinal,
                    parent: outputDirectory
                )
                // One track that can't be set up (a channel layout the EAC3
                // encoder can't express, say) costs that rendition, not the
                // session: the other tracks and the picture still play, which
                // is the whole point of not muxing them together.
                do {
                    try rendition.open(input: input)
                    renditions.append(rendition)
                } catch {
                    rendition.close()
                }
            }
            // The master is static — URIs, codecs and languages are all known
            // now — so it lands before the first segment. `PrismCoreSession`
            // reads its presence to decide which URL it hands out.
            if var variant = videoVariant, !renditions.isEmpty {
                variant.audioRenditions = renditions.enumerated().map { ordinal, rendition in
                    // DEFAULT on the first rendition only, which is the track
                    // `chooseAudio` would have picked (see `routeAll`).
                    rendition.rendition(groupID: Self.audioGroupID, isDefault: ordinal == 0)
                }
                try Data(try MasterPlaylistBuilder.build(variant).utf8).write(
                    to: outputDirectory.appendingPathComponent(Self.masterPlaylistFileName),
                    options: .atomic
                )
            }

        case .muxed(let audio):
            // Bridge first — its encoder parameters must be on the output stream
            // BEFORE write_header (empty_moov writes the sample entries then).
            if let audio {
                if audio.mode == .bridge {
                    let inStream = input.pointee.streams[Int(audio.index)]!
                    let bridge = try AudioBridge(
                        codecpar: inStream.pointee.codecpar,
                        timeBase: inStream.pointee.time_base,
                        // mp4/mov is a global-header muxer by definition; the
                        // encoder's extradata must land in codecpar, not in-band.
                        globalHeader: true
                    )
                    muxedBridge = bridge
                    plan.append(.init(inputIndex: audio.index) { outStream in
                        try bridge.configure(outputStream: outStream)
                    })
                } else {
                    plan.append(.init(inputIndex: audio.index))
                }
            }
        }

        let muxedBridgeIndex: Int32? = {
            guard case .muxed(let audio) = shape, audio?.mode == .bridge else { return nil }
            return audio?.index
        }()
        let renditionByInputIndex = Dictionary(
            uniqueKeysWithValues: renditions.map { (Int($0.route.index), $0) }
        )

        let writer = FMP4SegmentWriter()
        _ = try writer.open(input: input, plan: plan)   // delay_moov: header emits nothing
        let streamMap = writer.streamMap
        let playlist = MediaPlaylistWriter(directory: outputDirectory)

        // Segmentation state, tracked on the INPUT video stream's time base
        // (the packet still carries it when the cut decision is made).
        let videoTimeBase = input.pointee.streams[Int(videoIndex)]!.pointee.time_base
        let tickSeconds = av_q2d(videoTimeBase)
        let boundaryStep = Int64((Double(segmentSeconds) / tickSeconds).rounded())
        var segmentStartPTS: Int64?
        var nextBoundaryPTS: Int64 = 0
        var lastVideoEndPTS: Int64?
        var segmentIndex = 0

        func emitSegment(endPTS: Int64) throws {
            let (initSegment, media) = try writer.cutSegment()
            // The first cut also mints the init segment (see cutSegment's
            // doc); write it BEFORE the playlist entry so a reader that saw
            // the manifest can always fetch what it references.
            if let initSegment, !initSegment.isEmpty {
                try initSegment.write(to: outputDirectory.appendingPathComponent(Self.initFileName), options: .atomic)
            }
            // A boundary that produced no video bytes writes nothing anywhere,
            // renditions included: skipping the cut on all of them together is
            // what keeps their segment lists one-to-one with the video's.
            guard !media.isEmpty, let start = segmentStartPTS else { return }
            let duration = max(0.001, Double(endPTS - start) * tickSeconds)
            let file = String(format: "seg%05d.m4s", segmentIndex)
            try media.write(to: outputDirectory.appendingPathComponent(file), options: .atomic)
            try playlist.appendSegment(duration: duration, file: file)
            // Same wall-time window, so rendition segment N covers variant
            // segment N — cut only when a media segment really landed.
            try subtitles.flushSegment(
                start: Double(start) * tickSeconds,
                end: Double(endPTS) * tickSeconds
            )
            segmentIndex += 1
            // Every rendition cuts on the SAME source-time boundary the video
            // just used — HLS expects comparable segmentation across renditions,
            // and a rendition that drifted into its own cadence would make
            // AVPlayer's switch between them a resync.
            for rendition in renditions {
                try rendition.cut(durationSeconds: duration)
            }
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return }

        // MARK: Copy loop
        var reachedEOF = false
        while !cancelled.isSet {
            let readResult = av_read_frame(input, packet)
            if readResult == swift_AVERROR_EOF() {
                reachedEOF = true
                break
            }
            if readResult < 0 {
                // Transient read errors on network sources: the reconnect
                // options above handle the socket; anything that still
                // surfaces here ends the remux (the playlists stay valid up
                // to the last written segment).
                throw FFmpegError(code: readResult, operation: "av_read_frame")
            }
            defer { av_packet_unref(packet) }

            // Subtitle packets are consumed here and never handed to the muxer.
            if subtitleStreams.contains(Int32(packet.pointee.stream_index)) {
                subtitles.ingest(packet)
                continue
            }

            let streamIndex = Int(packet.pointee.stream_index)
            let inStream = input.pointee.streams[streamIndex]!
            let sourceTimeBase = inStream.pointee.time_base

            if Int32(streamIndex) == videoIndex {
                // Cut BEFORE writing a boundary keyframe, so the keyframe opens
                // the next segment (every segment starts decodable on its own —
                // what EXT-X-INDEPENDENT-SEGMENTS promises).
                if packet.pointee.pts != swift_AV_NOPTS_VALUE() {
                    let pts = packet.pointee.pts
                    let isKey = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
                    if isKey {
                        if segmentStartPTS == nil {
                            segmentStartPTS = pts
                            nextBoundaryPTS = pts + boundaryStep
                            // The presentation origin: what the WebVTT timestamp
                            // maps are anchored to (see WebVTTRenditionWriter).
                            subtitles.setTimelineOrigin(seconds: Double(pts) * tickSeconds)
                        } else if pts >= nextBoundaryPTS {
                            try emitSegment(endPTS: pts)
                            segmentStartPTS = pts
                            nextBoundaryPTS = pts + boundaryStep
                        }
                    }
                    lastVideoEndPTS = pts + max(packet.pointee.duration, 0)
                }
                if let mapped = streamMap[streamIndex] {
                    try write(packet, to: mapped, from: sourceTimeBase, writer: writer)
                }
                continue
            }

            if let rendition = renditionByInputIndex[streamIndex] {
                try rendition.write(packet, sourceTimeBase: sourceTimeBase)
                continue
            }

            guard let mapped = streamMap[streamIndex] else { continue }

            if let muxedBridge, Int32(streamIndex) == muxedBridgeIndex {
                // Timestamps on the way in stay in the source stream's time
                // base — the bridge's decoder is configured for it — and come
                // back out on the encoder's, so only one rescale is left.
                try muxedBridge.feed(packet) { encoded in
                    try write(encoded, to: mapped, from: muxedBridge.timeBase, writer: writer)
                }
                continue
            }

            try write(packet, to: mapped, from: sourceTimeBase, writer: writer)
        }

        // A cancelled session is being torn down, so flushing the encoders would
        // only add work; on EOF the tail is real audio the file has.
        if reachedEOF {
            if let muxedBridge, let mapped = muxedBridgeIndex.flatMap({ streamMap[Int($0)] }) {
                try muxedBridge.flush { encoded in
                    try write(encoded, to: mapped, from: muxedBridge.timeBase, writer: writer)
                }
            }
            for rendition in renditions {
                try rendition.flushBridge()
            }
        }

        // Final segment: whatever is buffered since the last cut, plus the
        // trailer's tail bytes, is one segment. A sub-6s source cuts here for
        // the first time, so this can also mint the init segment.
        let closingPTS = lastVideoEndPTS ?? nextBoundaryPTS
        let (initSegment, media) = try writer.cutSegment()
        if let initSegment, !initSegment.isEmpty {
            try initSegment.write(to: outputDirectory.appendingPathComponent(Self.initFileName), options: .atomic)
        }
        var finalSegment = media
        finalSegment.append(try writer.finish())
        let finalDuration = max(0.001, Double(closingPTS - (segmentStartPTS ?? closingPTS)) * tickSeconds)
        if !finalSegment.isEmpty, segmentStartPTS != nil {
            let file = String(format: "seg%05d.m4s", segmentIndex)
            try finalSegment.write(to: outputDirectory.appendingPathComponent(file), options: .atomic)
            try playlist.appendSegment(duration: finalDuration, file: file)
            if let start = segmentStartPTS {
                try subtitles.flushSegment(
                    start: Double(start) * tickSeconds,
                    end: Double(closingPTS) * tickSeconds
                )
            }
        }
        for rendition in renditions {
            try rendition.finish(durationSeconds: finalDuration, endList: reachedEOF)
        }
        if reachedEOF {
            try subtitles.finish()
            // ENDLIST only on a genuinely finished remux — a cancelled one leaves the
            // event playlist open-ended, and the session dir dies with stop().
            try playlist.finish()
        }
    }

    /// Rescale one packet onto an output stream and hand it to the muxer.
    /// `sourceTimeBase` is the packet's own base — the input stream's for
    /// copied packets, the encoder's for bridged ones.
    private func write(
        _ packet: UnsafeMutablePointer<AVPacket>,
        to outputIndex: Int32,
        from sourceTimeBase: AVRational,
        writer: FMP4SegmentWriter
    ) throws {
        guard let output = writer.context else { return }
        let outStream = output.pointee.streams[Int(outputIndex)]!
        av_packet_rescale_ts(packet, sourceTimeBase, outStream.pointee.time_base)
        packet.pointee.stream_index = outputIndex
        packet.pointee.pos = -1
        try writer.write(packet)
    }

    // MARK: - Setup

    private func audioCandidates(_ input: UnsafeMutablePointer<AVFormatContext>) -> [AudioCandidate] {
        var candidates: [AudioCandidate] = []
        for index in 0..<Int(input.pointee.nb_streams) {
            let par = input.pointee.streams[index]!.pointee.codecpar.pointee
            guard par.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            candidates.append(AudioCandidate(index: Int32(index), codecID: par.codec_id))
        }
        return candidates
    }

    /// Every audio track worth carrying, as its own rendition.
    ///
    /// Order matters: the preferred track — whatever `chooseAudio` would have
    /// selected as the single one, i.e. the demuxer's best copyable or bridged
    /// track — comes first, because the first rendition is the one flagged
    /// `DEFAULT` in the master. The rest follow in container order, which is the
    /// order a user expects to see them listed in.
    ///
    /// Tracks that are neither copyable nor bridgeable here and now (no decoder
    /// in this build, or no EAC3 encoder — see `AudioBridge.isEncoderAvailable`)
    /// are skipped: a rendition AVPlayer can't play is worse than an absent one,
    /// because a failed rendition fetch can fail the whole item.
    static func routeAll(
        candidates: [AudioCandidate],
        best: Int32?,
        canBridge: (AVCodecID) -> Bool = { AudioBridge.canBridge(codecID: $0) }
    ) -> [AudioRoute] {
        let viable: [AudioRoute] = candidates.compactMap { candidate in
            if copyableAudio.contains(candidate.codecID) {
                return AudioRoute(index: candidate.index, mode: .streamCopy)
            }
            if canBridge(candidate.codecID) {
                return AudioRoute(index: candidate.index, mode: .bridge)
            }
            return nil
        }
        guard let preferred = chooseAudio(candidates: candidates, best: best, canBridge: canBridge),
              let position = viable.firstIndex(where: { $0.index == preferred.index })
        else { return viable }
        var ordered = viable
        ordered.remove(at: position)
        ordered.insert(preferred, at: 0)
        return ordered
    }

    /// Decide which single audio stream to carry, and how — the muxed shape's
    /// selection, and the one that decides which rendition is `DEFAULT`.
    ///
    /// Order of preference, and the reasoning:
    ///
    /// 1. The demuxer's *best* stream when it is stream-copyable — untouched
    ///    bits beat anything we could re-encode, and this is the case that keeps
    ///    Atmos alive.
    /// 2. The best stream through the bridge. Before phase 3 this case fell back
    ///    to a lesser copyable track, which meant a DTS-HD MA 7.1 main track
    ///    lost to an AC3 2.0 compatibility track — the bridge makes the main
    ///    track the better answer even at a re-encode's cost.
    /// 3. Any copyable stream, for sources whose best track can't be bridged
    ///    either (no decoder in this build, or no EAC3 encoder — see
    ///    `AudioBridge.isEncoderAvailable`). This is v0's behaviour, preserved
    ///    as the fallback rather than removed.
    /// 4. Any bridgeable stream at all.
    ///
    /// `canBridge` is injected so the decision can be exercised as a pure
    /// function in tests, independent of what the linked FFmpeg supports.
    static func chooseAudio(
        candidates: [AudioCandidate],
        best: Int32?,
        canBridge: (AVCodecID) -> Bool = { AudioBridge.canBridge(codecID: $0) }
    ) -> AudioRoute? {
        if let best, let bestCandidate = candidates.first(where: { $0.index == best }) {
            if copyableAudio.contains(bestCandidate.codecID) {
                return AudioRoute(index: best, mode: .streamCopy)
            }
            if canBridge(bestCandidate.codecID) {
                return AudioRoute(index: best, mode: .bridge)
            }
        }
        if let copyable = candidates.first(where: { copyableAudio.contains($0.codecID) }) {
            return AudioRoute(index: copyable.index, mode: .streamCopy)
        }
        if let bridgeable = candidates.first(where: { canBridge($0.codecID) }) {
            return AudioRoute(index: bridgeable.index, mode: .bridge)
        }
        return nil
    }

    // MARK: - Master playlist description

    /// The video half of the master's variant, or `nil` when this source can't
    /// be declared honestly (no `CODECS` string to be had, or a dynamic range
    /// this display isn't ready for). `nil` routes the session to the muxed
    /// shape — see the type's doc.
    private func makeVideoVariant(
        input: UnsafeMutablePointer<AVFormatContext>,
        video: VideoTrackInfo
    ) -> MasterPlaylistBuilder.VariantDescription? {
        guard let codec = videoCodecDeclaration(for: video) else { return nil }

        // A range the display can't take must not be claimed, and must not be
        // *mis*-claimed either: declaring an HDR10 stream as SDR doesn't fool
        // the compatibility gate (it reads the bitstream's own `colr`), it only
        // makes the manifest a lie. So an HDR source on a display the host
        // hasn't vouched for gets no master at all, which is exactly the shape
        // v0 already served it.
        guard video.dynamicRange == .sdr || displayIsHDRReady else { return nil }

        return MasterPlaylistBuilder.VariantDescription(
            mediaPlaylistURI: Self.mediaPlaylistFileName,
            bandwidth: sourceBandwidth(input: input),
            resolution: video.width > 0 && video.height > 0
                ? .init(width: video.width, height: video.height)
                : nil,
            frameRate: video.frameRate,
            dynamicRange: video.dynamicRange,
            videoCodec: codec,
            dolbyVision: video.dolbyVision,
            displayIsDolbyVisionCapable: displayIsDolbyVisionCapable
        )
    }

    /// How the video codec is declared — from the container's own configuration
    /// record, never guessed. Annex-B extradata (MPEG-TS) has no record, so
    /// there is no honest `CODECS` string and the source plays media-direct
    /// rather than risk an over-claim AVPlayer checks against the init segment.
    private func videoCodecDeclaration(
        for video: VideoTrackInfo
    ) -> MasterPlaylistBuilder.VideoCodec? {
        if let hevc = video.hevcConfiguration { return .hevc(hevc) }
        if let avc = video.avcConfiguration { return .avc(avc) }
        return nil
    }

    /// `BANDWIDTH` for the single variant: the container's own bit rate, or the
    /// streams' summed rates, or the file's size over its duration.
    ///
    /// A one-variant master has nothing to switch between, so this attribute is
    /// informational — but it is mandatory, and AVPlayer uses it to size its
    /// read-ahead, so an order-of-magnitude-honest number is worth the three
    /// lookups. The last resort is a deliberately generous 4K-ish figure:
    /// over-stating it costs a bigger buffer, under-stating it can make AVPlayer
    /// pace fetches below what the stream needs.
    private func sourceBandwidth(input: UnsafeMutablePointer<AVFormatContext>) -> Int {
        if input.pointee.bit_rate > 0 { return Int(input.pointee.bit_rate) }

        var summed: Int64 = 0
        for index in 0..<Int(input.pointee.nb_streams) {
            summed += max(0, input.pointee.streams[index]!.pointee.codecpar.pointee.bit_rate)
        }
        if summed > 0 { return Int(summed) }

        if sourceURL.isFileURL, input.pointee.duration != swift_AV_NOPTS_VALUE(),
           input.pointee.duration > 0,
           let size = try? FileManager.default
               .attributesOfItem(atPath: sourceURL.path)[.size] as? Int, size > 0 {
            let seconds = Double(input.pointee.duration) / Double(AV_TIME_BASE)
            return max(1, Int(Double(size) * 8 / seconds))
        }
        return 25_000_000
    }
}

/// Tiny lock-protected flag — the cancel signal crossing from the session
/// actor into the synchronous copy loop.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}
