import Testing
import Foundation
import CoreMedia
import CoreVideo
@testable import PrismCore
import Libavformat
import Libavcodec
import Libavutil

/// Phase 7's deinterlacer: verified-interlaced sources leave the native path
/// (AVPlayer never deinterlaces — stream-copy means combing), the software
/// path runs them through `bwdif` at field rate, and declared-but-progressive
/// broadcast carriage keeps its native route.
@Suite("Deinterlace")
struct DeinterlaceTests {

    private func fixture(_ name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return try #require(
            Bundle.module.url(forResource: "Fixtures/\(base)", withExtension: ext),
            "fixture \(name) missing"
        )
    }

    // MARK: - Probe + routing

    @Test("A really interlaced H.264 stream is verified, reported, and evicted from the native path")
    func interlacedIsDetectedAndRouted() throws {
        let info = try SourceProbe.probe(url: try fixture("h264_interlaced.mkv"))
        let video = try #require(info.video)
        #expect(video.fieldOrder.isInterlaced)
        #expect(video.copyability == .unsupported)
        #expect(info.nativeReadiness == .unsupported)

        let decision = try PrismCoreEngine.decide(for: info)
        #expect(decision.engine == .software)
        #expect(decision.reason.contains("interlaced"))
        #expect(decision.reason.contains("bwdif"))
    }

    @Test("Progressive frames in interlaced carriage keep the native path — the broadcast norm")
    func flaggedProgressiveKeepsStreamCopy() throws {
        // The container declares tt; every coded frame is progressive. The
        // declaration alone must not cost this source hardware decode.
        let info = try SourceProbe.probe(url: try fixture("h264_flagged_progressive.mkv"))
        let video = try #require(info.video)
        #expect(video.fieldOrder == .progressive)
        #expect(video.copyability == .streamCopy)

        let decision = try PrismCoreEngine.decide(for: info)
        #expect(decision.engine == .remux)
    }

    @Test("An ordinary progressive file is untouched by the verification")
    func progressiveIsUntouched() throws {
        let info = try SourceProbe.probe(url: try fixture("h264_aac.mkv"))
        let video = try #require(info.video)
        #expect(!video.fieldOrder.isInterlaced)
        #expect(video.copyability == .streamCopy)
    }

    // MARK: - Decoding

    @Test("bwdif doubles an interlaced stream to field rate, progressive frames out, PTS strictly increasing")
    func deinterlacedDecode() throws {
        let url = try fixture("h264_interlaced.mkv")

        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")

        let streamIndex = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        let stream = try #require(context.pointee.streams[Int(streamIndex)])

        let decoder = try SoftwareVideoDecoder(
            codecpar: stream.pointee.codecpar,
            timeBase: stream.pointee.time_base,
            averageFrameRate: stream.pointee.avg_frame_rate,
            allowHardware: false,
            deinterlace: true
        )
        defer { decoder.close() }

        var inputFrames = 0
        var frames: [CMSampleBuffer] = []
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let allocated = try #require(packet)

        while true {
            let result = av_read_frame(context, allocated)
            if result == swift_AVERROR_EOF() {
                try decoder.decode(nil) { frames.append($0) }
                break
            }
            try FFmpegError.check(result, "av_read_frame")
            defer { av_packet_unref(allocated) }
            guard Int32(allocated.pointee.stream_index) == streamIndex else { continue }
            inputFrames += 1
            try decoder.decode(allocated) { frames.append($0) }
        }

        // Field-rate: every interlaced frame becomes two progressive ones.
        // bwdif's first frame has no history so the very first field can be
        // absorbed — allow a small tolerance rather than pin an exact double.
        #expect(inputFrames > 60, "fixture should carry ~75 coded frames, got \(inputFrames)")
        #expect(
            frames.count >= inputFrames * 2 - 2 && frames.count <= inputFrames * 2,
            "expected ~\(inputFrames * 2) field-rate frames, got \(frames.count)"
        )

        var previous: CMTime?
        for frame in frames {
            let pixelBuffer = try #require(CMSampleBufferGetImageBuffer(frame))
            #expect(CVPixelBufferGetWidth(pixelBuffer) == 640)
            #expect(CVPixelBufferGetHeight(pixelBuffer) == 360)
            let pts = CMSampleBufferGetPresentationTimeStamp(frame)
            #expect(pts.isValid)
            if let previous {
                #expect(pts > previous, "PTS must increase (\(previous.seconds) → \(pts.seconds))")
            }
            previous = pts
        }
    }

    @Test("A progressive stream through an engaged deinterlacer passes 1:1 — deint=interlaced is per-frame")
    func progressiveThroughFilterPassesThrough() throws {
        // The pipeline engages the filter from the container flag; the flag
        // can lie (flagged-progressive carriage loaded directly into the
        // pipeline). The filter must not double or damage those frames.
        let url = try fixture("h264_flagged_progressive.mkv")

        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")

        let streamIndex = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        let stream = try #require(context.pointee.streams[Int(streamIndex)])

        let decoder = try SoftwareVideoDecoder(
            codecpar: stream.pointee.codecpar,
            timeBase: stream.pointee.time_base,
            averageFrameRate: stream.pointee.avg_frame_rate,
            allowHardware: false,
            deinterlace: true
        )
        defer { decoder.close() }

        var inputFrames = 0
        var outputFrames = 0
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let allocated = try #require(packet)
        while true {
            let result = av_read_frame(context, allocated)
            if result == swift_AVERROR_EOF() {
                try decoder.decode(nil) { _ in outputFrames += 1 }
                break
            }
            try FFmpegError.check(result, "av_read_frame")
            defer { av_packet_unref(allocated) }
            guard Int32(allocated.pointee.stream_index) == streamIndex else { continue }
            inputFrames += 1
            try decoder.decode(allocated) { _ in outputFrames += 1 }
        }

        #expect(inputFrames > 0)
        #expect(outputFrames == inputFrames, "progressive content must pass 1:1, got \(outputFrames)/\(inputFrames)")
    }
}
