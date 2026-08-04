import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Stream-copies one video + one audio elementary stream out of any container
/// libavformat can demux, into HLS-fMP4 on disk — segmenting with our own
/// `FMP4SegmentWriter` (the `hls` muxer is absent from MPVKit's libavformat
/// build; see that type's doc) and writing the playlist ourselves.
///
/// This is the v0 producer: it starts at the head of the source and runs to
/// EOF, growing an EVENT playlist AVPlayer can start playing immediately.
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
/// Not in v0 (by design, see README roadmap): demand-driven seeking, DV/HDR
/// master-playlist signaling, multi-audio / subtitle tracks.
final class HLSRemuxer: @unchecked Sendable {

    /// How the selected audio stream reaches the output.
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

    struct StreamSelection {
        let videoIndex: Int32
        let audio: AudioRoute?
    }

    /// One audio stream as the routing decision sees it. Deliberately a plain
    /// value so the decision itself is pure and testable without a demuxer.
    struct AudioCandidate: Equatable {
        let index: Int32
        let codecID: AVCodecID
    }

    enum Failure: Error {
        case noVideoStream
        /// The video codec can't ride AVPlayer's HLS-fMP4 pipeline (VP9,
        /// MPEG-2, …) — the caller should route this source to Prism/libmpv.
        case videoCodecNotNativelyPlayable(String)
    }

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

    /// Set by `cancel()`; checked once per packet in the copy loop.
    private let cancelled = LockedFlag()

