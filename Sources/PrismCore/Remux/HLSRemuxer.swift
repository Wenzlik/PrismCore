import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Stream-copies one video + one audio elementary stream out of any container
/// libavformat can demux, into HLS-fMP4 on disk — using FFmpeg's own `hls`
/// muxer for the segmentation, playlist writing, and `EXT-X-MAP` handling.
///
/// This is the v0 producer: it starts at the head of the source and runs to
/// EOF, growing an EVENT playlist AVPlayer can start playing immediately.
/// Because it *stream-copies*, the bits AVPlayer receives are the source's
/// own: an EAC3+JOC (Atmos) track stays object audio all the way to HDMI, and
/// HDR metadata rides the untouched HEVC bitstream. The prior art proves this
/// segmentation is byte-equivalent to `ffmpeg -f hls -hls_segment_type fmp4`,
/// which is what Apple's HLS spec is validated against — that's exactly what
/// this muxer produces, because it IS that muxer.
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
        let (output, streamMap, bridge) = try makeOutput(input: input, selection: selection)
        defer { bridge?.close() }
        // Only this input stream goes through the bridge; everything else is
        // copied exactly as v0 did.
        let bridgedInputIndex = selection.audio?.mode == .bridge ? selection.audio?.index : nil
        var outputCtx: UnsafeMutablePointer<AVFormatContext>? = output
        defer {
            if let outputCtx {
                // Free the muxer context; `avio_closep` is owned by the hls
                // muxer for its segment files.
                avformat_free_context(outputCtx)
            }
        }

        try writeHeader(output: output)

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

            if let bridge, Int32(packet.pointee.stream_index) == bridgedInputIndex {
                // Timestamps on the way in stay in the source stream's time
                // base — the bridge's decoder is configured for it — and come
                // back out on the encoder's, so only one rescale is left.
                try bridge.feed(packet) { encoded in
                    try write(encoded, to: mapped, from: bridge.timeBase, output: output)
                }
                continue
            }

            let inStream = input.pointee.streams[Int(packet.pointee.stream_index)]!
            try write(packet, to: mapped, from: inStream.pointee.time_base, output: output)
        }

        // A cancelled session is being torn down, so flushing the encoder tail
        // would only add work; on EOF the tail is real audio the file has.
        if reachedEOF, let bridge, let mapped = bridgedInputIndex.flatMap({ streamMap[Int($0)] }) {
            try bridge.flush { encoded in
                try write(encoded, to: mapped, from: bridge.timeBase, output: output)
            }
        }

        // EOF or cancel: finalize. On EOF the hls muxer appends
        // `EXT-X-ENDLIST`, flipping the event playlist to a finished VOD.
        try FFmpegError.check(av_write_trailer(output), "av_write_trailer")
        outputCtx = nil
        avformat_free_context(output)
    }

    /// Rescale one packet onto an output stream and hand it to the muxer.
    /// `sourceTimeBase` is the packet's own base — the input stream's for
    /// copied packets, the encoder's for bridged ones.
    private func write(
        _ packet: UnsafeMutablePointer<AVPacket>,
        to outputIndex: Int32,
        from sourceTimeBase: AVRational,
        output: UnsafeMutablePointer<AVFormatContext>
    ) throws {
        let outStream = output.pointee.streams[Int(outputIndex)]!
        av_packet_rescale_ts(packet, sourceTimeBase, outStream.pointee.time_base)
        packet.pointee.stream_index = outputIndex
        packet.pointee.pos = -1
        try FFmpegError.check(
            av_interleaved_write_frame(output, packet),
            "av_interleaved_write_frame"
        )
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

    /// Allocate the `hls` output context and mirror the selected streams'
    /// codec parameters onto it. Returns the context plus an input→output
    /// stream index map.
    private func makeOutput(
        input: UnsafeMutablePointer<AVFormatContext>,
        selection: StreamSelection
    ) throws -> (UnsafeMutablePointer<AVFormatContext>, [Int: Int32], AudioBridge?) {
        let playlistPath = outputDirectory.appendingPathComponent("index.m3u8").path

        var outputOpt: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(
            avformat_alloc_output_context2(&outputOpt, nil, "hls", playlistPath),
            "avformat_alloc_output_context2(hls)"
        )
        guard let output = outputOpt else { throw Failure.noVideoStream }

        var streamMap: [Int: Int32] = [:]
        var bridge: AudioBridge?

        var plan: [(index: Int32, bridged: Bool)] = [(selection.videoIndex, false)]
        if let audio = selection.audio {
            plan.append((audio.index, audio.mode == .bridge))
        }

        for entry in plan {
            let inStream = input.pointee.streams[Int(entry.index)]!
            guard let outStream = avformat_new_stream(output, nil) else {
                throw FFmpegError(code: -1, operation: "avformat_new_stream")
            }
            if entry.bridged {
                // The output stream describes the *encoder*, not the source:
                // its codec, layout, and rate are what the muxer must write
                // into the audio sample entry. Built before `write_header`
                // because that's when the muxer reads them.
                let audioBridge = try AudioBridge(
                    codecpar: inStream.pointee.codecpar,
                    timeBase: inStream.pointee.time_base,
                    globalHeader: output.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0
                )
                try audioBridge.configure(outputStream: outStream)
                bridge = audioBridge
            } else {
                try FFmpegError.check(
                    avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar),
                    "avcodec_parameters_copy"
                )
                // The muxer picks its own tag space; a stale source tag (e.g. a
                // matroska V_MPEG4/ISO/AVC fourcc) would poison the mp4 boxes.
                outStream.pointee.codecpar.pointee.codec_tag = 0
            }
            streamMap[Int(entry.index)] = outStream.pointee.index
        }
        return (output, streamMap, bridge)
    }

    private func writeHeader(output: UnsafeMutablePointer<AVFormatContext>) throws {
        var options: OpaquePointer?
        defer { av_dict_free(&options) }

        av_dict_set(&options, "hls_segment_type", "fmp4", 0)
        av_dict_set(&options, "hls_time", String(segmentSeconds), 0)
        // EVENT: entries accumulate while we produce; `av_write_trailer`
        // appends ENDLIST. AVPlayer treats it as a growing seekable window.
        av_dict_set(&options, "hls_playlist_type", "event", 0)
        av_dict_set(&options, "hls_fmp4_init_filename", "init.mp4", 0)
        av_dict_set(
            &options, "hls_segment_filename",
            outputDirectory.appendingPathComponent("seg%05d.m4s").path, 0
        )
        // Keep every segment on disk — the loopback serves the whole history
        // (v0 has no eviction; the session dir is temporary and removed on
        // stop). Without this the muxer would delete segments behind the
        // live window for event playlists on some FFmpeg builds.
        av_dict_set(&options, "hls_list_size", "0", 0)
        // fMP4 segments need the moof-per-fragment layout.
        av_dict_set(&options, "movflags", "+frag_keyframe", 0)
        // Open question for the bridged-audio path, to settle on a real fixture:
        // the init segment (and with it the `dec3` sample entry) is written at
        // header time, before any EAC3 packet has passed through the muxer's
        // bitstream inspection. The prior art hits exactly this and defers the
        // moov (`+delay_moov`) so the box is filled from real packets. Whether
        // FFmpeg's hls muxer tolerates a deferred moov for its fMP4 init file is
        // not something a build-only check can answer, so this stays as-is until
        // a fixture says otherwise.

        try FFmpegError.check(
            avformat_write_header(output, &options),
            "avformat_write_header"
        )
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
