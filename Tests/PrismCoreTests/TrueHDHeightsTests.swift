import Testing
import Foundation
import AVFoundation
import Libavcodec
import Libavformat
import Libavutil
@testable import PrismCore
#if canImport(TrueHDObjects)
import TrueHDObjects
#endif

/// TrueHD Atmos with its heights (`ObjectAudioRendering.heights`): off unless asked for, routed
/// only where every condition holds, served as a real `apac` track, and placed channel by
/// channel. The fixture is FFmpeg's own 5.1 TrueHD (no objects), which exercises the whole chain
/// — renderer, encoder, muxer patch, AVFoundation's demux and decode — through the bed fallback.
/// Real Atmos streams are behind `PRISMCORE_TRUEHD_VECTORS` (see `realAtmosVector`).
@Suite("TrueHD heights", .serialized)
struct TrueHDHeightsTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "missing fixture \(name)")
    }

    private static let atmosTrack = AudioTrackInfo(
        streamIndex: 1, codecName: "truehd", profileName: "Dolby TrueHD + Dolby Atmos",
        channelCount: 8, channelLayoutDescription: "7.1", sampleRate: 48_000, language: nil, title: nil,
        isObjectAudio: true, copyability: .requiresAudioBridge
    )

    // MARK: - Opt-in and routing

    @Test("Heights are off unless the host asks, and asking alone is not enough")
    func offByDefault() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_truehd51_tones_3s.mkv"), display: .init(isHDRReady: false, isDolbyVisionCapable: false))
        let options = await session.options
        #expect(options.objectAudioRendering == .off)
        #expect(options.allowsAtmosOutput == false)
        #expect(PrismCoreSession.describe(.off, allowsAtmosOutput: true) == "off")
        if ObjectAudioRendering.isAvailable {
            #expect(PrismCoreSession.describe(.heights, allowsAtmosOutput: false).contains("did not allow"))
            #expect(PrismCoreSession.describe(.heights, allowsAtmosOutput: true) == "heights")
        } else {
            #expect(PrismCoreSession.describe(.heights, allowsAtmosOutput: true).contains("unavailable"))
        }
    }

    @Test("Only a bridged 48 kHz TrueHD Atmos track, with both flags and the renderer, renders heights")
    func routing() {
        let atmos = Self.atmosTrack
        func renders(
            _ track: AudioTrackInfo = atmos, carries: Bool? = nil, mode: HLSRemuxer.AudioRouteMode = .bridge,
            rendering: ObjectAudioRendering = .heights, allows: Bool = true, available: Bool = true
        ) -> Bool {
            HLSRemuxer.rendersHeights(
                track: track, carriesObjects: carries ?? track.isObjectAudio, mode: mode, rendering: rendering,
                allowsAtmosOutput: allows, available: available
            )
        }
        #expect(renders())
        #expect(!renders(rendering: .off))
        #expect(!renders(allows: false))
        #expect(!renders(available: false))
        #expect(!renders(mode: .boost(.medium)), "dialogue boost stays on the EAC3 bridge")
        #expect(!renders(mode: .streamCopy))
        let plain = AudioTrackInfo(
            streamIndex: 1, codecName: "truehd", profileName: nil, channelCount: 8, channelLayoutDescription: "7.1",
            sampleRate: 48_000, language: nil, title: nil, isObjectAudio: false, copyability: .requiresAudioBridge
        )
        #expect(!renders(plain), "no Atmos claim and no bitstream answer: no apac promise in the master")
        // The bitstream outranks the claim both ways (Grok r1 P2: the claim is silent whenever
        // find_stream_info did not decode a TrueHD frame).
        #expect(renders(plain, carries: true))
        #expect(!renders(atmos, carries: false))
        let dtsx = AudioTrackInfo(
            streamIndex: 1, codecName: "dts", profileName: "DTS-HD MA + DTS:X", channelCount: 8, channelLayoutDescription: "7.1",
            sampleRate: 48_000, language: nil, title: nil, isObjectAudio: true, copyability: .requiresAudioBridge
        )
        #expect(!renders(dtsx), "TrueHD only")
        let hiRate = AudioTrackInfo(
            streamIndex: 1, codecName: "truehd", profileName: nil, channelCount: 8, channelLayoutDescription: "7.1",
            sampleRate: 96_000, language: nil, title: nil, isObjectAudio: true, copyability: .requiresAudioBridge
        )
        #expect(!renders(hiRate))
    }

    @Test("The scout reads Atmos off the bitstream before the master")
    func scoutReadsTheBitstream() throws {
        let (context, close) = try open("h264_truehd51_tones_3s.mkv")
        defer { close() }
        // FFmpeg's TrueHD has two substreams: a major sync that says "no Atmos".
        #expect(TrueHDAtmosScout.scan(input: context, streams: [1]) == [1: false])
        #expect(TrueHDAtmosScout.scan(input: context, streams: []) == [:])
    }

    @Test("The muxed fallback session drops heights")
    func muxedFallbackDropsHeights() async throws {
        let session = try PrismCoreSession(
            url: try fixture("h264_truehd51_tones_3s.mkv"), display: .init(isHDRReady: false, isDolbyVisionCapable: false),
            objectAudioRendering: .heights, allowsAtmosOutput: true
        )
        let fallback = try await session.makeMuxedFallbackSession()
        #expect(await fallback.options.objectAudioRendering == .off)
        #expect(await session.options.objectAudioRendering == .heights)
        await fallback.stop()
        await session.stop()
    }

    @Test("A re-anchor with no major sync left ends empty, never failing the producer")
    func emptyEpochFlushesQuietly() throws {
        guard #available(macOS 26.0, *), ObjectAudioRendering.isAvailable else { return }
        let (context, close) = try open("h264_truehd51_tones_3s.mkv")
        defer { close() }
        let stream = context.pointee.streams[1]!
        let bridge = try HeightsBridge(codecpar: stream.pointee.codecpar, timeBase: stream.pointee.time_base)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var out = 0
        var fed = 0
        // Only access units that are not restart units: what a seek into the last ~107 ms of a
        // stream hands the bridge.
        while av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == 1, let data = pkt.pointee.data,
                  !TrueHDMajorSync.startsWithMajorSync(UnsafeBufferPointer(start: data, count: Int(pkt.pointee.size)))
            else { continue }
            try bridge.feed(pkt) { _ in out += 1 }
            fed += 1
        }
        #expect(fed > 0)
        try bridge.flush { _ in out += 1 }
        #expect(out == 0)
    }

    @Test("After the decoder fails, silence keeps the rendition on the source clock")
    func decoderFailureStaysOnTheSourceGrid() throws {
        guard #available(macOS 26.0, *), ObjectAudioRendering.isAvailable else { return }
        let (context, close) = try open("h264_truehd51_tones_3s.mkv")
        defer { close() }
        let stream = context.pointee.streams[1]!
        let timeBase = stream.pointee.time_base
        let bridge = try HeightsBridge(codecpar: stream.pointee.codecpar, timeBase: timeBase)
        var deliveries: [ObjectAudioDelivery] = []
        bridge.onObjectAudio = { delivery, _ in deliveries.append(delivery) }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var count = 0
        var checked = 0
        while av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == 1, pkt.pointee.size > 8 else { continue }
            count += 1
            if count == 600 {
                // Bytes missing from the front of a unit: the decoder's framing breaks, for good.
                pkt.pointee.data += 6
                pkt.pointee.size -= 6
            }
            try bridge.feed(pkt) { _ in }
            if count >= 600 {
                let end = av_rescale_q(pkt.pointee.pts + pkt.pointee.duration, timeBase, AVRational(num: 1, den: 48_000))
                #expect(bridge.renderedPosition == end, "packet \(count)")
                checked += 1
            }
        }
        #expect(checked > 100)
        #expect(deliveries.last == .notPreserved)
    }

    @Test("Once the master declared apac, a failed encoder rebuild never changes the rendition's codec")
    func declaredCodecIsLocked() throws {
        guard ObjectAudioRendering.isAvailable else { return }
        struct Refused: Error {}
        let (context, close) = try open("h264_truehd51_tones_3s.mkv")
        defer { close() }
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let writer = AudioRenditionWriter(
            route: .init(index: 1, mode: .bridge), track: Self.atmosTrack, ordinal: 0, parent: parent, rendersHeights: true
        )
        try writer.open(input: context)
        #expect(writer.rendition(groupID: "aud", isDefault: true).codecString == "apac.31.03")
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        let timeBase = context.pointee.streams[1]!.pointee.time_base
        func feed(_ limit: Int) throws {
            var fed = 0
            while fed < limit, av_read_frame(context, pkt) >= 0 {
                defer { av_packet_unref(pkt) }
                guard pkt.pointee.stream_index == 1 else { continue }
                try writer.write(pkt, sourceTimeBase: timeBase)
                fed += 1
            }
        }
        try feed(.max)
        try writer.cut(durationSeconds: 3)
        try writer.flushBridge()

        // EOF spent the encoder; the re-anchor's rebuild fails. Before the fix the writer fell
        // back to AudioBridge here and muxed EAC3/AAC fragments under the served apac entry.
        writer.heightsBridgeFactoryForTesting = { _ in throw Refused() }
        try FFmpegError.check(avformat_seek_file(context, 1, Int64.min, 0, 0, 0), "seek")
        try writer.reanchor(input: context, segmentIndex: 1)
        #expect(writer.rendersHeights)
        #expect(writer.rendition(groupID: "aud", isDefault: true).codecString == "apac.31.03")
        try feed(500)
        let directory = parent.appendingPathComponent("audio0")
        #expect(try writer.cut(durationSeconds: 1) == 0, "no encoder, no fragment — and never a foreign one")

        // The next re-anchor builds the encoder again and the rendition plays on.
        writer.heightsBridgeFactoryForTesting = nil
        try FFmpegError.check(avformat_seek_file(context, 1, Int64.min, 0, 0, 0), "seek")
        try writer.reanchor(input: context, segmentIndex: 2)
        try feed(500)
        #expect(try writer.cut(durationSeconds: 1) > 0)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("seg00002.m4s").path))
        writer.close()
    }

    @Test("A stalled source cannot hold the scout past its time budget")
    func scoutIsBounded() async throws {
        let media = try Data(contentsOf: try fixture("h264_truehd51_tones_3s.mkv"))
        // ~30 KB/s: the header arrives, the major-sync hunt would take ~18 s.
        let server = try RangeFixtureServer(media: media, bytesPerSecond: 30_000, firstByteDelay: 0)
        let url = try await server.start()
        defer { server.stop() }
        let guardian = ReadInterruptGuard()
        var input: UnsafeMutablePointer<AVFormatContext>? = guardian.makeContext()
        try FFmpegError.check(avformat_open_input(&input, url.absoluteString, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        let started = ContinuousClock.now
        let found = TrueHDAtmosScout.scan(
            // Stream 0 is the video: it never answers, so only a budget ends the hunt.
            input: context, streams: [0, 1], interruptGuard: guardian, timeBudget: .milliseconds(300)
        )
        let spent = ContinuousClock.now - started
        #expect(spent < .seconds(2), "scout took \(spent)")
        #expect(context.pointee.pb?.pointee.error ?? 0 >= 0, "the latched abort must be cleared")
        _ = found  // whatever arrived in time; the rest falls back to the claim
        // A byte budget alone also stops it, on a local file, before any answer.
        let (local, close) = try open("h264_truehd51_tones_3s.mkv")
        defer { close() }
        #expect(TrueHDAtmosScout.scan(input: local, streams: [1], byteBudget: 0) == [:])
    }

    @Test("A chain under 2x real time over ten seconds of audio asks for the bed, once per epoch")
    func loadGuardRequestsTheBed() throws {
        guard #available(macOS 26.0, *), ObjectAudioRendering.isAvailable else { return }
        let par = try #require(avcodec_parameters_alloc())
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_TRUEHD
        par.pointee.sample_rate = 48_000
        let fast = try HeightsBridge(codecpar: par, timeBase: AVRational(num: 1, den: 48_000))
        defer { fast.close() }
        // 3x real time: fine. A short burst of slowness inside a fast window: fine too.
        for _ in 0..<20 { fast.noteLoad(busySeconds: 1.0 / 3, audioSeconds: 1) }
        fast.noteLoad(busySeconds: 2, audioSeconds: 1)
        for _ in 0..<9 { fast.noteLoad(busySeconds: 0.1, audioSeconds: 1) }
        #expect(fast.bedRequest == nil)
        let slow = try HeightsBridge(codecpar: par, timeBase: AVRational(num: 1, den: 48_000))
        defer { slow.close() }
        for _ in 0..<9 { slow.noteLoad(busySeconds: 0.6, audioSeconds: 1) }
        #expect(slow.bedRequest == nil, "not before ten seconds of audio")
        slow.noteLoad(busySeconds: 0.6, audioSeconds: 1)
        let why = try #require(slow.bedRequest)
        #expect(why.contains("1.7x real time"), "\(why)")
        // A seek starts a new epoch, and a new chance.
        try slow.reset()
        #expect(slow.bedRequest == nil)
    }

    @Test("Every heights layout has its APAC encoder on OS 26, and its CODECS level")
    func heightsLayouts() {
        #expect(HeightsLayout.allCases.map(\.channelCount) == [8, 10, 10, 12])
        #expect(HeightsLayout.allCases.map { APACSampleEntry.codecsString(channelCount: $0.channelCount) }
            == ["apac.31.02", "apac.31.03", "apac.31.03", "apac.31.03"])
        if ObjectAudioRendering.isAvailable {
            #expect(HeightsLayout.allCases.allSatisfy { $0.isAvailable }, "macOS 26+ encodes every layout")
        }
        #expect(PrismCoreSession.describe(.heights, allowsAtmosOutput: true, layout: .atmos5_1_2).hasPrefix("heights 5.1.2"))
    }

    @Test("CODECS follows Apple's APAC profile/level table")
    func codecsString() {
        #expect(APACSampleEntry.codecsString(channelCount: 12) == "apac.31.03")
        #expect(APACSampleEntry.codecsString(channelCount: 2) == "apac.31.00")
        #expect(APACSampleEntry.codecsString(channelCount: 16) == "apac.31.04")
    }

    @Test("The rendered-heights report outranks the claim, and a fallback reads as not preserved")
    func deliveryReport() {
        let store = AudioDeliveryStore()
        store.prepare(indexes: [1], objectAudioClaims: [1])
        store.update(index: 1, delivery: .bridged)
        #expect(store.snapshot.first?.objectAudio == .notPreserved)
        store.noteRenderedObjectAudio(index: 1, .renderedHeights)
        #expect(store.snapshot.first?.objectAudio == .renderedHeights)
        store.noteRenderedObjectAudio(index: 1, .notPreserved)
        #expect(store.snapshot.first?.objectAudio == .notPreserved)
    }

    // MARK: - The served track

    @Test("A heights rendition that cannot be built keeps the track, on the regular bridge")
    func fallbackBeforeTheMaster() throws {
        // A stream the renderer refuses (not TrueHD) — or, on a build or OS without it, any
        // stream: the writer must come out bridging, declaring what it really serves.
        let (context, close) = try open("h264_ac3_51_20s.mkv")
        defer { close() }
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let writer = AudioRenditionWriter(
            route: .init(index: 1, mode: .bridge), track: Self.atmosTrack, ordinal: 0, parent: parent, rendersHeights: true
        )
        try writer.open(input: context)
        #expect(!writer.rendersHeights)
        #expect(writer.rendition(groupID: "aud", isDefault: true).codecString?.hasPrefix("apac") == false)
        writer.close()
    }

    @Test("Rendered to apac in each layout, served as fMP4, decoded by AVFoundation: each bed channel lands on its speaker, on time",
          arguments: HeightsLayout.allCases)
    func apacRoundTrip(layout: HeightsLayout) async throws {
        guard layout.isAvailable else { return }
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let (writer, deliveries) = try renderFixture(into: parent, layout: layout)
        #expect(writer.rendersHeights)
        let rendition = writer.rendition(groupID: "aud", isDefault: true)
        let channels = layout.channelCount
        #expect(rendition.codecString == (channels == 8 ? "apac.31.02" : "apac.31.03"))
        #expect(rendition.channels == "\(channels)")
        // FFmpeg's TrueHD has no objects: the renderer says so and plays the bed.
        #expect(deliveries.last == .notPreserved)

        let directory = parent.appendingPathComponent("audio0")
        let initSegment = try Data(contentsOf: directory.appendingPathComponent("init.mp4"))
        #expect(ISOBMFFPatch.locate("apac", in: initSegment) != nil)
        #expect(initSegment.range(of: Data("dapa".utf8)) != nil)
        #expect(ISOBMFFPatch.locate("alac", in: initSegment) == nil, "the stand-in must not survive")

        var file = initSegment
        for index in 0... {
            let url = directory.appendingPathComponent(String(format: "seg%05d.m4s", index))
            guard let segment = try? Data(contentsOf: url) else { break }
            file.append(segment)
        }
        let joined = parent.appendingPathComponent("joined.mp4")
        try file.write(to: joined)
        let (pcm, firstTime) = try await decode(joined, layout: layout)

        // 3 s of source, every sample of it (± one 1024-frame packet of padding).
        let frames = pcm.count / channels
        #expect(abs(frames - 144_000) <= 1024 + 2048, "\(frames) frames")
        // The tones start at source time 0: so does the decoded audio.
        let onset = (0..<frames).first { abs(pcm[$0 * channels]) > 0.01 } ?? -1
        let onsetSeconds = firstTime + Double(onset) / 48_000
        #expect(abs(onsetSeconds) < 0.002, "first sample of L at \(onsetSeconds) s")

        // Each bed channel on its own speaker (L R C LFE Ls Rs lead every layout), backs and
        // heights silent. The fixture was meant as
        // L 220, R 330, C 440, but FFmpeg's experimental TrueHD encoder rotates the front three:
        // FFmpeg's own decoder and the truehd crate both read L 330, R 440, C 220 — and the
        // channel each decoder names is the speaker it has to reach.
        let tones: [Int: Double] = [0: 330, 1: 440, 2: 220, 3: 55, 4: 550, 5: 660]
        let window = 24_000..<120_000
        for channel in 0..<channels {
            let energy = window.reduce(0.0) { $0 + Double(pcm[$1 * channels + channel] * pcm[$1 * channels + channel]) }
            guard let tone = tones[channel] else {
                #expect(energy < 1e-3, "channel \(channel) should be silent, energy \(energy)")
                continue
            }
            let own = goertzel(pcm, channels: channels, channel: channel, frequency: tone, window: window)
            for (other, frequency) in tones where other != channel {
                let leak = goertzel(pcm, channels: channels, channel: channel, frequency: frequency, window: window)
                #expect(own > 30 * leak, "channel \(channel): \(tone) Hz \(own) vs \(frequency) Hz \(leak)")
            }
        }
    }

    /// ISO/IEC 23091-3 speaker positions of each layout, in Core Audio's `Atmos_*` order, and
    /// the labels CoreMedia reads them back as.
    private static let lpcmPositions: [HeightsLayout: [UInt8]] = [
        .atmos5_1_2: [0, 1, 2, 3, 4, 5, 23, 24],
        .atmos5_1_4: [0, 1, 2, 3, 4, 5, 17, 18, 20, 21],
        .atmos7_1_2: [0, 1, 2, 3, 4, 5, 8, 9, 23, 24],
        .atmos7_1_4: [0, 1, 2, 3, 4, 5, 8, 9, 17, 18, 20, 21],
    ]

    @Test("Rendered to LPCM in each layout: ipcm + pcmC + chnl, Core Audio's channel order, decoded by AVFoundation on time",
          arguments: HeightsLayout.allCases)
    func lpcmRoundTrip(layout: HeightsLayout) async throws {
        guard HeightsOutput.lpcm.isAvailable(for: layout) else { return }
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let (writer, _) = try renderFixture(into: parent, layout: layout, output: .lpcm)
        #expect(writer.rendersHeights)
        let rendition = writer.rendition(groupID: "aud", isDefault: true)
        let channels = layout.channelCount
        #expect(rendition.codecString == "ipcm")
        #expect(rendition.channels == "\(channels)")

        let directory = parent.appendingPathComponent("audio0")
        let initSegment = try Data(contentsOf: directory.appendingPathComponent("init.mp4"))
        let bytes = [UInt8](initSegment)
        #expect(ISOBMFFPatch.locate("apac", in: initSegment) == nil && ISOBMFFPatch.locate("alac", in: initSegment) == nil)
        // ipcm: AudioSampleEntry with the layout's channel count.
        let entry = try #require(ISOBMFFPatch.locate("ipcm", in: initSegment))
        let channelCount = Int(bytes[entry.boxStart + 8 + 16]) << 8 | Int(bytes[entry.boxStart + 8 + 17])
        #expect(channelCount == channels)
        // pcmC (ISO/IEC 23003-5): version/flags, format_flags 1 = little-endian, 24 bits.
        let pcmC = try #require(initSegment.range(of: Data("pcmC".utf8)))
        #expect(Array(bytes[pcmC.upperBound..<(pcmC.upperBound + 6)]) == [0, 0, 0, 0, 1, 24])
        // chnl (ISO/IEC 14496-12): stream_structure 1 (channels), definedLayout 0, then one
        // explicit speaker position per channel in Core Audio's order.
        let chnl = try #require(initSegment.range(of: Data("chnl".utf8)))
        let size = Int(bytes[chnl.lowerBound - 2]) << 8 | Int(bytes[chnl.lowerBound - 1])
        #expect(size == 4 + 4 + 4 + 2 + channels)
        #expect(Array(bytes[chnl.upperBound..<(chnl.upperBound + 6)]) == [0, 0, 0, 0, 1, 0])
        let positions = Array(bytes[(chnl.upperBound + 6)..<(chnl.upperBound + 6 + channels)])
        #expect(positions == Self.lpcmPositions[layout])

        var file = initSegment
        for index in 0... {
            let url = directory.appendingPathComponent(String(format: "seg%05d.m4s", index))
            guard let segment = try? Data(contentsOf: url) else { break }
            file.append(segment)
        }
        let joined = parent.appendingPathComponent("joined.mp4")
        try file.write(to: joined)

        // CoreMedia reads the chnl back as the layout's own `kAudioChannelLayoutTag_Atmos_*`
        // (measured on macOS 27; a list of the same labels in the same order would do too).
        let asset = AVURLAsset(url: joined)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let format = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 24)
        #expect(Int(format.mChannelsPerFrame) == channels && format.mSampleRate == 48_000)
        var layoutSize = 0
        let served = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize))
        #expect(served.pointee.mChannelLayoutTag == layout.layoutTag || Self.labels(served) == Self.atmosLabels[layout],
                "\(layout): tag \(served.pointee.mChannelLayoutTag >> 16)/\(served.pointee.mChannelLayoutTag & 0xFFFF) labels \(Self.labels(served))")

        // Every source sample, from source time 0, each bed channel on its speaker.
        let (pcm, firstTime) = try await decode(joined, layout: layout)
        let frames = pcm.count / channels
        #expect(abs(frames - 144_000) <= 1024, "\(frames) frames")
        let onset = (0..<frames).first { abs(pcm[$0 * channels]) > 0.01 } ?? -1
        #expect(abs(firstTime + Double(onset) / 48_000) < 0.002, "first sample of L at \(firstTime) + \(onset)")
        let tones: [Int: Double] = [0: 330, 1: 440, 2: 220, 3: 55, 4: 550, 5: 660]
        let window = 24_000..<120_000
        for channel in 0..<channels {
            let energy = window.reduce(0.0) { $0 + Double(pcm[$1 * channels + channel] * pcm[$1 * channels + channel]) }
            guard let tone = tones[channel] else {
                #expect(energy < 1e-3, "channel \(channel) should be silent, energy \(energy)")
                continue
            }
            let own = goertzel(pcm, channels: channels, channel: channel, frequency: tone, window: window)
            for (other, frequency) in tones where other != channel {
                let leak = goertzel(pcm, channels: channels, channel: channel, frequency: frequency, window: window)
                #expect(own > 30 * leak, "channel \(channel): \(tone) Hz \(own) vs \(frequency) Hz \(leak)")
            }
        }
    }

    @Test("LPCM samples are packed as 24-bit little-endian integers, clipped at full scale")
    func lpcmPacking() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 2, -2, 1 / 8_388_608, .nan]
        var bytes = [UInt8](repeating: 0xAA, count: samples.count * 3)
        samples.withUnsafeBufferPointer { LPCMSampleEntry.pack($0, into: &bytes) }
        let values = stride(from: 0, to: bytes.count, by: 3).map {
            Int32(bitPattern: UInt32(bytes[$0]) << 8 | UInt32(bytes[$0 + 1]) << 16 | UInt32(bytes[$0 + 2]) << 24) >> 8
        }
        #expect(values == [0, 4_194_304, -4_194_304, 8_388_607, -8_388_608, 8_388_607, -8_388_608, 1, 0])
        #expect(Array(bytes[3..<6]) == [0x00, 0x00, 0x40], "little-endian")
    }

    @Test("LPCM needs no encoder, and its bitrate is 48 kHz x 24 bits a channel")
    func lpcmAvailability() {
        var os26 = false
        if #available(macOS 26.0, *) { os26 = true }
        for layout in HeightsLayout.allCases {
            #expect(HeightsOutput.apac.isAvailable(for: layout) == layout.isAvailable)
            #expect(HeightsOutput.lpcm.isAvailable(for: layout) == (ObjectAudioRendering.rendererIsLinked && os26))
        }
        #expect(PrismCoreSession.describe(.heights, allowsAtmosOutput: true, layout: .atmos7_1_4, output: .lpcm)
            .hasPrefix("heights lpcm"))
        // 12 x 24 x 48 000 = 13.824 Mbit/s.
        #expect(HeightsLayout.atmos7_1_4.channelCount * 24 * 48_000 == 13_824_000)
    }

    @Test("APAC stays the default everywhere: options, writer, report; LPCM only when asked, and a clone keeps it")
    func apacStaysTheDefault() async throws {
        let url = URL(fileURLWithPath: "/nonexistent.mkv")
        let session = try PrismCoreSession(url: url, objectAudioRendering: .heights, allowsAtmosOutput: true)
        #expect(await session.options.heightsOutput == .apac)
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let writer = AudioRenditionWriter(
            route: .init(index: 1, mode: .bridge), track: Self.atmosTrack, ordinal: 0, parent: parent, rendersHeights: true
        )
        #expect(writer.heightsOutput == .apac)
        #expect(!PrismCoreSession.describe(.heights, allowsAtmosOutput: true).contains("lpcm"))
        let lpcm = try PrismCoreSession(url: url, objectAudioRendering: .heights, allowsAtmosOutput: true, heightsOutput: .lpcm)
        #expect(await lpcm.options.heightsOutput == .lpcm)
        let clone = try await lpcm.makeSession { $0.heightsLayout = .atmos5_1_2 }
        #expect(await clone.options.heightsOutput == .lpcm)
    }

    private static func labels(_ layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
        let descriptions = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { descriptions[$0].mChannelLabel }
    }

    /// Each layout's labels as `CoreAudioBaseTypes.h` lists them for its `Atmos_*` tag.
    private static let atmosLabels: [HeightsLayout: [AudioChannelLabel]] = {
        let bed = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                   kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        let rear = [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]
        let middle = [kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_RightTopMiddle]
        let four = [kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight,
                    kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear]
        return [.atmos5_1_2: bed + middle, .atmos5_1_4: bed + four, .atmos7_1_2: bed + rear + middle, .atmos7_1_4: bed + rear + four]
    }()

    @Test("After a seek the renderer starts at a major sync and stamps from it")
    func seekStartsAtAMajorSync() throws {
        guard #available(macOS 26.0, *), ObjectAudioRendering.isAvailable else { return }
        let (context, close) = try open("h264_truehd51_tones_3s.mkv")
        defer { close() }
        let stream = context.pointee.streams[1]!
        let bridge = try HeightsBridge(codecpar: stream.pointee.codecpar, timeBase: stream.pointee.time_base)
        let target = av_rescale_q(1_500_000, AVRational(num: 1, den: 1_000_000), stream.pointee.time_base)
        try FFmpegError.check(avformat_seek_file(context, 1, Int64.min, target, target, 0), "seek")
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var firstSync: Int64?
        var stamps: [Int64] = []
        while av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == 1, let data = pkt.pointee.data else { continue }
            if firstSync == nil, TrueHDMajorSync.startsWithMajorSync(UnsafeBufferPointer(start: data, count: Int(pkt.pointee.size))) {
                firstSync = av_rescale_q(pkt.pointee.pts, stream.pointee.time_base, AVRational(num: 1, den: 48_000))
            }
            try bridge.feed(pkt) { stamps.append($0.pointee.pts) }
        }
        try bridge.flush { stamps.append($0.pointee.pts) }
        let sync = try #require(firstSync)
        #expect(sync > 48_000, "the seek landed past the start")
        #expect(stamps.first == sync - 2048, "first packet sits one priming before the major sync")
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $1 - $0 == 1024 })

        // A flushed encoder comes back after a reset: the same path a jump in the source's
        // timestamps takes mid-stream.
        try bridge.reset()
        try FFmpegError.check(avformat_seek_file(context, 1, Int64.min, 0, 0, 0), "seek to start")
        var again: [Int64] = []
        while again.count < 10, av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == 1 else { continue }
            try bridge.feed(pkt) { again.append($0.pointee.pts) }
        }
        #expect(again.first == -2048, "the stream's first major sync is at 0: \(again.prefix(2))")
    }

    /// A real Atmos stream (one of the truehd crate's public test streams, which are not
    /// redistributable here) muxed under a test picture and served by a whole session.
    /// `PRISMCORE_TRUEHD_VECTORS` = the crate's `truehd/tests/assets` in Cargo's checkout.
    @Test("Real Atmos (opt-in): a session serves apac and reports rendered heights")
    func realAtmosVector() async throws {
        guard ObjectAudioRendering.isAvailable,
              let vectors = ProcessInfo.processInfo.environment["PRISMCORE_TRUEHD_VECTORS"] else { return }
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("atmos.mkv")
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ffmpeg.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=1",
                            "-f", "truehd", "-i", vectors + "/fba_atmos_dimtrim.mlp", "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-g", "12",
                            "-pix_fmt", "yuv420p", "-c:a", "copy", "-shortest", "-y", source.path]
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        #expect(ffmpeg.terminationStatus == 0)
        #expect(try SourceProbe.probe(url: source).audioTracks.first?.isObjectAudio == true)
        do {
            var input: UnsafeMutablePointer<AVFormatContext>?
            try FFmpegError.check(avformat_open_input(&input, source.path, nil, nil), "open")
            defer { avformat_close_input(&input) }
            #expect(TrueHDAtmosScout.scan(input: try #require(input), streams: [1]) == [1: true])
        }
        let session = try PrismCoreSession(
            url: source, display: .init(isHDRReady: false, isDolbyVisionCapable: false),
            objectAudioRendering: .heights, allowsAtmosOutput: true
        )
        let playlist = try await session.start()
        let master = try String(contentsOf: playlist, encoding: .utf8)
        #expect(master.contains("apac.31.03"))
        // Production runs ahead of any fetch; wait for the renderer's verdict.
        for _ in 0..<100 where session.audioTrackDeliveries.first?.objectAudio != .renderedHeights {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.audioTrackDeliveries.first?.objectAudio == .renderedHeights)
        await session.stop()
    }

    /// Throughput of the whole heights chain (decode, render, limit, APAC encode, packetize) on
    /// one thread, in CPU time so a loaded machine still measures the work:
    /// `PRISMCORE_HEIGHTS_BENCH=/path/to/truehd-atmos.mkv swift test --filter heightsThroughput`.
    @Test("Heights throughput (opt-in benchmark)")
    func heightsThroughput() throws {
        guard #available(macOS 26.0, *), ObjectAudioRendering.isAvailable,
              let path = ProcessInfo.processInfo.environment["PRISMCORE_HEIGHTS_BENCH"] else { return }
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let index = try #require((0..<Int(context.pointee.nb_streams)).first {
            context.pointee.streams[$0]!.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_TRUEHD
        })
        let stream = context.pointee.streams[index]!
        let bridge = try HeightsBridge(codecpar: stream.pointee.codecpar, timeBase: stream.pointee.time_base)
        var delivery: ObjectAudioDelivery?
        bridge.onObjectAudio = { delivery = $0; _ = $1 }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var (fed, out, firstOutputAfter) = (0, 0, -1)
        var bytes = 0
        var cpuInFeed: UInt64 = 0
        var worstFeed: UInt64 = 0
        let wall = ContinuousClock.now
        while av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard Int(pkt.pointee.stream_index) == index else { continue }
            fed += 1
            let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            try bridge.feed(pkt) { out += 1; bytes += Int($0.pointee.size) }
            let spent = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before
            cpuInFeed += spent
            worstFeed = max(worstFeed, spent)
            if out > 0, firstOutputAfter < 0 { firstOutputAfter = fed }
        }
        let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        try bridge.flush { out += 1; bytes += Int($0.pointee.size) }
        cpuInFeed += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before
        let audio = Double(out * HeightsBridge.framesPerPacket) / 48_000
        let cpu = Double(cpuInFeed) / 1e9
        print(String(
            format: "heights bench: %.1f s audio, %d packets in, %d APAC packets (%.0f kbit/s), %@; CPU %.2f s = %.1fx real time per core; wall %@; worst single feed %.1f ms; first APAC packet after %d input packets",
            audio, fed, out, Double(bytes * 8) / audio / 1000, String(describing: delivery), cpu, audio / cpu,
            String(describing: ContinuousClock.now - wall), Double(worstFeed) / 1e6, firstOutputAfter
        ))
        #expect(out > 0)
    }

    /// One TrueHD Atmos source rendered to 12-channel 7.1.4 CAF (Float32,
    /// `kAudioChannelLayoutTag_Atmos_7_1_4`) and, with `afconvert`, APAC `.mp4`, for listening:
    /// `<name>.heights.*` is what `.heights` plays (the exact object render), `<name>.split.*`
    /// the split of the 7.1 presentation it falls back to (what 3.8 played).
    /// `PRISMCORE_HEIGHTS_EXPORT=/path/to/atmos.mkv [PRISMCORE_HEIGHTS_EXPORT_SECONDS=60]
    /// swift test --filter heightsListeningExport`. Files land next to the source.
    @Test("Heights listening export (opt-in)")
    func heightsListeningExport() throws {
        guard #available(macOS 26.0, *), ObjectAudioRendering.isAvailable,
              let path = ProcessInfo.processInfo.environment["PRISMCORE_HEIGHTS_EXPORT"] else { return }
        let limit = ProcessInfo.processInfo.environment["PRISMCORE_HEIGHTS_EXPORT_SECONDS"].flatMap(Double.init) ?? .infinity
        let source = URL(fileURLWithPath: path)
        for split in [false, true] {
            let stem = source.deletingPathExtension().path + (split ? ".split" : ".heights")
            let caf = URL(fileURLWithPath: stem + ".caf")
            try? FileManager.default.removeItem(at: caf)
            let pcm = try exportPCM(source: source, split: split, seconds: limit)
            let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4))
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: true, channelLayout: layout)
            let file = try AVAudioFile(forWriting: caf, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            let frames = pcm.count / 12
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            pcm.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: pcm.count) }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            // `mp4f`: afconvert refuses APAC in `m4af`.
            let mp4 = stem + ".mp4"
            try? FileManager.default.removeItem(atPath: mp4)
            let afconvert = Process()
            afconvert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            afconvert.arguments = ["-f", "mp4f", "-d", "apac", "-b", "\(HeightsBridge.bitRate(.atmos7_1_4))", caf.path, mp4]
            try afconvert.run()
            afconvert.waitUntilExit()
            print("heights export: \(caf.path) (\(Double(frames) / 48_000) s)\(afconvert.terminationStatus == 0 ? ", " + mp4 : "; afconvert failed")")
        }
    }

    /// The library's interleaved 7.1.4 for a TrueHD track, through the C API the bridge uses,
    /// from the first major sync on.
    private func exportPCM(source: URL, split: Bool, seconds: Double) throws -> [Float] {
        #if canImport(TrueHDObjects)
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, source.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let index = try #require((0..<Int(context.pointee.nb_streams)).first {
            context.pointee.streams[$0]!.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_TRUEHD
        })
        let session = try #require(split ? truehd_objects_open_split() : truehd_objects_open())
        defer { truehd_objects_close(session) }
        final class Sink { var pcm: [Float] = [] }
        let sink = Sink()
        let context2 = Unmanaged.passUnretained(sink).toOpaque()
        let callback: TrueHDObjectsPCM = { context, pcm, frames in
            let sink = Unmanaged<Sink>.fromOpaque(context!).takeUnretainedValue()
            sink.pcm.append(contentsOf: UnsafeBufferPointer(start: pcm, count: Int(frames) * 12))
            return 0
        }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var started = false
        while av_read_frame(context, pkt) >= 0, Double(sink.pcm.count / 12) / 48_000 < seconds {
            defer { av_packet_unref(pkt) }
            guard Int(pkt.pointee.stream_index) == index, let data = pkt.pointee.data else { continue }
            let bytes = UnsafeBufferPointer(start: data, count: Int(pkt.pointee.size))
            if !started { started = TrueHDMajorSync.startsWithMajorSync(bytes) }
            guard started else { continue }
            #expect(truehd_objects_push(session, bytes.baseAddress, bytes.count, 0, callback, context2) == 0)
        }
        #expect(truehd_objects_push(session, nil, 0, 1, callback, context2) == 0)
        print("heights export: \(split ? "split" : "heights") mode \(truehd_objects_mode(session))")
        return sink.pcm
        #else
        return []
        #endif
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PrismCoreHeights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func open(_ name: String) throws -> (UnsafeMutablePointer<AVFormatContext>, () -> Void) {
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, try fixture(name).path, nil, nil), "avformat_open_input")
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        return (context, { avformat_close_input(&input) })
    }

    /// The tones fixture's TrueHD through a heights rendition, cut every second.
    private func renderFixture(
        into parent: URL, layout: HeightsLayout = .atmos7_1_4, output: HeightsOutput = .apac
    ) throws -> (AudioRenditionWriter, [ObjectAudioDelivery]) {
        let (context, close) = try open("h264_truehd51_tones_3s.mkv")
        defer { close() }
        let writer = AudioRenditionWriter(
            route: .init(index: 1, mode: .bridge), track: Self.atmosTrack, ordinal: 0, parent: parent, rendersHeights: true,
            heightsLayout: layout, heightsOutput: output
        )
        var deliveries: [ObjectAudioDelivery] = []
        writer.onObjectAudio = { delivery, _ in deliveries.append(delivery) }
        try writer.open(input: context)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        let timeBase = context.pointee.streams[1]!.pointee.time_base
        var nextCut = 1.0
        while av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == 1 else { continue }
            if Double(pkt.pointee.pts) * av_q2d(timeBase) >= nextCut {
                try writer.cut(durationSeconds: 1)
                nextCut += 1
            }
            try writer.write(pkt, sourceTimeBase: timeBase)
        }
        try writer.flushBridge()
        try writer.finish(durationSeconds: 1, endList: true)
        return (writer, deliveries)
    }

    /// Interleaved float PCM in the layout's channel order, and the presentation time of its
    /// first frame.
    private func decode(_ url: URL, layout target: HeightsLayout = .atmos7_1_4) async throws -> ([Float], Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = target.layoutTag
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: target.channelCount, AVSampleRateKey: 48_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        reader.add(output)
        #expect(reader.startReading())
        var pcm: [Float] = []
        var first: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if first == nil { first = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            pcm += chunk
        }
        #expect(reader.status == .completed, "\(String(describing: reader.error))")
        return (pcm, first ?? .nan)
    }

    private func goertzel(_ pcm: [Float], channels: Int = 12, channel: Int, frequency: Double, window: Range<Int>) -> Double {
        let w = 2 * Double.pi * frequency / 48_000
        var (s1, s2) = (0.0, 0.0)
        for frame in window {
            let s = Double(pcm[frame * channels + channel]) + 2 * cos(w) * s1 - s2
            s2 = s1
            s1 = s
        }
        return s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
    }
}
