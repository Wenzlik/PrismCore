import Testing
import Foundation
import AVFoundation
import Libavcodec
import Libavformat
import Libavutil
@testable import PrismCore

/// TrueHD Atmos: what the engine can and cannot keep of it, and that it says
/// which. The objects themselves cannot be carried (no public decoder of the
/// object substream, no JOC encoder — see the README); what is pinned here is
/// that (1) the source's Atmos is read off the bitstream, (2) every track
/// reports `objectAudio` honestly, and (3) `.lossless` bridging delivers the
/// whole channel bed bit-exact, 7.1 where the source has it.
@Suite("TrueHD Atmos")
struct TrueHDAtmosTests {

    // MARK: - Major sync

    /// The first access unit of `h264_truehd_14s.mkv`'s 5.1 track, as the
    /// demuxer hands it over: 4-byte unit header (152 bytes), then the major
    /// sync — two substreams, `substream_info` 0x3C, no Atmos.
    private static func restartUnit(substreams: UInt8 = 2, substreamInfo: UInt8 = 0x3C) -> [UInt8] {
        var unit: [UInt8] = [
            0xD0, 0x4C, 0xFF, 0xD8,
            0xF8, 0x72, 0x6F, 0xBA, 0x00, 0x07, 0x80, 0x0F, 0xB7, 0x52, 0x00, 0x00,
            0x00, 0x00, 0x8C, 0x7F, (substreams << 4) | 0x00, substreamInfo,
        ]
        unit += Array(repeating: 0, count: 152 - unit.count)
        return unit
    }

    /// A non-restart unit: header only, no major sync.
    private static let plainUnit: [UInt8] = [0x10, 0x08] + Array(repeating: 0x11, count: 14)

    @Test("A TrueHD major sync answers whether the 16-channel presentation is there")
    func majorSyncReadsAtmos() {
        #expect(TrueHDMajorSync.carriesObjectAudio(in: Self.restartUnit()) == false)
        // Four substreams with the top bit of substream_info: Atmos.
        #expect(TrueHDMajorSync.carriesObjectAudio(in: Self.restartUnit(substreams: 4, substreamInfo: 0xBC)) == true)
        // Either half alone is not.
        #expect(TrueHDMajorSync.carriesObjectAudio(in: Self.restartUnit(substreams: 4, substreamInfo: 0x3C)) == false)
        #expect(TrueHDMajorSync.carriesObjectAudio(in: Self.restartUnit(substreams: 3, substreamInfo: 0xBC)) == false)
    }

    @Test("Units without a major sync leave the question open; the walk finds a later restart unit")
    func majorSyncWalksUnits() {
        #expect(TrueHDMajorSync.carriesObjectAudio(in: Self.plainUnit) == nil)
        let packet = Self.plainUnit + Self.restartUnit(substreams: 4, substreamInfo: 0x80)
        #expect(TrueHDMajorSync.carriesObjectAudio(in: packet) == true)
    }

    @Test("Legacy MLP, a missing signature, truncation and a zero length are never Atmos")
    func majorSyncRejectsTheRest() {
        var mlp = Self.restartUnit(substreams: 4, substreamInfo: 0x80)
        mlp[7] = 0xBB
        #expect(TrueHDMajorSync.carriesObjectAudio(in: mlp) == false)
        var unsigned = Self.restartUnit(substreams: 4, substreamInfo: 0x80)
        unsigned[12] = 0x00
        #expect(TrueHDMajorSync.carriesObjectAudio(in: unsigned) == nil)
        #expect(TrueHDMajorSync.carriesObjectAudio(in: Array(Self.restartUnit().prefix(20))) == nil)
        #expect(TrueHDMajorSync.carriesObjectAudio(in: [0x00, 0x00, 0xF8, 0x72, 0x6F, 0xBA]) == nil)
        #expect(TrueHDMajorSync.carriesObjectAudio(in: []) == nil)
    }

    // MARK: - What a track reports

