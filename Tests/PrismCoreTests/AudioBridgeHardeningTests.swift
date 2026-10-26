import Testing
import Foundation
@testable import PrismCore
import Libavcodec
import Libavutil

/// The audio bridge's edges: what the system refuses even when the codec is
/// "copyable", and rates an encoder cannot carry.
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

    /// STREAMINFO with the given block sizes; the rest is zero (the parser reads no further).
    private func streamInfo(min: Int, max: Int) -> [UInt8] {
        [UInt8(min >> 8), UInt8(min & 0xFF), UInt8(max >> 8), UInt8(max & 0xFF)] + Array(repeating: 0, count: 30)
    }

    private func blockSizes(_ bytes: [UInt8]) -> (min: Int, max: Int)? {
        bytes.withUnsafeBufferPointer { FLACStreamInfo.blockSizes(extradata: $0) }
    }

    // MARK: - FLAC block size

    @Test("STREAMINFO block sizes are read bare or behind fLaC and its block header")
    func flacStreamInfoForms() throws {
        let bare = try #require(blockSizes(streamInfo(min: 128, max: 4096)))
        #expect(bare.min == 128 && bare.max == 4096)
        let framed = Array("fLaC".utf8) + [0x80, 0, 0, 34] + streamInfo(min: 4096, max: 4096)
        #expect(blockSizes(framed)?.min == 4096)
        // A first block that is not STREAMINFO, or one of the wrong length, says nothing.
        #expect(blockSizes(Array("fLaC".utf8) + [0x84, 0, 0, 34] + streamInfo(min: 16, max: 16)) == nil)
        #expect(blockSizes(Array("fLaC".utf8) + [0x00, 0, 0, 40] + streamInfo(min: 16, max: 16)) == nil)
        #expect(blockSizes(Array(streamInfo(min: 16, max: 16).prefix(20))) == nil)
    }

    @Test("CoreMedia's 192-sample floor decides the copy; unreadable extradata keeps it")
    func flacCopyability() {
        func copyable(_ bytes: [UInt8]) -> Bool {
            bytes.withUnsafeBufferPointer {
                FLACStreamInfo.isStreamCopyable(extradata: $0.baseAddress, size: Int32($0.count))
            }
        }
        #expect(!copyable(streamInfo(min: 191, max: 4096)))
        #expect(copyable(streamInfo(min: 192, max: 192)))
        #expect(copyable(streamInfo(min: 4096, max: 4096)))
        #expect(copyable([1, 2, 3]))
        #expect(FLACStreamInfo.isStreamCopyable(extradata: nil, size: 0))
    }

    @Test("A FLAC the system would refuse is bridged; every other copyable track still copies")
    func refusedFLACIsBridged() {
        let refused = HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_FLAC, refusesStreamCopy: true)
        let fine = HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_FLAC)
        let canDecode = AudioBridge.canDecodeForBoost(codecID: AV_CODEC_ID_FLAC)
        #expect(HLSRemuxer.route(refused)?.mode == (canDecode ? HLSRemuxer.AudioRouteMode.bridge : nil))
        #expect(HLSRemuxer.route(fine)?.mode == .streamCopy)
        // The single-track choice: the refused FLAC is not "copyable" when a
        // copyable track exists, and is still carried when it is the only one.
        let ac3 = HLSRemuxer.AudioCandidate(index: 3, codecID: AV_CODEC_ID_AC3)
        #expect(HLSRemuxer.chooseAudio(candidates: [refused, ac3], best: nil)?.index == 3)
        if canDecode {
            #expect(HLSRemuxer.chooseAudio(candidates: [refused], best: nil) == .init(index: 1, mode: .bridge))
            #expect(HLSRemuxer.routeAll(candidates: [refused, ac3], best: 1).map(\.mode) == [.bridge, .streamCopy])
        }
    }

    @Test("A FLAC track declaring 128-sample blocks is reported and served bridged, not copied")
    func smallBlockFLACFixtureIsBridged() async throws {
        let url = try fixture("h264_flac128_2s.mkv")
        let info = try SourceProbe.probe(url: url)
        let audio = try #require(info.audioTracks.first)
        #expect(audio.codecName == "flac")
        try #require(AudioBridge.canDecodeForBoost(codecID: AV_CODEC_ID_FLAC), "no flac decoder or bridge encoder")
        #expect(audio.copyability == .requiresAudioBridge)

        let session = try PrismCoreSession(url: url)
        _ = try await session.start()
        defer { Task { await session.stop() } }
        #expect(session.audioTrackDeliveries.first { $0.streamIndex == 1 }?.delivery == .bridged)
        let master = try String(contentsOf: await session.workDirectory.appendingPathComponent("master.m3u8"), encoding: .utf8)
        #expect(!master.contains("fLaC"), "\(master)")
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
