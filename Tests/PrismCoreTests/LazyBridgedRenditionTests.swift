import Testing
import Foundation
import Libavformat
import Libavcodec
import Libavutil
@testable import PrismCore

/// Issue #122: a bridged audio rendition that is not the DEFAULT is not
/// encoded until someone selects it, and a sequential session leaves such
/// renditions (and the dialogue-boost levels) out instead of encoding them
/// for the whole film.
///
/// The fixture (`h264_ac3_dts_20s.mkv`) is synthetic — 20 s of testsrc2,
/// 2 s keyframes, Cues — with a 5.1 AC3 `eng` track flagged default (stream
/// copy, and a boost base) and a mono DTS `ces` track (bridged). Every build
/// can bridge it: the target falls back to AAC where `eac3` is missing.
@Suite("Lazy bridged renditions", .serialized)
struct LazyBridgedRenditionTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func files(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private func waitUntil(_ timeout: Duration = .seconds(10), _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - The decision

    @Test("DEFAULT and stream copy are eager; encoders are lazy when planned and omitted when not")
    func productionTable() {
        typealias P = AudioRenditionProduction.Production
        let cases: [(HLSRemuxer.AudioRouteMode, Bool, Bool, P)] = [
            (.bridge, true, true, .eager),
            (.bridge, true, false, .eager),
            (.streamCopy, false, true, .eager),
            (.streamCopy, false, false, .eager),
            (.bridge, false, true, .lazy),
            (.bridge, false, false, .omitted),
            (.boost(.medium), false, true, .lazy),
            (.boost(.high), false, false, .omitted),
        ]
        for (mode, isDefault, planned, expected) in cases {
            #expect(
                HLSRemuxer.audioProduction(mode: mode, isDefault: isDefault, planned: planned) == expected,
                "\(mode) default=\(isDefault) planned=\(planned)"
            )
        }
    }

    @Test("The summary line names every group, boost levels by their base stream")
    func summaryLine() {
        let line = AudioRenditionProduction.summary([
            .init(streamIndex: 1, dialogueBoost: nil, encodes: false, production: .eager),
            .init(streamIndex: 2, dialogueBoost: nil, encodes: true, production: .lazy),
            .init(streamIndex: 1, dialogueBoost: .medium, encodes: true, production: .lazy),
        ])
        #expect(line == "eager #1; lazy #2 #1/boost-medium; omitted none")
        #expect(AudioRenditionProduction.summary([]) == "eager none; lazy none; omitted none")
    }

    // MARK: - Planned shape

    @Test("A non-default bridged rendition runs no bridge until fetched, then serves a whole segment at the demanded time")
    func bridgedAlternateIsProducedOnDemand() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_ac3_dts_20s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let work = await session.workDirectory
        let base = playlist.deletingLastPathComponent()

        let productions = await session.audioRenditionProductions
        #expect(productions == [
            .init(streamIndex: 1, dialogueBoost: nil, encodes: false, production: .eager),
            .init(streamIndex: 2, dialogueBoost: nil, encodes: true, production: .lazy),
        ])
        // Declared all the same, with the bridge's codec and channel count —
        // read off a bridge that was opened once at setup and closed again.
        let master = try String(contentsOf: work.appendingPathComponent("master.m3u8"), encoding: .utf8)
        let ces = try #require(master.split(separator: "\n").first { $0.contains("URI=\"audio1/") })
        #expect(ces.contains("LANGUAGE=\"ces\""), "\(ces)")
        #expect(ces.contains("CHANNELS=\"1\""), "\(ces)")
        #expect(!ces.contains("DEFAULT=YES"), "\(ces)")
        // The track is carried, it is just not running yet.
        let deliveries = session.audioTrackDeliveries
        #expect(deliveries.first { $0.streamIndex == 2 }?.delivery == .bridged)

        // (1) Production runs the whole file before any fetch: the DEFAULT
        // rendition lands its segments, the DTS directory holds its planned
        // playlist and nothing else — no init, no segment — so no bridge was
        // ever fed.
        let audio0 = work.appendingPathComponent("audio0")
        let audio1 = work.appendingPathComponent("audio1")
        await waitUntil { self.files(in: audio0).contains("seg00003.m4s") }
        #expect(files(in: audio0).contains("init.mp4"))
        #expect(files(in: audio1) == ["index.m3u8"])

        // (2) A mid-film switch: AVPlayer asks for the init, then the segment
        // at the playhead. The first fetch arms the rendition and re-anchors
        // production; both are served.
        let (initData, initResponse) = try await URLSession.uncached.data(
            from: base.appendingPathComponent("audio1/init.mp4")
        )
        #expect((initResponse as? HTTPURLResponse)?.statusCode == 200)
        let bridgeBox = AudioBridge.defaultTargetCodecName == "eac3" ? "dec3" : "esds"
        #expect(initData.range(of: Data(bridgeBox.utf8)) != nil, "init must describe the bridge codec")
        let (segment, response) = try await URLSession.uncached.data(
            from: base.appendingPathComponent("audio1/seg00002.m4s")
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(segment.range(of: Data("moof".utf8)) != nil)

        // (3) The segment is the one the playlist promised: segment 2 opens
        // at 8 s (a 2 s head, then 6 s entries), and its audio decodes from
        // there — not from wherever the producer happened to be.
        let firstSeconds = try Self.firstPacketSeconds(initSegment: initData, media: segment)
        #expect(abs(firstSeconds - 8.0) < 0.25, "first sample at \(firstSeconds) s")
    }

    @Test("TrueHD: the bridged DEFAULT and a lazy TrueHD alternate serve the planned time across a forward and a backward seek")
    func trueHDSeeksLandOnThePlan() async throws {
        // h264_truehd_14s.mkv: 14 s of testsrc2, 2 s keyframes, Cues; a 5.1
        // TrueHD `eng` track flagged default and a stereo TrueHD `ces` one,
        // both digital silence (FFmpeg's experimental TrueHD encoder makes
        // anything louder megabytes). Generated with system ffmpeg:
        //   -f lavfi -i testsrc2=size=320x180:rate=24
        //   -f lavfi -i anullsrc=channel_layout=5.1:sample_rate=48000
        //   -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000
        //   -t 14 -c:v libx264 -crf 35 -g 48 -c:a truehd -strict -2
        // It pins timing and the seek path, never TrueHD-Atmos fidelity —
        // that needs real media and a device.
        let session = try PrismCoreSession(url: try fixture("h264_truehd_14s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let base = playlist.deletingLastPathComponent()

        #expect(await session.audioRenditionProductions == [
            .init(streamIndex: 1, dialogueBoost: nil, encodes: true, production: .eager),
            .init(streamIndex: 2, dialogueBoost: nil, encodes: true, production: .lazy),
        ])
        // The plan covers the file on keyframes, no entry past a target.
        let plan = try #require(await session.diagnosticReport().startup.plan)
        #expect(plan.basis == "keyframeIndex")
        #expect(plan.indexCoversEnd == true)
        #expect(plan.maxSegmentSeconds <= 6.01, "\(plan)")

        // Segment first, then init: a lazy rendition's first SEGMENT fetch
        // re-anchors production on that segment (an init fetch would anchor
        // wherever the playhead was).
        func firstSeconds(_ directory: String, _ segment: Int) async throws -> Double {
            let prefix = directory.isEmpty ? "" : directory + "/"
            let (media, response) = try await URLSession.uncached.data(
                from: base.appendingPathComponent(prefix + String(format: "seg%05d.m4s", segment))
            )
            #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(prefix)\(segment)")
            let (initData, _) = try await URLSession.uncached.data(from: base.appendingPathComponent(prefix + "init.mp4"))
            return try Self.firstPacketSeconds(initSegment: initData, media: media)
        }
        // Segments open at 0, 2 and 8 s (a 2 s head, then 6 s entries). The
        // whole file is produced first — the producer parks at EOF — with the
        // TrueHD alternate never fed.
        let work = await session.workDirectory
        let audio1 = work.appendingPathComponent("audio1")
        await waitUntil { self.files(in: work.appendingPathComponent("audio0")).contains("seg00002.m4s") }
        #expect(files(in: audio1) == ["index.m3u8"])
        // FORWARD: its first fetch re-anchors production on segment 2 —
        // segment 1 is never made on the way — and the answer starts at 8 s.
        #expect(abs(try await firstSeconds("audio1", 2) - 8) < 0.25)
        #expect(!files(in: audio1).contains("seg00001.m4s"), "production walked from the head instead of seeking")
        // BACKWARD: segment 1 does not exist, so this fetch is a re-anchor
        // to 2 s. Both re-anchors here come after EOF, which drained the
        // bridges, so they are REBUILT (`trueHDResetBeforeEOF` covers the
        // reset of a live one).
        #expect(abs(try await firstSeconds("audio1", 1) - 2) < 0.25)
        // The DEFAULT bridge and the video are rewritten by the same
        // re-anchors and still open where the playlist says.
        #expect(abs(try await firstSeconds("audio0", 2) - 8) < 0.25)
        #expect(abs(try await firstSeconds("audio0", 1) - 2) < 0.25)
        #expect(abs(try await firstSeconds("", 1) - 2) < 0.1)
    }

    @Test("TrueHD: a backward re-anchor while the bridges are live resets them and lands on the plan")
    func trueHDResetBeforeEOF() async throws {
        // ~60 KB/s: the 1.08 MB fixture takes ~18 s to read, so production
        // is mid-file whenever the test acts — no bridge has reached EOF,
        // been drained, and taken `reanchor`'s rebuild branch.
        let server = try RangeFixtureServer(
            media: try Data(contentsOf: try fixture("h264_truehd_14s.mkv")), bytesPerSecond: 60_000
        )
        let url = try await server.start()
        defer { server.stop() }
        let session = try PrismCoreSession(url: url)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let base = playlist.deletingLastPathComponent()
        let work = await session.workDirectory
        #expect(try #require(await session.diagnosticReport().startup.plan).basis == "keyframeIndex")

        // Arm the TrueHD alternate on the LAST segment (8–14 s) and leave the
        // fetch waiting: production re-anchors there and both bridges run.
        let forward = Task {
            _ = try? await URLSession.uncached.data(from: base.appendingPathComponent("audio1/seg00002.m4s"))
        }
        defer { forward.cancel() }
        var alternateFed = false
        let deadline = ContinuousClock.now + .seconds(20)
        while !alternateFed, ContinuousClock.now < deadline {
            alternateFed = session.audioTrackDeliveries
                .first { $0.streamIndex == 2 }?.bridge.map { $0.inputPackets > 0 } ?? false
            if !alternateFed { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(alternateFed, "the alternate's bridge was never fed")
        // The last segment has not landed anywhere: no rendition reached EOF,
        // so the re-anchor below finds every bridge live and RESETS it.
        #expect(!files(in: work.appendingPathComponent("audio0")).contains("seg00002.m4s"))
        #expect(!files(in: work.appendingPathComponent("audio1")).contains("seg00002.m4s"))

        // BACKWARD to segment 1 (2 s), mid-production.
        let (segment, response) = try await URLSession.uncached.data(
            from: base.appendingPathComponent("audio1/seg00001.m4s")
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let (initData, _) = try await URLSession.uncached.data(from: base.appendingPathComponent("audio1/init.mp4"))
        let check = SegmentVerifier.verify(initSegment: initData, mediaSegment: segment)
        #expect(!check.hasErrors && check.audioFrames > 0, "\(check.problems)")
        #expect(abs(try Self.firstPacketSeconds(initSegment: initData, media: segment) - 2) < 0.25)
        // The DEFAULT TrueHD bridge, reset by the same re-anchor.
        let (defaultSegment, _) = try await URLSession.uncached.data(from: base.appendingPathComponent("audio0/seg00001.m4s"))
        let (defaultInit, _) = try await URLSession.uncached.data(from: base.appendingPathComponent("audio0/init.mp4"))
        #expect(abs(try Self.firstPacketSeconds(initSegment: defaultInit, media: defaultSegment) - 2) < 0.25)
    }

    /// Opens init + one fragment as one file and returns the first packet's
    /// presentation time — the fragment's `tfdt`, as a demuxer reads it.
    private static func firstPacketSeconds(initSegment: Data, media: Data) throws -> Double {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreLazyBridged-\(UUID().uuidString).mp4")
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

    // MARK: - Across a producer recovery

    /// A re-open (`ProducerRecoveryPolicy`) closes the context every bridge
    /// and muxer was built from. The armed rendition must come back on the
    /// NEW context's streams — a bridge or muxer still pointing into the old
    /// one reads freed memory, which is the likeliest way for a recovery to
    /// crash rather than heal.
    @Test("A lazy bridged rendition armed before a source failure is produced from the re-opened context")
    func armedRenditionSurvivesProducerRecovery() async throws {
        // 20 s, ~76 KB/s: the gate at 700 KB holds production inside
        // segment 2 (8–14 s) until the test lets the failure through.
        let factory = FlakyInputFactory(
            media: try Data(contentsOf: try fixture("h264_ac3_dts_20s.mkv")),
            behaviours: [.gate(at: 700_000)]
        )
        let session = try PrismCoreSession(url: URL(string: "prismcore-test://lazy.mkv")!, input: factory.make)
        let events = EventLog(await session.playbackEvents())
        let playlist = try await session.start()
        let base = playlist.deletingLastPathComponent()
        await waitUntil { factory.gated }
        #expect(factory.gated)

        // Arm the bridged DTS rendition while the producer holds the old
        // context: its bridge is built from that context's stream.
        // The loopback arms it on receipt, before the fetch waits for
        // anything; half a second is that receipt with room to spare.
        async let initFetch = URLSession.uncached.data(from: base.appendingPathComponent("audio1/init.mp4"))
        try await Task.sleep(for: .milliseconds(500))
        factory.openGate()

        await waitUntil { events.contains { if case .producerRecovered = $0 { true } else { false } } }
        #expect(events.contains { if case .producerRecovered = $0 { true } else { false } }, "\(events.snapshot)")
        let (initData, initResponse) = try await initFetch
        #expect((initResponse as? HTTPURLResponse)?.statusCode == 200)

        // Segment 2 is the seam (production failed inside it), 3 is after.
        for index in [2, 3] {
            let (segment, response) = try await URLSession.uncached.data(
                from: base.appendingPathComponent(String(format: "audio1/seg%05d.m4s", index))
            )
            #expect((response as? HTTPURLResponse)?.statusCode == 200, "audio1 segment \(index)")
            let check = SegmentVerifier.verify(initSegment: initData, mediaSegment: segment)
            #expect(!check.hasErrors && check.audioFrames > 0, "audio1 segment \(index): \(check.problems)")
            let first = try Self.firstPacketSeconds(initSegment: initData, media: segment)
            let planned = 2.0 + Double(index - 1) * 6
            #expect(abs(first - planned) < 0.25, "audio1 segment \(index) opens at \(first) s, planned \(planned) s")
        }
        let report = try await SegmentVerifier.verify(playlist: playlist)
        #expect(!report.hasErrors, "findings: \(report.findings)")
        await session.stop()
    }

    // MARK: - Sequential shape

    @Test("A sequential session declares only what it produces: no bridged alternate, no boost")
    func sequentialOmitsEncodedRenditions() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreSequentialAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        // A zero index-load budget is the field shape: the Cues sit at the
        // tail, the bounded seek gives up, the session runs sequentially.
        let remuxer = HLSRemuxer(
            sourceURL: try fixture("h264_ac3_dts_20s.mkv"),
            outputDirectory: output,
            demand: DemandCoordinator(),
            dialogueBoost: [.medium, .high],
            indexLoadBudget: .zero
        )
        try remuxer.run()

        let variant = try String(contentsOf: output.appendingPathComponent("index.m3u8"), encoding: .utf8)
        #expect(variant.contains("#EXT-X-PLAYLIST-TYPE:EVENT"), "the session planned; this test needs the sequential shape")
        let master = try String(contentsOf: output.appendingPathComponent("master.m3u8"), encoding: .utf8)
        let audioLines = master.split(separator: "\n").filter { $0.contains("TYPE=AUDIO") }
        #expect(audioLines.count == 1, "\(audioLines)")
        #expect(audioLines.first?.contains("URI=\"audio0/") == true)
        #expect(audioLines.first?.contains("DEFAULT=YES") == true)
        // Nothing was set up for the left-out renditions — not even a directory.
        let renditionDirectories = files(in: output).filter { $0.hasPrefix("audio") }
        #expect(renditionDirectories == ["audio0"], "\(renditionDirectories)")
        #expect(files(in: output.appendingPathComponent("audio0")).contains("seg00000.m4s"))

        // The host's contracts say the same thing the master does.
        #expect(remuxer.dialogueBoostRenditions.isEmpty)
        var expected: [AudioRenditionProduction] = [
            .init(streamIndex: 1, dialogueBoost: nil, encodes: false, production: .eager),
            .init(streamIndex: 2, dialogueBoost: nil, encodes: true, production: .omitted),
        ]
        if PrismCoreSession.isDialogueBoostAvailable {
            expected += [
                .init(streamIndex: 1, dialogueBoost: .medium, encodes: true, production: .omitted),
                .init(streamIndex: 1, dialogueBoost: .high, encodes: true, production: .omitted),
            ]
        }
        #expect(remuxer.audioRenditionProductions == expected)
        let dts = remuxer.audioDeliveryStore.snapshot.first { $0.streamIndex == 2 }
        #expect(dts?.delivery == .unavailable)
    }
}