    @Test("objectAudio: preserved only when the bits are copied, not preserved when bridged, none without objects")
    func objectAudioTable() {
        let cases: [(Bool, AudioDelivery, ObjectAudioDelivery)] = [
            (false, .streamCopy, .none),
            (false, .bridged, .none),
            (true, .streamCopy, .preserved),
            (true, .bridged, .notPreserved),
            (true, .decoded, .notPreserved),
            (true, .unavailable, .notPreserved),
        ]
        for (objects, delivery, expected) in cases {
            #expect(ObjectAudioDelivery(sourceCarriesObjects: objects, delivery: delivery) == expected)
        }
    }

    @Test("The bitstream overrides the container's claim in both directions")
    func evidenceOverridesClaim() {
        let store = AudioDeliveryStore()
        store.prepare(indexes: [1, 2, 3], objectAudioClaims: [1, 2])
        store.update(index: 1, delivery: .bridged)
        store.update(index: 2, delivery: .streamCopy)
        store.update(index: 3, delivery: .bridged)
        #expect(store.snapshot.map(\.objectAudio) == [.notPreserved, .preserved, .none])

        // A TrueHD track the metadata was silent about, and an E-AC-3 track
        // whose claim the JOC walk did not bear out.
        store.noteSourceObjectAudio(index: 3, present: true)
        store.noteSourceObjectAudio(index: 2, present: false)
        #expect(store.snapshot.map(\.objectAudio) == [.notPreserved, .none, .notPreserved])
        // A later progress update does not lose it.
        store.update(index: 3, delivery: .bridged, bridge: AudioBridgeProgress())
        #expect(store.snapshot.last?.objectAudio == .notPreserved)
    }

    // MARK: - Lossless bridge

    private static let sampleRate: Int32 = 48_000

