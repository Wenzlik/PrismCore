import Testing
import Foundation
import CoreMedia
import CoreVideo
import Libavformat
import Libavutil
@testable import PrismCore

/// What the software path can be proven headless: that a VP9 fixture decodes to
/// `CVPixelBuffer`s of the right shape with a monotonic, source-anchored
/// timeline, and what the linked FFmpeg actually provides.
///
/// What it can't: that a frame reached a display or a speaker. That boundary is
/// the sink protocols (`SampleBufferSinks.swift`), and
/// `SoftwarePlaybackPipelineTests` drives everything up to it.
@Suite("Software decode", .serialized)
struct SoftwareDecodeTests {

    // MARK: Helpers

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// Decode the first `limit` video frames of a fixture, straight through
    /// `SoftwareVideoDecoder` with no pipeline around it.
    private func decodeVideoFrames(
        of fixtureName: String,
        limit: Int,
        allowHardware: Bool
    ) throws -> (frames: [CMSampleBuffer], route: SoftwareVideoDecoder.PixelRoute) {
        let url = try fixture(fixtureName)

        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")

        let streamIndex = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        #expect(streamIndex >= 0)
        let stream = try #require(context.pointee.streams[Int(streamIndex)])

        let decoder = try SoftwareVideoDecoder(
            codecpar: stream.pointee.codecpar,
            timeBase: stream.pointee.time_base,
            averageFrameRate: stream.pointee.avg_frame_rate,
            allowHardware: allowHardware
        )
        defer { decoder.close() }

        var frames: [CMSampleBuffer] = []
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let allocated = try #require(packet)

        while frames.count < limit {
            let result = av_read_frame(context, allocated)
            if result == swift_AVERROR_EOF() {
                try decoder.decode(nil) { frames.append($0) }
                break
            }
            try FFmpegError.check(result, "av_read_frame")
            defer { av_packet_unref(allocated) }
            guard Int32(allocated.pointee.stream_index) == streamIndex else { continue }
            try decoder.decode(allocated) { frames.append($0) }
        }
        return (frames, decoder.route)
    }

    private func assertDecodedFrames(
        _ frames: [CMSampleBuffer],
        expectedCount: Int,
        width: Int,
        height: Int
    ) throws {
        #expect(frames.count == expectedCount)
        var previous: CMTime?
        for frame in frames {
            let pixelBuffer = try #require(CMSampleBufferGetImageBuffer(frame))
            #expect(CVPixelBufferGetWidth(pixelBuffer) == width)
            #expect(CVPixelBufferGetHeight(pixelBuffer) == height)
            // Biplanar 4:2:0 either way: NV12 from the CPU transfer, NV12 from
            // VideoToolbox. The layer takes both without a further conversion.
            #expect(CVPixelBufferGetPlaneCount(pixelBuffer) == 2)

            let pts = CMSampleBufferGetPresentationTimeStamp(frame)
            #expect(pts.isValid)
            if let previous {
                // Strictly increasing: receive_frame hands out presentation
                // order, and the display layer requires it.
                #expect(pts > previous, "PTS must increase (\(previous.seconds) → \(pts.seconds))")
            } else {
                // Anchored on the source's own axis, not rebased to zero.
                #expect(pts.seconds >= 0)
            }
            previous = pts
        }
    }

    // MARK: Tests

    @Test("VP9 decodes to 320×180 CVPixelBuffers with monotonic PTS (CPU path)")
    func vp9DecodesOnCPU() throws {
        let (frames, route) = try decodeVideoFrames(of: "vp9.webm", limit: 12, allowHardware: false)
        #expect(route == .softwareCopy)
        try assertDecodedFrames(frames, expectedCount: 12, width: 320, height: 180)
    }

    /// The same fixture with hardware allowed. Which route it ends up on is a
    /// property of the machine (VideoToolbox declines some sizes and profiles),
    /// so the route is reported rather than asserted — what must hold either way
    /// is that the frames are correct.
    @Test("VP9 decodes correctly with the VideoToolbox route allowed")
    func vp9DecodesWithHardwareAllowed() throws {
        let (frames, route) = try decodeVideoFrames(of: "vp9.webm", limit: 12, allowHardware: true)
        print("VP9 pixel route on this host: \(route.rawValue)")
        try assertDecodedFrames(frames, expectedCount: 12, width: 320, height: 180)
    }

    @Test("H.264 decodes through the same path (the interlaced-source detour's codec)")
    func h264Decodes() throws {
        let (frames, _) = try decodeVideoFrames(of: "h264_aac.mkv", limit: 8, allowHardware: false)
        try assertDecodedFrames(frames, expectedCount: 8, width: 320, height: 180)
    }

    @Test("AAC decodes to interleaved-float LPCM sample buffers")
    func aacDecodesToLPCM() throws {
        let url = try fixture("h264_aac.mkv")

        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")

        let streamIndex = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        let stream = try #require(context.pointee.streams[Int(streamIndex)])
        let decoder = try SoftwareAudioDecoder(
            codecpar: stream.pointee.codecpar,
            timeBase: stream.pointee.time_base
        )
        defer { decoder.close() }
        // The fixture is mono 44.1 kHz — the awkward rate whose 1024-sample
        // frames are 23.2199 ms, i.e. exactly the quantization AudioClock exists
        // for. The decoder must keep the source's rate rather than resample.
        #expect(decoder.outputFormat.sampleRate == 44_100)
        #expect(decoder.outputFormat.channelCount == 1)
        #expect(decoder.outputFormat.bytesPerFrame == 4)

        var buffers: [CMSampleBuffer] = []
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let allocated = try #require(packet)
        while buffers.count < 16 {
            let result = av_read_frame(context, allocated)
            if result == swift_AVERROR_EOF() { break }
            try FFmpegError.check(result, "av_read_frame")
            defer { av_packet_unref(allocated) }
            guard Int32(allocated.pointee.stream_index) == streamIndex else { continue }
            try decoder.decode(allocated) { buffers.append($0) }
        }

        #expect(buffers.count == 16)
        var expectedNextPTS: CMTime?
        for buffer in buffers {
            let description = try #require(CMSampleBufferGetFormatDescription(buffer))
            let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
            #expect(asbd.mFormatID == kAudioFormatLinearPCM)
            #expect(asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0)
            #expect(asbd.mSampleRate == 44_100)
            #expect(CMSampleBufferGetNumSamples(buffer) > 0)

            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if let expectedNextPTS {
                // The clock's whole job: consecutive buffers abut exactly, with
                // no sub-millisecond seam for the renderer to reconcile.
                #expect(pts == expectedNextPTS, "buffers must abut sample-exactly")
            }
            expectedNextPTS = CMTimeAdd(
                pts,
                CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(buffer)), timescale: 44_100)
            )
        }
    }

    /// Informational: prints what the *linked* FFmpeg provides, which is the
    /// only place that fact is written down (PrismCore doesn't own the build).
    /// Asserts only that the report is non-empty and that phase 7's headline
    /// codec is there — if VP9 ever went missing, this phase would be pointless.
    @Test("Decoder availability report")
    func decoderAvailability() {
        let report = SoftwareDecoderAvailability.report()
        print("=== FFmpeg decoders available to PrismCore's software path ===")
        print(report.summary)

        #expect(!report.entries.isEmpty)
        #expect(report.isAvailable("vp9"))
        let vp9 = report.entry(for: "vp9")
        #expect(vp9?.decoderName != nil)
    }
}
