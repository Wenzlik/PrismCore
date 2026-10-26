import Testing
import Foundation
@testable import PrismCore
import Libavcodec
import Libavformat
import Libavutil

/// The audio bridge's edges: what the system refuses even when the codec is
/// "copyable", rates an encoder cannot carry, and audio that ends before the
/// video.
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

    // MARK: - Audio that ends before the video

    /// Every rendition of a served session through `SegmentVerifier`, as `segverify` runs it.
    private func verifyServed(_ session: PrismCoreSession) async throws -> SegmentVerifier.Report {
        let playlist = try await session.start()
        return try await SegmentVerifier.verify(playlist: playlist, stallTimeout: .seconds(30))
    }

    @Test("A bridged alternate whose track ends early serves every slot, on a valid init")
    func shortBridgedAlternateIsServedWhole() async throws {
        // The MP2 track (stream 2) stops at 4 s of 14. Before: its lazy rendition was armed
        // at the playhead past its end, minted an E-AC-3 init from a cut with no packets
        // (zero-size `stsd`) and every segment under it failed to demux.
        let session = try PrismCoreSession(url: try fixture("h264_aac_mp2short_14s.mkv"))
        defer { Task { await session.stop() } }
        let report = try await verifyServed(session)
        #expect(!report.hasErrors && report.isComplete, "\(report.findings)")
        let alternate = try #require(report.playlists.first { $0.uri.hasPrefix("audio1/") })
        #expect(alternate.segmentsChecked == 3)
        #expect(alternate.audioFrames > 0)
    }

    @Test("A bridged DEFAULT track that ends early plays silence to the video's end, no 404")
    func shortBridgedDefaultIsFilledToTheEnd() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_mp2short_14s.mkv"), preferredAudioStreamIndex: 2)
        defer { Task { await session.stop() } }
        let report = try await verifyServed(session)
        #expect(!report.hasErrors && report.isComplete, "\(report.findings)")
        let main = try #require(report.playlists.first { $0.uri.hasPrefix("audio0/") })
        #expect(main.segmentsChecked == 3)
        // The last slot (8–14 s) is all silence and opens on its own boundary, not
        // where the audio stopped (4 s): playback follows `tfdt`.
        let work = await session.workDirectory.appendingPathComponent("audio0")
        let initSegment = try Data(contentsOf: work.appendingPathComponent("init.mp4"))
        let last = try Data(contentsOf: work.appendingPathComponent("seg00002.m4s"))
        let opens = try Self.firstPacketSeconds(initSegment: initSegment, media: last)
        #expect(abs(opens - 8) < 0.1, "the silent slot opens at \(opens) s")
        // 8–14 s of 1536-sample E-AC-3 frames; without the silence there were none.
        #expect(main.audioFrames > 300, "\(main.audioFrames) frames")
    }

    @Test("A gap of two slots in a bridged track: the first is silence on its boundary, the audio after keeps its time")
    func gapInBridgedTrackKeepsTheTimeline() async throws {
        // 26 s planned as 2 + 6 + 6 + 6 + 6; MP2 audio 0–4 s and 21–26 s. Before: the 8–14 s
        // slot answered 404, and movenc closed the 17 s gap, so the resumed audio played at ~4 s.
        let session = try PrismCoreSession(url: try fixture("h264_mp2gap_26s.mkv"))
        defer { Task { await session.stop() } }
        let report = try await verifyServed(session)
        let work = await session.workDirectory.appendingPathComponent("audio0")
        let initSegment = try Data(contentsOf: work.appendingPathComponent("init.mp4"))
        func opens(_ index: Int) throws -> Double {
            try Self.firstPacketSeconds(
                initSegment: initSegment,
                media: Data(contentsOf: work.appendingPathComponent(String(format: "seg%05d.m4s", index)))
            )
        }
        #expect(abs(try opens(2) - 8) < 0.1, "the silent slot")
        // The slot right before resumed audio stays empty (it may hold that audio's late
        // interleave), as it always did; the resumed audio sits at its own time.
        let resumed = try [3, 4].map { try? opens($0) }.compactMap { $0 }.min()
        #expect((resumed ?? 0) > 20.9, "resumed audio opens at \(String(describing: resumed)) s")
        #expect(!report.findings.contains { $0.severity == .error && $0.location.contains("seg00002") }, "\(report.findings)")
    }

    /// Opens init + one fragment as one file and returns the first packet's presentation time.
    private static func firstPacketSeconds(initSegment: Data, media: Data) throws -> Double {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreHardening-\(UUID().uuidString).mp4")
        try (initSegment + media).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, file.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        try FFmpegError.check(av_read_frame(context, pkt), "av_read_frame")
        defer { av_packet_unref(pkt) }
        let timeBase = context.pointee.streams[Int(pkt.pointee.stream_index)]!.pointee.time_base
        let pts = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
        return Double(pts) * av_q2d(timeBase)
    }

    @Test("Silence pads from where the output stands, or from the given start when nothing was heard")
    func padSilenceContinuesOrAnchors() throws {
        let target = try #require(
            [AV_CODEC_ID_EAC3, AV_CODEC_ID_AAC].first { avcodec_find_encoder($0) != nil }, "no bridge encoder"
        )
        func bridge() throws -> AudioBridge {
            let par = avcodec_parameters_alloc()!
            defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }
            par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
            par.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
            par.pointee.format = AV_SAMPLE_FMT_S16.rawValue
            par.pointee.sample_rate = 48_000
            par.pointee.bits_per_coded_sample = 16
            par.pointee.block_align = 4
            av_channel_layout_default(&par.pointee.ch_layout, 2)
            return try AudioBridge(
                codecpar: par, timeBase: AVRational(num: 1, den: 48_000), globalHeader: false, targetCodec: target
            )
        }
        // Nothing heard: the silence starts where it is told to, and runs to the end asked.
        let fresh = try bridge()
        defer { fresh.close() }
        var stamps: [(Int64, Int64)] = []
        let collect: AudioBridge.Emit = { stamps.append(($0.pointee.pts, $0.pointee.duration)) }
        try fresh.padSilence(from: 96_000, until: 144_000, final: true, emit: collect)
        try fresh.flush(emit: collect)
        // The encoder's own delay (E-AC-3's 256 samples, AAC's priming) puts its
        // first packet up to a frame before the first sample.
        let first = try #require(stamps.first?.0)
        #expect(first <= 96_000 && first > 96_000 - 2_048, "starts at \(first)")
        let end = stamps.map { $0.0 + $0.1 }.max() ?? 0
        #expect(end >= 144_000 && end < 144_000 + 2 * 1_536, "ends at \(end)")

        // Audio heard first: the silence continues it (the start is ignored), and a
        // second pad after the end of the source does not end the decoder twice.
        let heard = try bridge()
        defer { heard.close() }
        stamps = []
        let packet = av_packet_alloc()!
        defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
        av_new_packet(packet, 48_000 * 4)
        memset(packet.pointee.data, 0, 48_000 * 4)
        packet.pointee.pts = 0
        packet.pointee.duration = 48_000
        try heard.feed(packet, emit: collect)
        // Continuing (the start is within tolerance of where the output stands)…
        try heard.padSilence(from: 48_000, until: 96_000, final: false, emit: collect)
        // …and across a gap: a new timeline at the start given.
        try heard.padSilence(from: 120_000, until: 144_000, final: true, emit: collect)
        try heard.flush(emit: collect)
        let opening = try #require(stamps.first?.0)
        #expect(opening <= 0 && opening > -2_048, "starts at \(opening)")
        let pts = stamps.map(\.0)
        #expect(pts == pts.sorted(), "monotonic")
        let last = stamps.map { $0.0 + $0.1 }.max() ?? 0
        #expect(last >= 144_000 && last < 144_000 + 2 * 1_536, "ends at \(last)")
        // Nothing between the continued silence's end and the new timeline's start.
        #expect(!stamps.contains { $0.0 >= 96_000 + 1_536 && $0.0 < 120_000 - 1_536 }, "\(stamps.map(\.0))")
    }
}
