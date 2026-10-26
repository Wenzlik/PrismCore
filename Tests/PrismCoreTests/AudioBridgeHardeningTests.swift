import Testing
import Foundation
@testable import PrismCore
import Libavcodec
import Libavutil

/// The audio bridge's edges: rates an encoder cannot carry.
@Suite("Audio bridge hardening")
struct AudioBridgeHardeningTests {

    private func fixture(_ name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return try #require(
            Bundle.module.url(forResource: "Fixtures/\(base)", withExtension: ext),
            "fixture \(name) missing"
        )
    }

    // MARK: - EAC3 sample rate

    @Test("A 96 kHz source reaches EAC3 at 48 kHz", arguments: [96_000, 88_200, 192_000])
    func eac3RateIsCapped(rate: Int32) throws {
        try #require(avcodec_find_encoder(AV_CODEC_ID_EAC3) != nil, "this FFmpeg build has no eac3 encoder")
        let par = avcodec_parameters_alloc()!
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        par.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        par.pointee.sample_rate = rate
        par.pointee.bits_per_coded_sample = 16
        par.pointee.block_align = 4
        av_channel_layout_default(&par.pointee.ch_layout, 2)
        let bridge = try AudioBridge(
            codecpar: par, timeBase: AVRational(num: 1, den: rate), globalHeader: false, targetCodec: AV_CODEC_ID_EAC3
        )
        defer { bridge.close() }
        #expect(bridge.timeBase.den == 48_000)

        // A second of input comes out as a second at the new rate.
        var last: Int64 = -1
        let packet = av_packet_alloc()!
        defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
        av_new_packet(packet, rate * 4)
        memset(packet.pointee.data, 0, Int(rate * 4))
        packet.pointee.pts = 0
        packet.pointee.duration = Int64(rate)
        try bridge.feed(packet) { last = max(last, $0.pointee.pts + $0.pointee.duration) }
        try bridge.flush { last = max(last, $0.pointee.pts + $0.pointee.duration) }
        #expect(abs(last - 48_000) <= 1536 * 2, "output ends at \(last) of 48 000")
    }
}