    /// 24-bit interleaved LPCM, 7.1 — what a TrueHD 7.1 presentation decodes
    /// to, minus the codec FFmpeg cannot be made to encode at 7.1 (its truehd
    /// encoder stops at 5.1(side)).
    private func makeCodecpar(channels: Int32) -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_S24LE
        par.pointee.sample_rate = Self.sampleRate
        par.pointee.bits_per_coded_sample = 24
        par.pointee.block_align = channels * 3
        av_channel_layout_default(&par.pointee.ch_layout, channels)
        return par
    }

    /// A value no two channels share and that uses all 24 bits, sign included
    /// — a truncation to 16 bits, a dropped channel or a swapped pair all
    /// change it.
    private static func sample(channel: Int, frame: Int) -> Int32 {
        let magnitude = Int32((frame * 7_919 + channel * 104_729) % 8_388_607)
        return frame % 2 == 0 ? magnitude : -magnitude
    }

    private func makePacket(frames: Int, channels: Int, firstFrame: Int) -> UnsafeMutablePointer<AVPacket> {
        let packet = av_packet_alloc()!
        av_new_packet(packet, Int32(frames * channels * 3))
        var offset = 0
        for frame in firstFrame..<(firstFrame + frames) {
            for channel in 0..<channels {
                let value = UInt32(bitPattern: Self.sample(channel: channel, frame: frame))
                packet.pointee.data[offset] = UInt8(value & 0xFF)
                packet.pointee.data[offset + 1] = UInt8((value >> 8) & 0xFF)
                packet.pointee.data[offset + 2] = UInt8((value >> 16) & 0xFF)
                offset += 3
            }
        }
        packet.pointee.pts = Int64(firstFrame)
        packet.pointee.dts = Int64(firstFrame)
        packet.pointee.duration = Int64(frames)
        return packet
    }

    @Test("Lossless bridging keeps a 7.1 source's eight channels bit-exact at 24 bits; compressed folds it to 5.1")
    func losslessIsBitExact7_1() throws {
        let target = AudioBridge.targetCodec(for: .lossless)
        try #require(target == AV_CODEC_ID_FLAC, "this FFmpeg build has no flac encoder")
        let channels = 8
        let par = makeCodecpar(channels: Int32(channels))
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }

        // The default target cannot carry 7.1 — the gap this option closes.
        let compressed = try AudioBridge(
            codecpar: par, timeBase: AVRational(num: 1, den: Self.sampleRate), globalHeader: true
        )
        #expect((compressed.outputChannelCount ?? 0) <= 6)
        compressed.close()

        let bridge = try AudioBridge(
            codecpar: par, timeBase: AVRational(num: 1, den: Self.sampleRate),
            globalHeader: true, targetCodec: target
        )
        defer { bridge.close() }
        #expect(bridge.outputChannelCount == 8)
        #expect(bridge.outputCodecName == "flac")
        #expect(bridge.routeDescription.contains("7.1"), "\(bridge.routeDescription)")

        var encoded: [(data: [UInt8], pts: Int64)] = []
        let emit: AudioBridge.Emit = { packet in
            // flac's flush emits an empty packet carrying the final STREAMINFO
            // as side data; it holds no audio.
            guard packet.pointee.size > 0 else { return }
            encoded.append((Array(UnsafeBufferPointer(start: packet.pointee.data, count: Int(packet.pointee.size))),
                            packet.pointee.pts))
        }
        let totalFrames = 20_000
        for first in stride(from: 0, to: totalFrames, by: 1_000) {
            let packet = makePacket(frames: 1_000, channels: channels, firstFrame: first)
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            try bridge.feed(packet, emit: emit)
        }
        try bridge.flush(emit: emit)
        #expect(encoded.first?.pts == 0)

        // Decode with a fresh flac decoder, configured from what the muxer
        // would be given.
        let output = avformat_alloc_context()!
        defer { var output: UnsafeMutablePointer<AVFormatContext>? = output; avformat_free_context(output) }
        let stream = avformat_new_stream(output, nil)!
        try bridge.configure(outputStream: stream)
        let decoder = avcodec_find_decoder(AV_CODEC_ID_FLAC)!
        var context: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&context) }
        avcodec_parameters_to_context(context, stream.pointee.codecpar)
        #expect(avcodec_open2(context, decoder, nil) == 0)
        #expect(stream.pointee.codecpar.pointee.bits_per_raw_sample == 24)

        var decoded: [[Int32]] = Array(repeating: [], count: channels)
        var layoutOK = true
        let frame = av_frame_alloc()
        defer { var frame = frame; av_frame_free(&frame) }
        func drain() {
            while avcodec_receive_frame(context, frame) == 0 {
                var expected = AVChannelLayout()
                av_channel_layout_from_string(&expected, "7.1")
                layoutOK = layoutOK && av_channel_layout_compare(&frame!.pointee.ch_layout, &expected) == 0
                let count = Int(frame!.pointee.nb_samples)
                let planar = frame!.pointee.format == AV_SAMPLE_FMT_S32P.rawValue
                for channel in 0..<channels {
                    let plane = planar ? channel : 0
                    let base = UnsafeRawPointer(frame!.pointee.extended_data[plane]!).assumingMemoryBound(to: Int32.self)
                    for index in 0..<count {
                        decoded[channel].append(planar ? base[index] : base[index * channels + channel])
                    }
                }
                av_frame_unref(frame)
            }
        }
        for (bytes, _) in encoded {
            let packet = av_packet_alloc()!
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            av_new_packet(packet, Int32(bytes.count))
            bytes.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: bytes.count) }
            #expect(avcodec_send_packet(context, packet) == 0)
            drain()
        }
        avcodec_send_packet(context, nil)
        drain()

        #expect(layoutOK, "decoded layout is not 7.1")
        for channel in 0..<channels {
            #expect(decoded[channel].count == totalFrames, "channel \(channel): \(decoded[channel].count) frames")
            // 24-bit samples ride in the top of an S32: shift back down.
            let mismatch = decoded[channel].enumerated().first { $0.element >> 8 != Self.sample(channel: channel, frame: $0.offset) }
            #expect(mismatch == nil, "channel \(channel) differs at frame \(mismatch?.offset ?? -1)")
        }
    }

    @Test("Lossless bridging lands every source layout on the one FLAC means for its channel count")
    func flacLayoutsAreFLACs() throws {
        let target = AudioBridge.targetCodec(for: .lossless)
        try #require(target == AV_CODEC_ID_FLAC, "this FFmpeg build has no flac encoder")
        // A 2.1 source copied through would be read back as 3.0 — its LFE in
        // the centre speaker. FLAC's own layouts per count, resampled into.
        for (source, expected) in [
            ("2.1", "3.0"), ("5.1(side)", "5.1(side)"), ("5.1", "5.1(side)"), ("7.1(wide)", "7.1"), ("7.1", "7.1"),
            ("stereo", "stereo"), ("6.1", "6.1"),
        ] {
            let par = makeCodecpar(channels: 2)
            defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }
            av_channel_layout_uninit(&par.pointee.ch_layout)
            #expect(av_channel_layout_from_string(&par.pointee.ch_layout, source) == 0)
            par.pointee.block_align = par.pointee.ch_layout.nb_channels * 3
            let bridge = try AudioBridge(
                codecpar: par, timeBase: AVRational(num: 1, den: Self.sampleRate),
                globalHeader: true, targetCodec: target
            )
            defer { bridge.close() }
            #expect(bridge.routeDescription.contains("→ flac \(expected) "), "\(source): \(bridge.routeDescription)")
        }
    }

    @Test("A lossless bridge re-anchored to an earlier position starts clean there")
    func losslessResetReanchors() throws {
        let target = AudioBridge.targetCodec(for: .lossless)
        try #require(target == AV_CODEC_ID_FLAC, "this FFmpeg build has no flac encoder")
        let par = makeCodecpar(channels: 8)
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }
        let bridge = try AudioBridge(
            codecpar: par, timeBase: AVRational(num: 1, den: Self.sampleRate),
            globalHeader: true, targetCodec: target
        )
        defer { bridge.close() }

        var timestamps: [Int64] = []
        let emit: AudioBridge.Emit = { if $0.pointee.size > 0 { timestamps.append($0.pointee.pts) } }
        for first in stride(from: 480_000, to: 500_000, by: 1_000) {
            let packet = makePacket(frames: 1_000, channels: 8, firstFrame: first)
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            try bridge.feed(packet, emit: emit)
        }
        try bridge.reset()
        timestamps.removeAll()
        for first in stride(from: 96_000, to: 116_000, by: 1_000) {
            let packet = makePacket(frames: 1_000, channels: 8, firstFrame: first)
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            try bridge.feed(packet, emit: emit)
        }
        try bridge.flush(emit: emit)
        #expect(timestamps.first == 96_000, "\(timestamps.prefix(3))")
        #expect(timestamps == timestamps.sorted())
        #expect(timestamps.allSatisfy { $0 >= 96_000 && $0 < 116_000 })
    }

    @Test("Without lossless the target is unchanged")
    func compressedTargetIsTheDefault() {
        #expect(AudioBridge.targetCodec(for: .compressed) == AudioBridge.defaultTargetCodec)
    }
}

