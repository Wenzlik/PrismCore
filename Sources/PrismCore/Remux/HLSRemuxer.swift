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
/// Not in v0 (by design, see README roadmap): demand-driven seeking, the
/// audio bridge for non-streamable codecs, DV/HDR master-playlist signaling,
/// multi-audio / subtitle tracks.
final class HLSRemuxer: @unchecked Sendable {

    struct StreamSelection {
        let videoIndex: Int32
        let audioIndex: Int32?
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
        let (output, streamMap) = try makeOutput(input: input, selection: selection)
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
        while !cancelled.isSet {
            let readResult = av_read_frame(input, packet)
            if readResult == swift_AVERROR_EOF() { break }
            if readResult < 0 {
                // Transient read errors on network sources: the reconnect
                // options above handle the socket; anything that still
                // surfaces here ends the remux (the playlist stays valid up
                // to the last written segment).
                throw FFmpegError(code: readResult, operation: "av_read_frame")
            }
            defer { av_packet_unref(packet) }

            guard let mapped = streamMap[Int(packet.pointee.stream_index)] else { continue }

            let inStream = input.pointee.streams[Int(packet.pointee.stream_index)]!
            let outStream = output.pointee.streams[Int(mapped)]!
            av_packet_rescale_ts(packet, inStream.pointee.time_base, outStream.pointee.time_base)
            packet.pointee.stream_index = mapped
            packet.pointee.pos = -1

            try FFmpegError.check(
                av_interleaved_write_frame(output, packet),
                "av_interleaved_write_frame"
            )
        }

        // EOF or cancel: finalize. On EOF the hls muxer appends
        // `EXT-X-ENDLIST`, flipping the event playlist to a finished VOD.
        try FFmpegError.check(av_write_trailer(output), "av_write_trailer")
        outputCtx = nil
        avformat_free_context(output)
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

        var audioIndex = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        if audioIndex >= 0 {
            let audioCodec = input.pointee.streams[Int(audioIndex)]!.pointee.codecpar.pointee.codec_id
            if !Self.copyableAudio.contains(audioCodec) {
                // v0: prefer ANY copyable audio stream over the "best" one the
                // phase-3 bridge would transcode. A DTS-main + AC3-compat
                // source keeps sound through the AC3 track.
                audioIndex = -1
                for index in 0..<Int(input.pointee.nb_streams) {
                    let par = input.pointee.streams[index]!.pointee.codecpar.pointee
                    if par.codec_type == AVMEDIA_TYPE_AUDIO, Self.copyableAudio.contains(par.codec_id) {
                        audioIndex = Int32(index)
                        break
                    }
                }
            }
        }
        return StreamSelection(videoIndex: videoIndex, audioIndex: audioIndex >= 0 ? audioIndex : nil)
    }

    /// Allocate the `hls` output context and mirror the selected streams'
    /// codec parameters onto it. Returns the context plus an input→output
    /// stream index map.
    private func makeOutput(
        input: UnsafeMutablePointer<AVFormatContext>,
        selection: StreamSelection
    ) throws -> (UnsafeMutablePointer<AVFormatContext>, [Int: Int32]) {
        let playlistPath = outputDirectory.appendingPathComponent("index.m3u8").path

        var outputOpt: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(
            avformat_alloc_output_context2(&outputOpt, nil, "hls", playlistPath),
            "avformat_alloc_output_context2(hls)"
        )
        guard let output = outputOpt else { throw Failure.noVideoStream }

        var streamMap: [Int: Int32] = [:]
        for index in [selection.videoIndex].compactMap({ $0 }) + (selection.audioIndex.map { [$0] } ?? []) {
            let inStream = input.pointee.streams[Int(index)]!
            guard let outStream = avformat_new_stream(output, nil) else {
                throw FFmpegError(code: -1, operation: "avformat_new_stream")
            }
            try FFmpegError.check(
                avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar),
                "avcodec_parameters_copy"
            )
            // The muxer picks its own tag space; a stale source tag (e.g. a
            // matroska V_MPEG4/ISO/AVC fourcc) would poison the mp4 boxes.
            outStream.pointee.codecpar.pointee.codec_tag = 0
            streamMap[Int(index)] = outStream.pointee.index
        }
        return (output, streamMap)
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
