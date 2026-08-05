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
/// Phase 4 added two edits to the otherwise byte-for-byte video copy, both
/// applied before the muxer sees anything: the `hvcC` is normalized into the form
/// a `hvc1` sample entry has to have (`HVCCNormalizer`), and a Dolby Vision
/// Profile 7 source has its RPUs converted to 8.1 with the enhancement layer
/// dropped (`DolbyVisionRPUConverter`) so a dual-layer file Apple can't decode
/// arrives as a single-layer one it can. Neither touches picture data.
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
    /// Present = demand-driven session (phase 5): plan the segmentation
    /// upfront, publish complete VOD playlists, and re-anchor the producer
    /// wherever the loopback reports AVPlayer is fetching.
    private let demand: DemandCoordinator?
    /// Disk budget for produced segments, planned mode only (`nil` keeps
    /// everything). See `SegmentRetention` for the policy.
    private let segmentCacheBytes: Int?
    /// Skip the renditions shape even when a master is possible — the host's
    /// answer to AVPlayer refusing a master (-11868/-11848/-1002): a fresh
    /// session with the one best audio track muxed into the variant.
    private let forceMuxed: Bool

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
        displayIsDolbyVisionCapable: Bool = false,
        demand: DemandCoordinator? = nil,
        segmentCacheBytes: Int? = nil,
        forceMuxed: Bool = false
    ) {
        self.sourceURL = sourceURL
        self.httpHeaders = httpHeaders
        self.outputDirectory = outputDirectory
        self.segmentSeconds = segmentSeconds
        self.subtitles = SubtitleRenditionSet(outputDirectory: outputDirectory)
        self.displayIsHDRReady = displayIsHDRReady
        self.displayIsDolbyVisionCapable = displayIsDolbyVisionCapable
        self.demand = demand
        self.segmentCacheBytes = segmentCacheBytes
        self.forceMuxed = forceMuxed
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
        // reach it (in-band timed text is not HLS-conformant — muxing it in
        // gets the whole stream rejected by AVPlayer), they become WebVTT files
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
        // Profile 7 is dual-layer and undecodable here, but its base layer is
        // plain HDR10 — so rather than handing the source to Prism we convert its
        // RPUs to 8.1 and drop the enhancement layer as the packets go past. The
        // converter is nil for every other source (and when libdovi isn't in this
        // build), and then nothing below changes.
        let dolbyVisionConverter = makeDolbyVisionConverter(video: videoTrack)
        // What the manifest may claim: the *converted* configuration when we are
        // converting, the source's own otherwise. Declaring 8.1 for a stream
        // whose RPUs are still P7 would be the one lie AVKit can't detect at
        // parse time and can only fail on at the display.
        let outputDolbyVision = dolbyVisionConverter != nil
            ? videoTrack.dolbyVision?.convertedToProfile81
            : videoTrack.dolbyVision

        let videoVariant = makeVideoVariant(
            input: input, video: videoTrack, dolbyVision: outputDolbyVision
        )
        let masterIsPossible = videoVariant.map { (try? MasterPlaylistBuilder.build($0)) != nil } ?? false

        let shape: OutputShape = (!routes.isEmpty && masterIsPossible && !forceMuxed)
            ? .renditions(routes)
            : .muxed(Self.chooseAudio(candidates: candidates, best: bestAudio >= 0 ? bestAudio : nil))

        // Demand-driven mode needs a trustworthy upfront segmentation. Only a
        // keyframe-based plan qualifies — uniform-plan boundaries are time
        // targets, and a playlist that promises durations the producer can't
        // hit at keyframes would drift against what AVPlayer fetched. The one
        // shape excluded is muxed-with-bridge: re-anchoring would mean
        // resetting an encoder mid-fragment, and that combination only occurs
        // when a master was refused anyway.
        let plannedPlan: SegmentPlan? = {
            guard demand != nil else { return nil }
            if case .muxed(let audio) = shape, audio?.mode == .bridge { return nil }
            guard let built = SegmentPlan.build(
                input: input, videoStreamIndex: videoIndex, targetSeconds: segmentSeconds
            ), built.basis == .keyframeIndex else { return nil }
            return built
        }()

        // MARK: Output setup

        var renditions: [AudioRenditionWriter] = []
        defer { renditions.forEach { $0.close() } }
        var muxedBridge: AudioBridge?
        defer { muxedBridge?.close() }
        // The video stream is the one output stream we describe ourselves rather
        // than mirroring: its `hvcC` needs normalizing for the `hvc1` sample
        // entry, and a converted P7 has to carry an 8.1 `dvvC` instead of the
        // source's own record.
        var plan: [FMP4SegmentWriter.StreamPlan] = [
            .init(inputIndex: videoIndex) { [self] outStream in
                try configureVideoOutput(
                    outStream,
                    input: input,
                    videoIndex: videoIndex,
                    dolbyVision: dolbyVisionConverter != nil ? outputDolbyVision : nil
                )
            }
        ]

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

        var writer = FMP4SegmentWriter()
        _ = try writer.open(input: input, plan: plan)   // delay_moov: header emits nothing
        var streamMap = writer.streamMap
        let playlist = MediaPlaylistWriter(directory: outputDirectory)

        // Planned VOD: every playlist is complete before the first packet —
        // from here on, playlists are read-only and segments land as files.
        if let plannedPlan, let demand {
            let durations = plannedPlan.entries.map(\.duration)
            try playlist.writePlannedVOD(durations: durations) { index in
                String(format: "seg%05d.m4s", index)
            }
            for rendition in renditions {
                try rendition.writePlannedVOD(durations: durations)
            }
            try subtitles.writePlannedVOD(durations: durations)
            demand.publish(plan: plannedPlan)
            demand.setProducing(index: 0)
        }

        // Segmentation state, tracked on the INPUT video stream's time base
        // (the packet still carries it when the cut decision is made).
        let videoTimeBase = input.pointee.streams[Int(videoIndex)]!.pointee.time_base
        let tickSeconds = av_q2d(videoTimeBase)
        let boundaryStep = Int64((Double(segmentSeconds) / tickSeconds).rounded())
        var segmentStartPTS: Int64?
        var nextBoundaryPTS: Int64 = 0
        var lastVideoEndPTS: Int64?
        var segmentIndex = 0
        /// Post-reanchor: discard packets until the anchor keyframe arrives
        /// (a BACKWARD seek may land at an earlier keyframe than requested).
        var droppingUntilPTS: Int64?

        /// The planned end of segment `index` — the next entry's start — or
        /// "never" past the last entry (EOF closes it).
        func plannedBoundary(after index: Int) -> Int64 {
            guard let plannedPlan, index + 1 < plannedPlan.entries.count else { return .max }
            return plannedPlan.entries[index + 1].startPTS
        }

        // Retention exists only where eviction is survivable: planned mode,
        // where a deleted segment is reproduced on demand.
        var retention: SegmentRetention? = (plannedPlan != nil)
            ? segmentCacheBytes.map { SegmentRetention(budgetBytes: $0) }
            : nil

        /// Record a landed segment's disk cost (variant + every rendition
        /// file of the same index) and delete whatever the policy evicts.
        func recordAndEvict(index: Int, videoBytes: Int) {
            guard retention != nil else { return }
            let name = String(format: "seg%05d.m4s", index)
            var bytes = videoBytes
            for rendition in renditions {
                let path = outputDirectory
                    .appendingPathComponent(rendition.directoryName)
                    .appendingPathComponent(name).path
                bytes += ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0
            }
            for victim in retention!.record(index: index, bytes: bytes, producing: index) {
                let victimName = String(format: "seg%05d.m4s", victim)
                try? FileManager.default.removeItem(
                    at: outputDirectory.appendingPathComponent(victimName)
                )
                for rendition in renditions {
                    try? FileManager.default.removeItem(
                        at: outputDirectory
                            .appendingPathComponent(rendition.directoryName)
                            .appendingPathComponent(victimName)
                    )
                }
            }
        }

        func emitSegment(endPTS: Int64) throws {
            let (initSegment, media) = try writer.cutSegment()
            // The first cut also mints the init segment (see cutSegment's
            // doc); write it BEFORE the playlist entry so a reader that saw
            // the manifest can always fetch what it references.
            if let initSegment, !initSegment.isEmpty {
                let initURL = outputDirectory.appendingPathComponent(Self.initFileName)
                // A re-anchored muxer mints its moov again; the one already
                // served must not change under AVPlayer's cached EXT-X-MAP.
                if !FileManager.default.fileExists(atPath: initURL.path) {
                    try initSegment.write(to: initURL, options: .atomic)
                }
            }
            // A boundary that produced no video bytes writes nothing anywhere,
            // renditions included: skipping the cut on all of them together is
            // what keeps their segment lists one-to-one with the video's.
            guard !media.isEmpty, let start = segmentStartPTS else { return }
            let duration = max(0.001, Double(endPTS - start) * tickSeconds)
            let file = String(format: "seg%05d.m4s", segmentIndex)
            try media.write(to: outputDirectory.appendingPathComponent(file), options: .atomic)
            if plannedPlan == nil {
                try playlist.appendSegment(duration: duration, file: file)
            }
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
            demand?.setProducing(index: segmentIndex)
            recordAndEvict(index: segmentIndex - 1, videoBytes: media.count)
        }

        /// Demand-driven jump: abandon the in-flight fragment, seek the
        /// demuxer to the anchor's keyframe, and stand up fresh muxers whose
        /// tfdt carries absolute time (`restart` → frag_discont), so the
        /// produced segment sits exactly where the planned playlist put it.
        func reanchor(to anchor: Int) throws {
            guard let plannedPlan else { return }
            let target = plannedPlan.entries[anchor].startPTS
            try FFmpegError.check(
                av_seek_frame(input, videoIndex, target, AVSEEK_FLAG_BACKWARD),
                "av_seek_frame"
            )
            writer = FMP4SegmentWriter()
            _ = try writer.open(input: input, plan: plan, restart: true)
            streamMap = writer.streamMap
            for rendition in renditions {
                try rendition.reanchor(input: input, segmentIndex: anchor)
            }
            subtitles.reanchor(segmentIndex: anchor, startSeconds: Double(target) * tickSeconds)
            segmentIndex = anchor
            segmentStartPTS = nil
            nextBoundaryPTS = plannedBoundary(after: anchor)
            droppingUntilPTS = target
            demand?.setProducing(index: anchor)
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return }

        // MARK: Copy loop
        // In planned mode the producer never truly ends at EOF: an earlier
        // re-anchor may have skipped segments nobody produced, and a seek back
        // to one of them arrives AFTER the demuxer ran dry. So the produce
        // loop parks at EOF and waits for anchor requests until the session
        // is cancelled; sequential (v0) sessions run it exactly once.
        var reachedEOF = false
        produce: while true {
            reachedEOF = false
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

                // A fetch outside the producer's window re-anchors it — checked
                // once per packet; nil is the hot path.
                if plannedPlan != nil, let anchor = demand?.takeAnchorRequest(),
                   anchor != segmentIndex, anchor >= 0,
                   anchor < (plannedPlan?.entries.count ?? 0) {
                    try reanchor(to: anchor)
                }

                // Between a seek and the anchor keyframe, everything is discard:
                // the plan's PTS is an indexed keyframe, so it WILL arrive, and
                // pre-anchor packets belong to a segment nobody asked for.
                if let target = droppingUntilPTS {
                    let isAnchorKeyframe = Int32(packet.pointee.stream_index) == videoIndex
                        && packet.pointee.flags & AV_PKT_FLAG_KEY != 0
                        && packet.pointee.pts != swift_AV_NOPTS_VALUE()
                        && packet.pointee.pts >= target
                    if isAnchorKeyframe {
                        droppingUntilPTS = nil
                    } else {
                        continue
                    }
                }

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
                                nextBoundaryPTS = plannedPlan != nil
                                    ? plannedBoundary(after: segmentIndex)
                                    : pts + boundaryStep
                                // The presentation origin: what the WebVTT timestamp
                                // maps are anchored to (see WebVTTRenditionWriter).
                                subtitles.setTimelineOrigin(seconds: Double(pts) * tickSeconds)
                            } else if pts >= nextBoundaryPTS {
                                try emitSegment(endPTS: pts)
                                segmentStartPTS = pts
                                nextBoundaryPTS = plannedPlan != nil
                                    ? plannedBoundary(after: segmentIndex)
                                    : pts + boundaryStep
                            }
                        }
                        lastVideoEndPTS = pts + max(packet.pointee.duration, 0)
                    }
                    // P7 → 8.1: rewrite the RPUs and drop the enhancement layer
                    // before the bits reach the muxer. Returns nil for a packet
                    // that needed neither, which is every packet of every other
                    // source — the cost there is one NAL walk, no copy.
                    if let dolbyVisionConverter, let data = packet.pointee.data,
                       packet.pointee.size > 0 {
                        let original = [UInt8](
                            UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
                        )
                        if let converted = dolbyVisionConverter.convert(packet: original) {
                            try Self.replacePayload(of: packet, with: converted)
                        }
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
                let initURL = outputDirectory.appendingPathComponent(Self.initFileName)
                if !FileManager.default.fileExists(atPath: initURL.path) {
                    try initSegment.write(to: initURL, options: .atomic)
                }
            }
            var finalSegment = media
            finalSegment.append(try writer.finish())
            let finalDuration = max(0.001, Double(closingPTS - (segmentStartPTS ?? closingPTS)) * tickSeconds)
            if !finalSegment.isEmpty, segmentStartPTS != nil {
                let file = String(format: "seg%05d.m4s", segmentIndex)
                try finalSegment.write(to: outputDirectory.appendingPathComponent(file), options: .atomic)
                if plannedPlan == nil {
                    try playlist.appendSegment(duration: finalDuration, file: file)
                }
                recordAndEvict(index: segmentIndex, videoBytes: finalSegment.count)
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
                // (Planned playlists were born ended.)
                if plannedPlan == nil {
                    try playlist.finish()
                }
            }

            // Park: EOF reached with a plan published — wait for demand.
            guard plannedPlan != nil, reachedEOF, !cancelled.isSet else { break produce }
            var idleAnchor: Int?
            while !cancelled.isSet {
                if let anchor = demand?.takeAnchorRequest(),
                   anchor >= 0, anchor < (plannedPlan?.entries.count ?? 0) {
                    idleAnchor = anchor
                    break
                }
                // The provider's pending serves poll every 100 ms with a 15 s
                // budget; waking at half their cadence keeps the worst case
                // one poll late.
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard let anchor = idleAnchor else { break produce }
            try reanchor(to: anchor)
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

    // MARK: - Video output stream

    /// Describe the video output stream: mirror the source's parameters, then
    /// make the two corrections a stream-copied HEVC track needs.
    ///
    /// Both edits have to happen here rather than after `write_header`, because
    /// with `delay_moov` the sample entries are built from `codecpar` at
    /// moov-flush time — the init segment is minted from whatever this closure
    /// leaves behind.
    private func configureVideoOutput(
        _ outStream: UnsafeMutablePointer<AVStream>,
        input: UnsafeMutablePointer<AVFormatContext>,
        videoIndex: Int32,
        dolbyVision: DolbyVisionConfiguration?
    ) throws {
        let inStream = input.pointee.streams[Int(videoIndex)]!
        try FFmpegError.check(
            avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar),
            "avcodec_parameters_copy"
        )
        let par = outStream.pointee.codecpar!
        par.pointee.codec_tag = 0

        // `hvcC` → `hvc1`-correct form. Only HEVC has the problem (an `avcC`
        // carries no arrays to normalize), and `normalize` returns nil when the
        // record was already right, so the common case keeps the source's own
        // extradata pointer.
        if par.pointee.codec_id == AV_CODEC_ID_HEVC,
           let extradata = par.pointee.extradata, par.pointee.extradata_size > 0 {
            let current = Data(bytes: extradata, count: Int(par.pointee.extradata_size))
            if let normalized = HVCCNormalizer.normalize(hvcC: current) {
                try Self.setExtradata(normalized, on: par)
            }
        }

        // A converted P7 must be *declared* 8.1: movenc writes the `dvvC` box
        // from this side data, and a box that still said profile 7 would send an
        // Apple TV looking for an enhancement layer that is no longer there.
        if let dolbyVision {
            try Self.setDolbyVisionConfiguration(dolbyVision, on: par)
        }
    }

    /// Replace a codecpar's extradata with `data`.
    ///
    /// The allocation rules are libavcodec's, not ours: the buffer must come from
    /// `av_malloc` with `AV_INPUT_BUFFER_PADDING_SIZE` zeroed bytes past the end
    /// (bitstream readers over-read by design), and the old buffer must be freed
    /// with `av_free`. Getting either wrong is a crash inside FFmpeg, not a Swift
    /// error.
    private static func setExtradata(
        _ data: Data,
        on par: UnsafeMutablePointer<AVCodecParameters>
    ) throws {
        let padding = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buffer = av_malloc(data.count + padding) else {
            throw FFmpegError(code: -1, operation: "av_malloc(extradata)")
        }
        data.withUnsafeBytes { source in
            memcpy(buffer, source.baseAddress!, data.count)
        }
        memset(buffer.advanced(by: data.count), 0, padding)
        av_free(par.pointee.extradata)
        par.pointee.extradata = buffer.assumingMemoryBound(to: UInt8.self)
        par.pointee.extradata_size = Int32(data.count)
    }

    /// Put an `AVDOVIDecoderConfigurationRecord` on the stream as
    /// `AV_PKT_DATA_DOVI_CONF`, replacing whatever the source's own record said.
    ///
    /// `av_packet_side_data_add` takes ownership of the buffer (hence `av_malloc`)
    /// and replaces an existing entry of the same type, which is exactly the
    /// semantics wanted here: `avcodec_parameters_copy` already brought the P7
    /// record across.
    private static func setDolbyVisionConfiguration(
        _ configuration: DolbyVisionConfiguration,
        on par: UnsafeMutablePointer<AVCodecParameters>
    ) throws {
        let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        guard let buffer = av_malloc(size) else {
            throw FFmpegError(code: -1, operation: "av_malloc(dovi conf)")
        }
        let record = buffer.assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self)
        record.pointee = AVDOVIDecoderConfigurationRecord()
        record.pointee.dv_version_major = configuration.versionMajor
        record.pointee.dv_version_minor = configuration.versionMinor
        record.pointee.dv_profile = configuration.profile
        record.pointee.dv_level = configuration.level
        record.pointee.rpu_present_flag = configuration.rpuPresent ? 1 : 0
        record.pointee.el_present_flag = configuration.enhancementLayerPresent ? 1 : 0
        record.pointee.bl_present_flag = configuration.baseLayerPresent ? 1 : 0
        record.pointee.dv_bl_signal_compatibility_id = configuration.baseLayerSignalCompatibilityID

        guard av_packet_side_data_add(
            &par.pointee.coded_side_data,
            &par.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF,
            buffer,
            size,
            0
        ) != nil else {
            av_free(buffer)
            throw FFmpegError(code: -1, operation: "av_packet_side_data_add(DOVI_CONF)")
        }
    }

    /// Swap a demuxed packet's payload for rewritten bytes, in place.
    ///
    /// `av_packet_make_writable` first: the packet the demuxer handed us may
    /// share its buffer, and growing or writing through a shared buffer would
    /// corrupt whatever else holds a reference.
    private static func replacePayload(
        of packet: UnsafeMutablePointer<AVPacket>,
        with bytes: [UInt8]
    ) throws {
        try FFmpegError.check(av_packet_make_writable(packet), "av_packet_make_writable")
        let current = Int(packet.pointee.size)
        if bytes.count > current {
            try FFmpegError.check(
                av_grow_packet(packet, Int32(bytes.count - current)), "av_grow_packet"
            )
        } else if bytes.count < current {
            av_shrink_packet(packet, Int32(bytes.count))
        }
        // After grow the buffer may have moved, so read `data` only now.
        guard let destination = packet.pointee.data else {
            throw FFmpegError(code: -1, operation: "packet has no data after resize")
        }
        bytes.withUnsafeBytes { source in
            memcpy(destination, source.baseAddress!, bytes.count)
        }
    }

    /// A converter for this source, or `nil` when there is nothing to convert.
    ///
    /// Only Profile 7 qualifies. P5 has no HDR10 base to fall back to (its
    /// conversion target would be a different picture, not a different wrapper),
    /// 8.x is already single-layer, and a source with no DV configuration has no
    /// RPUs to rewrite.
    private func makeDolbyVisionConverter(video: VideoTrackInfo) -> DolbyVisionRPUConverter? {
        guard let dv = video.dolbyVision, dv.isDualLayer, dv.rpuPresent else { return nil }
        guard video.hevcConfiguration != nil else { return nil }
        // The prefix width comes from the record itself; a source whose hvcC we
        // couldn't parse never gets here (no `CODECS` string either, so it plays
        // media-direct).
        return DolbyVisionRPUConverter(lengthSize: video.nalUnitLengthSize)
    }

    // MARK: - Master playlist description

    /// The video half of the master's variant, or `nil` when this source can't
    /// be declared honestly (no `CODECS` string to be had, or a dynamic range
    /// this display isn't ready for). `nil` routes the session to the muxed
    /// shape — see the type's doc.
    ///
    /// - Parameter dolbyVision: the configuration to *declare*, which is the
    ///   converted 8.1 record for a P7 source being converted and the source's
    ///   own otherwise.
    private func makeVideoVariant(
        input: UnsafeMutablePointer<AVFormatContext>,
        video: VideoTrackInfo,
        dolbyVision: DolbyVisionConfiguration?
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
            dolbyVision: dolbyVision,
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