/// The served session: what the master declares and what a host reads.
@Suite("TrueHD Atmos sessions", .serialized)
struct TrueHDAtmosSessionTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func audioMediaLines(_ master: String) -> [String] {
        master.split(separator: "\n").map(String.init).filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
    }

    @Test("lossless: a TrueHD track is served as FLAC at its own channel count and reported as not carrying objects")
    func losslessTrueHDSession() async throws {
        guard AudioBridge.targetCodec(for: .lossless) == AV_CODEC_ID_FLAC else { return }
        // h264_truehd_14s.mkv: a 5.1 TrueHD default track and a stereo one
        // (see LazyBridgedRenditionTests for how it was made).
        let session = try PrismCoreSession(url: try fixture("h264_truehd_14s.mkv"), bridgedAudio: .lossless)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        #expect(await session.options.bridgedAudio == .lossless)

        let (masterData, _) = try await URLSession.uncached.data(from: playlist)
        let master = String(decoding: masterData, as: UTF8.self)
        let media = audioMediaLines(master)
        #expect(media.count == 2, "\(master)")
        #expect(media.first?.contains("CHANNELS=\"6\"") == true, "\(media)")
        #expect(master.contains("fLaC"), "\(master)")
        #expect(!master.contains("16/JOC"))

        let (initData, _) = try await URLSession.uncached.data(
            from: playlist.deletingLastPathComponent().appendingPathComponent("audio0/init.mp4")
        )
        #expect(initData.range(of: Data("fLaC".utf8)) != nil)
        #expect(initData.range(of: Data("dfLa".utf8)) != nil)

        let deliveries = session.audioTrackDeliveries
        #expect(deliveries.map(\.delivery).contains(.bridged))
        // The fixture is plain TrueHD: its major sync says two substreams.
        #expect(deliveries.allSatisfy { $0.objectAudio == .none }, "\(deliveries)")
        #expect(await session.diagnosticReport().options?.bridgedAudio == "lossless")

        // Every segment of every rendition — the tail included, after flac's
        // flush (whose empty STREAMINFO packet the bridge drops) — demuxes and
        // decodes as served.
        let report = try await SegmentVerifier.verify(playlist: playlist, stallTimeout: .seconds(20))
        #expect(!report.hasErrors && report.isComplete, "\(report.findings)")
        #expect(report.playlists.count == 3, "\(report.playlists)")
        let audio = report.playlists.filter { $0.uri.contains("audio") }
        #expect(audio.count == 2 && audio.allSatisfy { $0.audioFrames > 0 && $0.undecodedStreams.isEmpty },
                "\(report.playlists)")
    }

    @Test("A TrueHD Atmos alternate nobody selected is read off the bitstream before any fetch")
    func lazyAtmosAlternateIsReported() async throws {
        // h264_truehd_14s.mkv with its stereo `ces` track's major syncs
        // rewritten to declare the 16-channel presentation (four substreams,
        // top bit of substream_info), checksums recomputed so the parser
        // keeps the units. FFmpeg's TrueHD encoder cannot make Atmos, hence
        // the patch. That track is a lazy rendition: it is never decoded, and
        // its rendition never sees a packet, unless someone selects it — the
        // answer has to come from the read loop.
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("prismcore-atmos-\(UUID().uuidString).mkv")
        try Data(Self.declaringAtmos(onStereoTrackOf: try Data(contentsOf: try fixture("h264_truehd_14s.mkv"))))
            .write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let session = try PrismCoreSession(url: source)
        _ = try await session.start()
        defer { Task { await session.stop() } }
        #expect(await session.audioRenditionProductions.map(\.production) == [.eager, .lazy])

        let store = await session.remuxer.audioDeliveryStore
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.objectAudioEvidence(index: 2) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.objectAudioEvidence(index: 2) == true, "the lazy track's major sync was never read")
        #expect(store.objectAudioEvidence(index: 1) == false)
        #expect(session.audioTrackDeliveries.map(\.objectAudio) == [.none, .notPreserved])
        #expect(await session.diagnosticReport().runtime?.audioTracks?.last?.objectAudio == "notPreserved")
        let work = await session.workDirectory
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("audio1/init.mp4").path),
                "the lazy rendition was produced, so this proves nothing about the read loop")
    }

    /// Rewrites every major sync with ONE substream (the fixture's stereo
    /// track) to four substreams with the
    /// Atmos bit, and re-signs it — CRC-16, polynomial 0x2D, over the header
    /// minus its last four bytes, byte-swapped the way libavutil keeps a
    /// non-reflected CRC, XORed with the 16-bit word before the checksum.
    static func declaringAtmos(onStereoTrackOf data: Data) -> [UInt8] {
        var bytes = [UInt8](data)
        let header = 28
        func crc(_ range: Range<Int>) -> UInt16 {
            var crc: UInt16 = 0
            for byte in bytes[range] {
                crc ^= UInt16(byte) << 8
                for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x2D : crc << 1 }
            }
            return crc.byteSwapped
        }
        for index in 0..<(bytes.count - header)
        where bytes[index] == 0xF8 && bytes[index + 1] == 0x72 && bytes[index + 2] == 0x6F
            && bytes[index + 3] == 0xBA && bytes[index + 8] == 0xB7 && bytes[index + 9] == 0x52
            && bytes[index + 16] >> 4 == 1 {
            bytes[index + 16] = 0x40 | (bytes[index + 16] & 0x0F)
            bytes[index + 17] |= 0x80
            let word = UInt16(bytes[index + header - 4]) | UInt16(bytes[index + header - 3]) << 8
            let checksum = crc(index..<(index + header - 4)) ^ word
            bytes[index + header - 2] = UInt8(checksum & 0xFF)
            bytes[index + header - 1] = UInt8(checksum >> 8)
        }
        return bytes
    }

    @Test("lossless: an 8-channel source keeps all 8; compressed serves at most 6")
    func sevenOneSurvives() async throws {
        guard AudioBridge.targetCodec(for: .lossless) == AV_CODEC_ID_FLAC else { return }
        // h264_pcm71_1s.mkv: 1 s of testsrc2 (320x180, 24 fps, -g 24) and
        // 16-bit PCM, eight tones (200…800 Hz, 50 Hz on the LFE), made with
        // system ffmpeg:
        //   eight `sine=f=…:d=1` inputs → amerge=inputs=8,aformat=channel_layouts=7.1
        //   -c:v libx264 -crf 35 -g 24 -c:a pcm_s16le -metadata:s:a:0 language=eng
        // (channel N carries tone N: FL 200, FR 300, FC 400, LFE 50, BL 500,
        // BR 600, SL 700, SR 800 Hz)
        // Matroska keeps the channel count, not the layout, so this also
        // pins an unspecified 8-channel layout landing on 7.1.
        for (format, expectChannels) in [(BridgedAudioFormat.lossless, "8"), (.compressed, "6")] {
            let session = try PrismCoreSession(url: try fixture("h264_pcm71_1s.mkv"), bridgedAudio: format)
            let playlist = try await session.start()
            let (masterData, _) = try await URLSession.uncached.data(from: playlist)
            let master = String(decoding: masterData, as: UTF8.self)
            await session.stop()
            let media = audioMediaLines(master)
            #expect(media.count == 1, "\(master)")
            #expect(media.first?.contains("CHANNELS=\"\(expectChannels)\"") == true, "\(format): \(media)")
            #expect(master.contains("fLaC") == (format == .lossless), "\(format): \(master)")
        }
    }

    @Test("AVPlayer takes the lossless 7.1 master and decodes an 8-channel FLAC track")
    @MainActor func avPlayerPlaysLossless7_1() async throws {
        guard AudioBridge.targetCodec(for: .lossless) == AV_CODEC_ID_FLAC else { return }
        // macOS AVFoundation, not a tvOS device or an AVR: it shows Apple's
        // HLS stack accepts the rendition and reads it as 8 channels. What an
        // Apple TV sends over HDMI is a device run's question.
        let session = try PrismCoreSession(url: try fixture("h264_pcm71_1s.mkv"), bridgedAudio: .lossless)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let item = AVPlayerItem(url: playlist)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while item.status != .readyToPlay {
            if item.status == .failed || ContinuousClock.now >= deadline {
                Issue.record("item never became ready (error: \(String(describing: item.error)))")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        player.play()

        var audio: (format: FourCharCode, channels: UInt32)?
        while audio == nil, item.status != .failed, ContinuousClock.now < deadline {
            for track in item.tracks where track.assetTrack?.mediaType == .audio {
                let descriptions = (try? await track.assetTrack?.load(.formatDescriptions)) ?? []
                if let description = descriptions.first,
                   let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    audio = (CMFormatDescriptionGetMediaSubType(description), basic.pointee.mChannelsPerFrame)
                }
            }
            if audio == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let found = try #require(audio, "no audio track surfaced (error: \(String(describing: item.error)))")
        #expect(found.format == kAudioFormatFLAC)
        #expect(found.channels == 8)
        player.pause()
    }

    @Test("Apple's own FLAC decoder puts every 7.1 channel of the served rendition where the source had it")
    func appleDecoderKeepsChannelOrder() async throws {
        guard AudioBridge.targetCodec(for: .lossless) == AV_CODEC_ID_FLAC else { return }
        // FLAC's 8-channel order (RFC 9639 §9.1.3: FL FR FC LFE BL BR SL SR)
        // is FFmpeg's 7.1, so the bridge maps nothing — but an FFmpeg round
        // trip cannot tell a swapped side/back pair from a right one. Apple's
        // decoder can: each channel is a different tone, and each output
        // channel's CoreAudio label must carry the tone the source put there.
        let session = try PrismCoreSession(url: try fixture("h264_pcm71_1s.mkv"), bridgedAudio: .lossless)
        let base = try await session.start().deletingLastPathComponent()
        let (initData, _) = try await URLSession.uncached.data(from: base.appendingPathComponent("audio0/init.mp4"))
        let (segment, _) = try await URLSession.uncached.data(from: base.appendingPathComponent("audio0/seg00000.m4s"))
        await session.stop()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prismcore-flac71-\(UUID().uuidString).mp4")
        try (initData + segment).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let asset = AVURLAsset(url: file)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        var tag: AudioChannelLayoutTag?
        var rate = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            let description = try #require(CMSampleBufferGetFormatDescription(buffer))
            var size = 0
            tag = tag ?? CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size)?.pointee.mChannelLayoutTag
            rate = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mSampleRate ?? rate
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer?.withMemoryRebound(to: Float.self, capacity: length / 4) {
                samples += UnsafeBufferPointer(start: $0, count: length / 4)
            }
        }
        var layoutTag = try #require(tag, "the decoded audio carries no channel layout")
        var size: UInt32 = 0
        AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &layoutTag, &size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &layoutTag, &size, raw)
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let labels = withUnsafePointer(to: &layout.pointee.mChannelDescriptions) {
            UnsafeBufferPointer(start: $0, count: Int(layout.pointee.mNumberChannelDescriptions)).map(\.mChannelLabel)
        }
        #expect(labels.count == 8, "tag \(String(layoutTag, radix: 16))")

        // In a 7.1 layout CoreAudio's Ls/Rs are the side pair, Rls/Rrs the back.
        let tone: [AudioChannelLabel: Double] = [
            kAudioChannelLabel_Left: 200, kAudioChannelLabel_Right: 300, kAudioChannelLabel_Center: 400,
            kAudioChannelLabel_LFEScreen: 50,
            kAudioChannelLabel_RearSurroundLeft: 500, kAudioChannelLabel_RearSurroundRight: 600,
            kAudioChannelLabel_LeftSurround: 700, kAudioChannelLabel_RightSurround: 800,
            kAudioChannelLabel_LeftSurroundDirect: 700, kAudioChannelLabel_RightSurroundDirect: 800,
        ]
        let frames = samples.count / 8
        try #require(frames > 4_096 && rate > 0)
        for (channel, label) in labels.enumerated() {
            var crossings = 0
            for index in 1..<frames where (samples[(index - 1) * 8 + channel] < 0) != (samples[index * 8 + channel] < 0) {
                crossings += 1
            }
            let hertz = Double(crossings) / 2 / (Double(frames) / rate)
            let expected = try #require(tone[label], "unexpected label \(label) at \(channel)")
            #expect(abs(hertz - expected) < 15, "channel \(channel) (label \(label)): \(hertz) Hz, expected \(expected)")
        }
    }

    @Test("AVPlayer plays the 5.1 TrueHD lossless master, and switches to a compressed boost rendition in the same group")
    @MainActor func avPlayerPlaysLosslessTrueHDWithBoost() async throws {
        guard AudioBridge.targetCodec(for: .lossless) == AV_CODEC_ID_FLAC, PrismCoreSession.isDialogueBoostAvailable else { return }
        // 5.1(side) is the layout class that once broke AAC on Apple players
        // (a PCE), and a group mixing fLaC with a boost rendition's ec-3 / aac
        // is a shape no other test serves. macOS AVFoundation, not a device.
        let session = try PrismCoreSession(
            url: try fixture("h264_truehd_14s.mkv"), dialogueBoost: [.medium], preferredAudioLanguage: "eng",
            bridgedAudio: .lossless
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let (masterData, _) = try await URLSession.uncached.data(from: playlist)
        let master = String(decoding: masterData, as: UTF8.self)
        #expect(audioMediaLines(master).count == 3, "\(master)")

        let item = AVPlayerItem(url: playlist)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while item.status != .readyToPlay {
            if item.status == .failed || ContinuousClock.now >= deadline {
                Issue.record("item never became ready (error: \(String(describing: item.error)))")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // The machine's language picks the rendition, not the master's
        // DEFAULT; the 5.1 English one is the subject here.
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))
        let english = try #require(group.options.first {
            $0.locale?.language.languageCode?.identifier == "en" && !$0.hasMediaCharacteristic(.enhancesSpeechIntelligibility)
        }, "\(group.options)")
        item.select(english, in: group)
        player.play()

        func playingAudio() async -> (format: FourCharCode, channels: UInt32)? {
            for track in item.tracks where track.isEnabled && track.assetTrack?.mediaType == .audio {
                let descriptions = (try? await track.assetTrack?.load(.formatDescriptions)) ?? []
                if let description = descriptions.first,
                   let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    return (CMFormatDescriptionGetMediaSubType(description), basic.pointee.mChannelsPerFrame)
                }
            }
            return nil
        }
        var audio = await playingAudio()
        while !(audio?.format == kAudioFormatFLAC && audio?.channels == 6), item.status != .failed,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            audio = await playingAudio()
        }
        #expect(audio?.format == kAudioFormatFLAC && audio?.channels == 6, "\(String(describing: audio))")

        let boost = try #require(group.options.first { $0.hasMediaCharacteristic(.enhancesSpeechIntelligibility) })
        item.select(boost, in: group)
        let switchDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while audio?.format == kAudioFormatFLAC, item.status != .failed, ContinuousClock.now < switchDeadline {
            try await Task.sleep(for: .milliseconds(100))
            audio = await playingAudio()
        }
        #expect(item.status != .failed, "\(String(describing: item.error))")
        #expect(audio.map { $0.format != kAudioFormatFLAC } == true, "never switched off FLAC: \(String(describing: audio))")
        player.pause()
    }

    @Test("The muxed fallback goes back to compressed")
    func muxedFallbackIsCompressed() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_truehd_14s.mkv"), bridgedAudio: .lossless)
        let fallback = try await session.makeMuxedFallbackSession()
        #expect(await fallback.options.bridgedAudio == .compressed)
        #expect(await fallback.options.forceMuxedShape)
    }

    @Test("A clone keeps the host's lossless choice")
    func cloneCarriesLossless() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_truehd_14s.mkv"), bridgedAudio: .lossless)
        let clone = try await session.makeSession { $0.preferredAudioLanguage = "ces" }
        #expect(await clone.options.bridgedAudio == .lossless)
    }
}
