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

    @Test("The bridge reads the major sync of what it is fed and reports it once")
    func bridgeReportsSourceAtmos() throws {
        guard avcodec_find_decoder(AV_CODEC_ID_TRUEHD) != nil else { return }
        let par = avcodec_parameters_alloc()!
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_TRUEHD
        par.pointee.sample_rate = 48_000
        av_channel_layout_default(&par.pointee.ch_layout, 8)

        let bridge = try AudioBridge(
            codecpar: par, timeBase: AVRational(num: 1, den: 48_000), globalHeader: true
        )
        defer { bridge.close() }
        var reports: [Bool] = []
        bridge.onSourceObjectAudio = { reports.append($0) }

        for bytes in [Self.plainUnit, Self.restartUnit(substreams: 4, substreamInfo: 0xBC), Self.restartUnit()] {
            let packet = av_packet_alloc()!
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            av_new_packet(packet, Int32(bytes.count))
            bytes.withUnsafeBytes { packet.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count) }
            packet.pointee.pts = 0
            // The units are not decodable audio (the checksum is not real), so
            // the decoder may refuse them; the read happens before it does.
            try? bridge.feed(packet) { _ in }
        }
        #expect(reports == [true])
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

        // Every segment of every rendition — the tail included, where flac's
        // flush hands the muxer an empty packet carrying STREAMINFO — demuxes
        // and decodes as served.
        let report = try await SegmentVerifier.verify(playlist: playlist, stallTimeout: .seconds(20))
        #expect(!report.hasErrors && report.isComplete, "\(report.findings)")
        #expect(report.playlists.count == 3, "\(report.playlists)")
        let audio = report.playlists.filter { $0.uri.contains("audio") }
        #expect(audio.count == 2 && audio.allSatisfy { $0.audioFrames > 0 && $0.undecodedStreams.isEmpty },
                "\(report.playlists)")
    }

    @Test("lossless: an 8-channel source keeps all 8; compressed serves at most 6")
    func sevenOneSurvives() async throws {
        guard AudioBridge.targetCodec(for: .lossless) == AV_CODEC_ID_FLAC else { return }
        // h264_pcm71_1s.mkv: 1 s of testsrc2 (320x180, 24 fps, -g 24) and
        // 16-bit PCM, eight tones (200…800 Hz, 50 Hz on the LFE), made with
        // system ffmpeg:
        //   eight `sine=f=…:d=1` inputs → join=inputs=8:channel_layout=7.1
        //   -c:v libx264 -crf 35 -c:a pcm_s16le -metadata:s:a:0 language=eng
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
