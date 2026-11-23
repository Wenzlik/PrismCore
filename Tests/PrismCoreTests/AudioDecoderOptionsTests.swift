import Testing
import Foundation
import Libavcodec
import Libavformat
import Libavutil
@testable import PrismCore

/// AC-3 / E-AC-3 decoded inside the engine must come out at full dynamics,
/// like the stream-copied track AVFoundation decodes — FFmpeg's default
/// `drc_scale` of 1 made every engine decode ~2 dB quieter in dialogue.
@Suite("Audio decoder options")
struct AudioDecoderOptionsTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// `drc_scale` as the decoder holds it, or the lookup's error code.
    private func drcScale(_ context: UnsafeMutablePointer<AVCodecContext>) -> (result: Int32, value: Double) {
        var value = -1.0
        let result = av_opt_get_double(context.pointee.priv_data, "drc_scale", 0, &value)
        return (result, value)
    }

    /// Opens a bare decoder context for `codecID`, applying the helper first
    /// when asked, and hands back its `drc_scale` after `avcodec_open2`.
    private func openedDRCScale(_ codecID: AVCodecID, applyingHelper: Bool) throws -> Double {
        let decoder = try #require(avcodec_find_decoder(codecID), "no decoder for \(codecID.rawValue)")
        var context = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&context) }
        let opened = try #require(context)
        if applyingHelper { AudioDecoderOptions.apply(to: opened) }
        try FFmpegError.check(avcodec_open2(opened, decoder, nil), "avcodec_open2")
        let read = drcScale(opened)
        try FFmpegError.check(read.result, "av_opt_get_double(drc_scale)")
        return read.value
    }

    @Test("AC-3 and E-AC-3 decoders open with dynamic range compression off")
    func dolbyDecodersOpenWithoutDRC() throws {
        for codecID in [AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3] {
            // The untouched default proves the read is real: a 0 that any
            // lookup would return would make the second expectation vacuous.
            #expect(try openedDRCScale(codecID, applyingHelper: false) == 1, "codec \(codecID.rawValue)")
            #expect(try openedDRCScale(codecID, applyingHelper: true) == 0, "codec \(codecID.rawValue)")
        }
    }

    @Test("Other audio decoders are left exactly as they were")
    func otherDecodersAreUntouched() throws {
        let decoder = try #require(avcodec_find_decoder(AV_CODEC_ID_AAC))
        var context = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&context) }
        let opened = try #require(context)
        let before = drcScale(opened)
        AudioDecoderOptions.apply(to: opened)
        let after = drcScale(opened)
        #expect(before.result == after.result)
        #expect(before.value == after.value)
        #expect(avcodec_open2(opened, decoder, nil) == 0)
    }

    /// The first audio stream of a fixture, with its input kept open for `body`.
    private func withAudioStream<T>(
        _ name: String, _ body: (UnsafeMutablePointer<AVStream>) throws -> T
    ) throws -> T {
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, try fixture(name).path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let index = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        try FFmpegError.check(index, "av_find_best_stream")
        return try body(try #require(context.pointee.streams[Int(index)]))
    }

    @Test("The software path's AC-3 decoder runs without DRC")
    func softwareAudioDecoderSkipsDRC() throws {
        try withAudioStream("h264_ac3_51_20s.mkv") { stream in
            let decoder = try SoftwareAudioDecoder(
                codecpar: stream.pointee.codecpar,
                timeBase: stream.pointee.time_base
            )
            defer { decoder.close() }
            let context = try #require(decoder.codecContext)
            #expect(drcScale(context).value == 0)
        }
    }

    @Test("The bridge's E-AC-3 decoder runs without DRC")
    func audioBridgeSkipsDRC() throws {
        try withAudioStream("hevc_eac3.mkv") { stream in
            let bridge = try AudioBridge(
                codecpar: stream.pointee.codecpar,
                timeBase: stream.pointee.time_base,
                globalHeader: false
            )
            defer { bridge.close() }
            let context = try #require(bridge.decoderCtx)
            #expect(drcScale(context).value == 0)
        }
    }
}