    init(
        sourceURL: URL,
        httpHeaders: [String: String] = [:],
        outputDirectory: URL,
        segmentSeconds: Int = 6
    ) {
        self.sourceURL = sourceURL
        self.httpHeaders = httpHeaders
        self.outputDirectory = outputDirectory
        self.segmentSeconds = segmentSeconds
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

        let selection = try selectStreams(input)

        // Bridge first — its encoder parameters must be on the output stream
        // BEFORE write_header (empty_moov writes the sample entries then).
        var bridge: AudioBridge?
        defer { bridge?.close() }
        var plan: [FMP4SegmentWriter.StreamPlan] = [.init(inputIndex: selection.videoIndex)]
        if let audio = selection.audio {
            if audio.mode == .bridge {
                let inStream = input.pointee.streams[Int(audio.index)]!
                let audioBridge = try AudioBridge(
                    codecpar: inStream.pointee.codecpar,
                    timeBase: inStream.pointee.time_base,
                    // mp4/mov is a global-header muxer by definition; the
                    // encoder's extradata must land in codecpar, not in-band.
                    globalHeader: true
                )
                bridge = audioBridge
                plan.append(.init(inputIndex: audio.index) { outStream in
                    try audioBridge.configure(outputStream: outStream)
                })
            } else {
                plan.append(.init(inputIndex: audio.index))
            }
        }
        let bridgedInputIndex = selection.audio?.mode == .bridge ? selection.audio?.index : nil

        let writer = FMP4SegmentWriter()
        _ = try writer.open(input: input, plan: plan)   // delay_moov: header emits nothing
        let streamMap = writer.streamMap
        let playlist = MediaPlaylistWriter(directory: outputDirectory)

        // Segmentation state, tracked on the INPUT video stream's time base
        // (the packet still carries it when the cut decision is made).
        let videoTimeBase = input.pointee.streams[Int(selection.videoIndex)]!.pointee.time_base
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
                try initSegment.write(to: outputDirectory.appendingPathComponent("init.mp4"), options: .atomic)
            }
            guard !media.isEmpty, let start = segmentStartPTS else { return }
            let file = String(format: "seg%05d.m4s", segmentIndex)
            try media.write(to: outputDirectory.appendingPathComponent(file), options: .atomic)
            try playlist.appendSegment(
                duration: max(0.001, Double(endPTS - start) * tickSeconds),
                file: file
            )
            segmentIndex += 1
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
                // surfaces here ends the remux (the playlist stays valid up
                // to the last written segment).
                throw FFmpegError(code: readResult, operation: "av_read_frame")
            }
            defer { av_packet_unref(packet) }

            guard let mapped = streamMap[Int(packet.pointee.stream_index)] else { continue }

            // Cut BEFORE writing a boundary keyframe, so the keyframe opens
            // the next segment (every segment starts decodable on its own —
            // what EXT-X-INDEPENDENT-SEGMENTS promises).
            if Int32(packet.pointee.stream_index) == selection.videoIndex,
               packet.pointee.pts != swift_AV_NOPTS_VALUE() {
                let pts = packet.pointee.pts
                let isKey = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
                if isKey {
                    if segmentStartPTS == nil {
                        segmentStartPTS = pts
                        nextBoundaryPTS = pts + boundaryStep
                    } else if pts >= nextBoundaryPTS {
                        try emitSegment(endPTS: pts)
                        segmentStartPTS = pts
                        nextBoundaryPTS = pts + boundaryStep
                    }
                }
                lastVideoEndPTS = pts + max(packet.pointee.duration, 0)
            }

            if let bridge, Int32(packet.pointee.stream_index) == bridgedInputIndex {
                // Timestamps on the way in stay in the source stream's time
                // base — the bridge's decoder is configured for it — and come
                // back out on the encoder's, so only one rescale is left.
                try bridge.feed(packet) { encoded in
                    try write(encoded, to: mapped, from: bridge.timeBase, writer: writer)
                }
                continue
            }

            let inStream = input.pointee.streams[Int(packet.pointee.stream_index)]!
            try write(packet, to: mapped, from: inStream.pointee.time_base, writer: writer)
        }

        // A cancelled session is being torn down, so flushing the encoder tail
        // would only add work; on EOF the tail is real audio the file has.
        if reachedEOF, let bridge, let mapped = bridgedInputIndex.flatMap({ streamMap[Int($0)] }) {
            try bridge.flush { encoded in
                try write(encoded, to: mapped, from: bridge.timeBase, writer: writer)
            }
        }

        // Final segment: whatever is buffered since the last cut, plus the
        // trailer's tail bytes, is one segment. A sub-6s source cuts here for
        // the first time, so this can also mint the init segment.
        let closingPTS = lastVideoEndPTS ?? nextBoundaryPTS
        let (initSegment, media) = try writer.cutSegment()
        if let initSegment, !initSegment.isEmpty {
            try initSegment.write(to: outputDirectory.appendingPathComponent("init.mp4"), options: .atomic)
        }
        var finalSegment = media
        finalSegment.append(try writer.finish())
        if !finalSegment.isEmpty, let start = segmentStartPTS {
            let file = String(format: "seg%05d.m4s", segmentIndex)
            try finalSegment.write(to: outputDirectory.appendingPathComponent(file), options: .atomic)
            try playlist.appendSegment(
                duration: max(0.001, Double(closingPTS - start) * tickSeconds),
                file: file
            )
        }
        if reachedEOF {
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

    private func selectStreams(_ input: UnsafeMutablePointer<AVFormatContext>) throws -> StreamSelection {
        let videoIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0 else { throw Failure.noVideoStream }

        let videoCodec = input.pointee.streams[Int(videoIndex)]!.pointee.codecpar.pointee.codec_id
        guard Self.copyableVideo.contains(videoCodec) else {
            let name = avcodec_get_name(videoCodec).map { String(cString: $0) } ?? "unknown"
            throw Failure.videoCodecNotNativelyPlayable(name)
        }

        var candidates: [AudioCandidate] = []
        for index in 0..<Int(input.pointee.nb_streams) {
            let par = input.pointee.streams[index]!.pointee.codecpar.pointee
            guard par.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            candidates.append(AudioCandidate(index: Int32(index), codecID: par.codec_id))
        }
        let bestAudio = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)

        return StreamSelection(
            videoIndex: videoIndex,
            audio: Self.chooseAudio(candidates: candidates, best: bestAudio >= 0 ? bestAudio : nil)
        )
    }

    /// Decide which audio stream to carry, and how.
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

}

/// `AVERROR_EOF` is a macro Swift can't import; recompute it the way the
/// header does: `FFERRTAG('E','O','F',' ')` negated.
func swift_AVERROR_EOF() -> Int32 {
    let tag = (Int32(UInt8(ascii: "E"))) | (Int32(UInt8(ascii: "O")) << 8)
        | (Int32(UInt8(ascii: "F")) << 16) | (Int32(UInt8(ascii: " ")) << 24)
    return -tag
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
