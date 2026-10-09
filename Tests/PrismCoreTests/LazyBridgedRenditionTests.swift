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
        let deliveries = await session.audioTrackDeliveries
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
