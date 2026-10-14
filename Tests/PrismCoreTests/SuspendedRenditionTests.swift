import Testing
import Foundation
import Libavformat
import Libavcodec
import Libavutil
@testable import PrismCore

/// An encoded audio rendition the player has switched away from stops being
/// encoded, and starts again when the player comes back to it. The profile
/// that asked for this: a bridged DEFAULT plus the bridged track the viewer
/// switched to cost 9.9 s of CPU per 150 s of 4K instead of 5.1 s — the
/// encoder exactly twice.
///
/// The fixture (`h264_opus_opus_60s.mkv`, `generate_switch_away.sh`) has two
/// bridged Opus tracks: `eng` flagged default, `ces` not. Each is a click on
/// every whole second, so a served segment can be checked by ear for where
/// its audio sits.
@Suite("Suspended renditions", .serialized)
struct SuspendedRenditionTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func files(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    // MARK: - The decisions

    @Test("Only an encoded rendition of a planned session can be suspended")
    func suspendableTable() {
        #expect(HLSRemuxer.audioSuspendable(mode: .bridge, planned: true))
        #expect(HLSRemuxer.audioSuspendable(mode: .boost(.medium), planned: true))
        #expect(!HLSRemuxer.audioSuspendable(mode: .streamCopy, planned: true))
        #expect(!HLSRemuxer.audioSuspendable(mode: .bridge, planned: false), "sequential: nothing to re-anchor on")
        #expect(!HLSRemuxer.audioSuspendable(mode: .boost(.high), planned: false))
    }

    @Test("A rendition is left after three audio segment fetches elsewhere, never while it is fetched")
    func trackerJudgesFromFetches() {
        let n = AudioDemandTracker.abandonAfter
        #expect(n == 3)
        var tracker = AudioDemandTracker(watched: ["audio0", "audio1"])
        // Playing audio0: it is never left, however long it plays. audio1,
        // never fetched, is reported (an unarmed rendition ignores that).
        for _ in 0..<20 {
            #expect(!tracker.noteFetch(under: "audio0", isSegment: true).contains("audio0"))
        }
        // The switch: init, then segments under audio1. Two are a switch
        // burst that may still come back; the third says it is over.
        #expect(tracker.noteFetch(under: "audio1", isSegment: false) == [])
        #expect(tracker.noteFetch(under: "audio1", isSegment: true) == [])
        #expect(tracker.noteFetch(under: "audio1", isSegment: true) == [])
        #expect(tracker.noteFetch(under: "audio1", isSegment: true) == ["audio0"])
        #expect(tracker.noteFetch(under: "audio1", isSegment: true) == ["audio0"], "repeated; suspension is idempotent")
        // Switching back: the fetch of audio0 clears it, and now audio1 is
        // the one counting.
        #expect(tracker.noteFetch(under: "audio0", isSegment: true) == [])
        #expect(tracker.noteFetch(under: "audio0", isSegment: true) == [])
        #expect(tracker.noteFetch(under: "audio0", isSegment: true) == ["audio1"])
    }

    @Test("An init fetch resets its rendition's gap, and a paused player loses nothing")
    func trackerInitAndPause() {
        var tracker = AudioDemandTracker(watched: ["audio0", "audio1"])
        for _ in 0..<5 { _ = tracker.noteFetch(under: "audio0", isSegment: true) }
        // audio1 just selected: its init arrives first. Its first segment is
        // not yet here; an audio0 fetch in between must not judge it left.
        _ = tracker.noteFetch(under: "audio1", isSegment: false)
        #expect(!tracker.noteFetch(under: "audio0", isSegment: true).contains("audio1"))
        // Unwatched directories (a stream copy) count as "elsewhere" but are
        // never reported themselves.
        var copy = AudioDemandTracker(watched: ["audio1"])
        for _ in 0..<10 { #expect(!copy.noteFetch(under: "audio0", isSegment: true).contains("audio0")) }
        // No fetches, no verdicts: time alone never suspends anything.
        var idle = AudioDemandTracker(watched: ["audio0"])
        #expect(idle.noteFetch(under: "audio0", isSegment: true) == [])
    }

    // MARK: - The writer's state machine

    @Test("Suspend applies at a boundary, a re-arm before it cancels it, and a re-arm after it re-anchors")
    func writerSuspendResume() throws {
        let url = try fixture("h264_opus_opus_60s.mkv")
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let audioIndex = 1
        let track = AudioTrackInfo(
            streamIndex: audioIndex, codecName: "opus", profileName: nil,
            channelCount: 1, channelLayoutDescription: "mono",
            sampleRate: 48_000, language: "eng", title: nil,
            isObjectAudio: false, copyability: .requiresAudioBridge
        )
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreSuspendWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("audio0")

        // The bridged DEFAULT: eager, suspendable.
        let writer = AudioRenditionWriter(
            route: .init(index: Int32(audioIndex), mode: .bridge),
            track: track, ordinal: 0, parent: parent, suspendable: true
        )
        try writer.open(input: context)
        try writer.writePlannedVOD(durations: Array(repeating: 2, count: 30))
        #expect(writer.isProducing)
        #expect(writer.arm() == false, "an eager rendition that is wanted needs no arming")

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        func feed(_ count: Int) throws {
            var fed = 0
            while fed < count, av_read_frame(context, pkt) >= 0 {
                defer { av_packet_unref(pkt) }
                guard Int(pkt.pointee.stream_index) == audioIndex else { continue }
                try writer.write(pkt, sourceTimeBase: context.pointee.streams[audioIndex]!.pointee.time_base)
                fed += 1
            }
        }
        try feed(100)
        try writer.cut(durationSeconds: 2)
        #expect(files(in: directory).isSuperset(of: ["init.mp4", "seg00000.m4s"]))

        // (1) Asked to stop, then wanted again before the producer reached a
        // boundary: production never stopped, so the re-arm needs no
        // re-anchor, and the boundary keeps it running.
        #expect(writer.requestSuspend() == true)
        #expect(writer.requestSuspend() == false, "idempotent")
        #expect(writer.arm() == false)
        #expect(writer.suspendIfUnwanted() == false)
        #expect(writer.isProducing)

        // (2) Asked to stop, and the boundary comes first: it stops, and what
        // it fed afterwards lands nowhere.
        #expect(writer.requestSuspend())
        #expect(writer.suspendIfUnwanted())
        #expect(!writer.isProducing)
        #expect(writer.suspensionCounts == (1, 0))
        try feed(100)
        try writer.cut(durationSeconds: 2)
        #expect(!files(in: directory).contains("seg00001.m4s"))
        // A re-anchor while nobody wants it keeps it dormant.
        try writer.reanchor(input: context, segmentIndex: 2)
        #expect(!writer.isProducing)

        // (3) The player comes back: the fetch arms it once and asks for a
        // re-anchor, where it opens again and produces a whole segment.
        #expect(writer.arm() == true)
        #expect(writer.arm() == false, "arming is once")
        try writer.reanchor(input: context, segmentIndex: 3)
        #expect(writer.isProducing)
        #expect(writer.suspensionCounts == (1, 1))
        try feed(100)
        try writer.cut(durationSeconds: 2)
        #expect(files(in: directory).contains("seg00003.m4s"), "\(files(in: directory))")

        // Suspended again with seg00003 on disk: a re-anchored pass over that
        // index keeps the file (and reports it to retention) — unless the
        // audio offset changed since, when the stale file must go.
        #expect(writer.requestSuspend())
        try writer.reanchor(input: context, segmentIndex: 3)
        #expect(!writer.isProducing)
        #expect(writer.suspensionCounts == (2, 1))
        #expect(try writer.cut(durationSeconds: 2) > 0, "retained bytes still count")
        #expect(files(in: directory).contains("seg00003.m4s"))
        try writer.reanchor(input: context, segmentIndex: 3)
        #expect(try writer.cut(durationSeconds: 2, superseded: true) == 0)
        #expect(!files(in: directory).contains("seg00003.m4s"), "a superseded file of a dormant rendition was kept")

        // A stream copy is never suspended, whatever is asked.
        let copy = AudioRenditionWriter(
            route: .init(index: Int32(audioIndex), mode: .streamCopy),
            track: track, ordinal: 1, parent: parent
        )
        #expect(copy.requestSuspend() == false)
        #expect(copy.suspendIfUnwanted() == false)
        writer.close()
    }

    @Test("A pending audio wait re-arms a rendition suspended after its fetch armed it")
    func pendingWaitRearms() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreRearm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio0"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<10).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        coordinator.setProducing(index: 7)
        var provider = PlanSegmentProvider(root: root, coordinator: coordinator)
        // The fetch arms (forced re-anchor at 5); the producer takes it.
        provider.audioDemand = { _ in true }
        // Then three old-track fetches suspend it again before it opened:
        // the first look from the wait finds it dormant and re-arms it.
        let rearms = SuspendLockedBox(0)
        provider.audioRearm = { _ in rearms.withValue { count in count += 1; return count == 1 } }
        guard case .pending(let pending) = await provider.data(forPath: "audio0/seg00005.m4s") else {
            Issue.record("miss must be pending"); return
        }
        #expect(coordinator.takeAnchorRequestDetailed()?.forced == true)
        let serve = Task { await pending.resolve() }
        let deadline = ContinuousClock.now + .seconds(3)
        var again: (index: Int, forced: Bool)?
        while again == nil, ContinuousClock.now < deadline {
            if let request = coordinator.takeAnchorRequestDetailed() { again = (request.index, request.forced) }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(again?.index == 5 && again?.forced == true, "the wait never re-anchored for its dormant rendition")
        try Data("moof".utf8).write(to: root.appendingPathComponent("audio0/seg00005.m4s"))
        guard case .data = await serve.value else { Issue.record("the wait must serve the landed file"); return }
        #expect(rearms.value >= 1)
    }

    @Test("Read-ahead of N+1 pipelined across the takeover of anchor N leaves N's wait served", arguments: [false, true])
    func pipelinedReadAheadKeepsTakenAnchor(resume: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCorePipelined-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio0"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<40).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        // Playing at 2–3; then the player seeks to 20 (or, `resume`, comes
        // back to a suspended rendition whose fetch of 20 re-arms it).
        coordinator.noteFetch(of: 2)
        coordinator.setProducing(index: 3)
        var provider = PlanSegmentProvider(root: root, coordinator: coordinator)
        provider.productionTimeout = .seconds(2)
        let arms = SuspendLockedBox(0)
        provider.audioDemand = { _ in resume && arms.withValue { count in count += 1; return count == 1 } }
        func path(_ index: Int) -> String { String(format: "audio0/seg%05d.m4s", index) }
        guard case .pending(let first) = await provider.data(forPath: path(20)) else {
            Issue.record("miss of 20 must be pending"); return
        }
        // The producer takes 20; its demuxer seek is under way, so
        // `producingIndex` still says 3 when the pipelined 21 arrives.
        let taken = coordinator.takeAnchorRequestDetailed()
        #expect(taken?.index == 20 && taken?.forced == resume)
        guard case .pending(let second) = await provider.data(forPath: path(21)) else {
            Issue.record("miss of 21 must be pending"); return
        }
        let serveFirst = Task { await first.resolve() }
        let serveSecond = Task { await second.resolve() }
        // Past the debounce: a moved anchor would be handed out now, and a
        // producer following it would never write 20.
        try await Task.sleep(for: DemandCoordinator.anchorDebounce * 2)
        var position = 20
        while let request = coordinator.takeAnchorRequestDetailed() { position = request.index }
        #expect(position == 20, "read-ahead moved the anchor off the segment being waited for")
        coordinator.setProducing(index: position)
        try Data("moof".utf8).write(to: root.appendingPathComponent(path(position)))
        coordinator.setProducing(index: position + 1)
        try Data("moof".utf8).write(to: root.appendingPathComponent(path(position + 1)))
        guard case .data = await serveFirst.value else { Issue.record("the wait on 20 timed out"); return }
        guard case .data = await serveSecond.value else { Issue.record("the wait on 21 timed out"); return }
        // A real seek elsewhere still wins over the pending position.
        coordinator.noteFetch(of: 30)
        coordinator.requestProduction(of: 30)
        #expect(coordinator.takeAnchorRequestDetailed()?.index == 30)
    }

    /// A dormant, suspendable rendition (never opened: a lazy one, or one
    /// whose suspension the producer applied) wired into a provider the way
    /// the session wires the remuxer, over a 40-segment plan with the player
    /// on another track at 2–3.
    private func joiningRendition(_ name: String, timeout: Duration) throws
        -> (root: URL, writer: AudioRenditionWriter, coordinator: DemandCoordinator, provider: PlanSegmentProvider) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio0"), withIntermediateDirectories: true)
        let track = AudioTrackInfo(
            streamIndex: 1, codecName: "opus", profileName: nil,
            channelCount: 1, channelLayoutDescription: "mono",
            sampleRate: 48_000, language: "eng", title: nil,
            isObjectAudio: false, copyability: .requiresAudioBridge
        )
        let writer = AudioRenditionWriter(
            route: .init(index: 1, mode: .bridge), track: track, ordinal: 0,
            parent: root, lazy: true, suspendable: true
        )
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<40).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        coordinator.noteFetch(of: 2)
        coordinator.setProducing(index: 3)
        var provider = PlanSegmentProvider(root: root, coordinator: coordinator)
        provider.productionTimeout = timeout
        // The writer's seams are lock-guarded; the type just is not marked.
        nonisolated(unsafe) let rendition = writer
        provider.audioDemand = { _ in rendition.arm() }
        provider.audioRearm = { _ in rendition.arm() }
        provider.audioWait = { path, begin in
            guard let index = PlanSegmentProvider.segmentIndex(inPath: path) else { return }
            if begin { rendition.beginWait(index: index) } else { rendition.endWait(index: index) }
        }
        provider.audioLowestWait = { _ in rendition.lowestPendingWait }
        return (root, writer, coordinator, provider)
    }

    private static func segmentPath(_ index: Int) -> String { String(format: "audio0/seg%05d.m4s", index) }

    @Test("Fetches of N and N+1 of a re-armed rendition, re-suspended before the join and N+1 waking first, are both served")
    func rearmJoinsAtLowestPendingWait() async throws {
        let (root, writer, coordinator, provider) = try joiningRendition("PrismCoreRearmLowest", timeout: .seconds(2))
        defer { try? FileManager.default.removeItem(at: root) }
        // The player comes back: N = 20 arms the rendition (forced join at
        // 20); the pipelined 21 finds it wanted.
        guard case .pending(let first) = await provider.data(forPath: Self.segmentPath(20)),
              case .pending(let second) = await provider.data(forPath: Self.segmentPath(21)) else {
            Issue.record("misses must be pending"); return
        }
        // Three overlapping fetches of the old track judge it left before
        // the producer joined it: a rendition with fetches waiting on it is
        // wanted, and stays so.
        #expect(writer.requestSuspend() == false, "suspended a rendition two fetches are waiting on")
        // N+1's wait wakes first.
        let serveSecond = Task { await second.resolve() }
        try await Task.sleep(for: .milliseconds(100))
        let serveFirst = Task { await first.resolve() }
        try await Task.sleep(for: DemandCoordinator.anchorDebounce * 2)
        var position = 3
        while let request = coordinator.takeAnchorRequestDetailed() { position = request.index }
        #expect(position == 20, "the join moved above the pending segment 20")
        for index in position...21 {
            coordinator.setProducing(index: index)
            try Data("moof".utf8).write(to: root.appendingPathComponent(Self.segmentPath(index)))
        }
        guard case .data = await serveFirst.value else { Issue.record("the wait on 20 timed out"); return }
        guard case .data = await serveSecond.value else { Issue.record("the wait on 21 timed out"); return }
        #expect(writer.lowestPendingWait == nil)
    }

    @Test("An arm or re-arm joins at the rendition's lowest pending wait, not at the fetch that armed it")
    func armJoinsAtLowestPendingWait() async throws {
        let (root, writer, coordinator, provider) = try joiningRendition("PrismCoreArmLowest", timeout: .seconds(2))
        defer { try? FileManager.default.removeItem(at: root) }
        // A wait on 20 already registered when 21's fetch is the one that
        // arms the rendition: the join is at 20.
        writer.beginWait(index: 20)
        guard case .pending(let second) = await provider.data(forPath: Self.segmentPath(21)) else {
            Issue.record("miss of 21 must be pending"); return
        }
        let taken = coordinator.takeAnchorRequestDetailed()
        #expect(taken?.index == 20 && taken?.forced == true)
        // A join production took above a pending wait (another rendition's,
        // say, at 21) is pulled down by that wait's next look.
        writer.endWait(index: 20)
        coordinator.requestProduction(of: 22, force: true)
        _ = coordinator.takeAnchorRequestDetailed()
        let serve = Task { await second.resolve() }
        let deadline = ContinuousClock.now + .seconds(1)
        var lowered: Int?
        while lowered == nil, ContinuousClock.now < deadline {
            lowered = coordinator.takeAnchorRequestDetailed()?.index
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lowered == 21, "a forced join above the pending wait stayed there")
        try Data("moof".utf8).write(to: root.appendingPathComponent(Self.segmentPath(21)))
        guard case .data = await serve.value else { Issue.record("the wait on 21 timed out"); return }
    }

    @Test("A pending wait leaves the registry on timeout, cancellation and a hit, and pins no later join")
    func pendingWaitsEndOnEveryExit() async throws {
        let (root, writer, coordinator, provider) = try joiningRendition("PrismCoreWaitExit", timeout: .milliseconds(300))
        defer { try? FileManager.default.removeItem(at: root) }
        // Timeout.
        guard case .pending(let timesOut) = await provider.data(forPath: Self.segmentPath(20)) else {
            Issue.record("miss of 20 must be pending"); return
        }
        #expect(writer.lowestPendingWait == 20)
        guard case .notFound = await timesOut.resolve() else { Issue.record("expected a timeout"); return }
        #expect(writer.lowestPendingWait == nil, "a timed-out wait stayed registered")
        // Cancellation.
        guard case .pending(let cancelled) = await provider.data(forPath: Self.segmentPath(21)) else {
            Issue.record("miss of 21 must be pending"); return
        }
        let serve = Task { await cancelled.resolve() }
        serve.cancel()
        _ = await serve.value
        #expect(writer.lowestPendingWait == nil, "a cancelled wait stayed registered")
        // A hit.
        try Data("moof".utf8).write(to: root.appendingPathComponent(Self.segmentPath(5)))
        guard case .data = await provider.data(forPath: Self.segmentPath(5)) else { Issue.record("hit"); return }
        #expect(writer.lowestPendingWait == nil, "a served hit stayed registered")
        // Nothing waits: the rendition can be left again, and the next
        // return joins where it is fetched, not at a stale 20.
        #expect(writer.requestSuspend())
        while coordinator.takeAnchorRequestDetailed() != nil {}
        guard case .pending(let later) = await provider.data(forPath: Self.segmentPath(30)) else {
            Issue.record("miss of 30 must be pending"); return
        }
        let join = coordinator.takeAnchorRequestDetailed()
        #expect(join?.index == 30 && join?.forced == true)
        let cancel = Task { await later.resolve() }
        cancel.cancel()
        _ = await cancel.value
    }

    @Test("A seek elsewhere still wins over a joining rendition's pending wait")
    func seekWinsOverPendingJoinWait() async throws {
        let (root, writer, coordinator, provider) = try joiningRendition("PrismCoreSeekWins", timeout: .seconds(2))
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .pending(let stale) = await provider.data(forPath: Self.segmentPath(20)) else {
            Issue.record("miss of 20 must be pending"); return
        }
        #expect(coordinator.takeAnchorRequestDetailed()?.index == 20)
        coordinator.setProducing(index: 20)
        coordinator.setProducing(index: 21)
        // The player seeks to 30: the variant's fetch re-anchors there, while
        // the wait on 20 has not been cancelled yet.
        coordinator.noteFetch(of: 30)
        coordinator.requestProduction(of: 30)
        let serve = Task { await stale.resolve() }
        try await Task.sleep(for: .milliseconds(500))
        var position: Int?
        while let request = coordinator.takeAnchorRequestDetailed() { position = request.index }
        #expect(position == 30, "a pending wait pulled the seek back")
        serve.cancel()
        _ = await serve.value
        #expect(writer.lowestPendingWait == nil)
    }

    // MARK: - A session

    @Test("A bridged DEFAULT the player left stops encoding, and resumes on the timeline when the player comes back")
    func defaultSuspendsAndResumes() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_opus_opus_60s.mkv"))
        let master = try await session.start()
        defer { Task { await session.stop() } }
        let base = master.deletingLastPathComponent()
        let work = await session.workDirectory
        func fetch(_ path: String) async throws -> Data {
            let (data, response) = try await URLSession.uncached.data(from: base.appendingPathComponent(path))
            try #require((response as? HTTPURLResponse)?.statusCode == 200, "\(path)")
            return data
        }
        func segment(_ directory: String, _ index: Int) -> String {
            (directory.isEmpty ? "" : directory + "/") + String(format: "seg%05d.m4s", index)
        }
        func counts() async -> (suspended: Int?, resumed: Int?) {
            let entry = await session.diagnosticReport().runtime?.audioRenditionProductions
                .first { $0.streamIndex == 1 && $0.dialogueBoost == nil }
            return (entry?.suspensions, entry?.resumptions)
        }

        #expect(await session.audioRenditionProductions == [
            .init(streamIndex: 1, dialogueBoost: nil, encodes: true, production: .eager),
            .init(streamIndex: 2, dialogueBoost: nil, encodes: true, production: .lazy),
        ])
        let variant = try String(contentsOf: work.appendingPathComponent("index.m3u8"), encoding: .utf8)
        let durations = variant.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") }
        try #require(durations.count >= 10, "\(variant)")
        let last = durations.count - 1
        func planned(_ index: Int) -> Double { durations.prefix(index).reduce(0, +) }

        // Playing the DEFAULT, as AVPlayer does at load.
        let defaultInit = try await fetch("audio0/init.mp4")
        for index in 0...1 {
            _ = try await fetch(segment("", index))
            _ = try await fetch(segment("audio0", index))
        }
        #expect(await counts() == (0, 0))

        // The switch: the alternate's init and segments, video alongside.
        let alternateInit = try await fetch("audio1/init.mp4")
        for index in 2...4 {
            _ = try await fetch(segment("", index))
            _ = try await fetch(segment("audio1", index))
        }
        // Applied at the producer's next boundary.
        let deadline = ContinuousClock.now + .seconds(20)
        while await counts().suspended != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await counts() == (1, 0))

        // Play the alternate to the end. The DEFAULT encodes nothing more:
        // its tail is never made, the alternate's is.
        for index in 5...last {
            _ = try await fetch(segment("", index))
            let audio = try await fetch(segment("audio1", index))
            let clicks = try ReanchorTimelineTests.clickOnsets(initSegment: alternateInit, media: audio)
            #expect(!clicks.isEmpty, "audio1 seg\(index) is silent")
        }
        let audio0 = work.appendingPathComponent("audio0")
        #expect(!files(in: audio0).contains(String(format: "seg%05d.m4s", last)), "\(files(in: audio0).sorted())")
        #expect(!files(in: audio0).contains(String(format: "seg%05d.m4s", last - 1)))
        #expect(await counts() == (1, 0))

        // The switch back, near the end: every segment the player asks for
        // is served (no 404), audible, through the init it already holds,
        // with its clicks on whole seconds of the film's timeline.
        var resumed = Data()
        for index in (last - 1)...last {
            let audio = try await fetch(segment("audio0", index))
            let clicks = try ReanchorTimelineTests.clickOnsets(initSegment: defaultInit, media: audio)
            #expect(clicks.count >= 2, "audio0 seg\(index): clicks \(clicks)")
            if let first = clicks.first {
                #expect(first >= planned(index) - 0.05 && first < planned(index) + 1.05,
                        "audio0 seg\(index): first click \(first) s, segment opens at \(planned(index)) s")
            }
            resumed += audio
        }
        // Played back to back, as the player does: every second is heard,
        // once, on its second — no gap and no overlap at the seam.
        let heard = try ReanchorTimelineTests.clickOnsets(initSegment: defaultInit, media: resumed)
        for click in heard {
            #expect(abs(click - click.rounded()) < 0.005, "audio0: click at \(click) s")
        }
        let seconds = heard.map { Int($0.rounded()) }
        #expect(seconds.count >= 8 && seconds == Array((seconds.first ?? 0)...(seconds.last ?? 0)), "\(heard)")
        #expect(await counts() == (1, 1))
        #expect(try await fetch("audio0/init.mp4") == defaultInit, "the init the player holds is never replaced")
    }

    @Test("A switch back mid-film, with the old track's fetch still in flight, is served promptly on the plan")
    func midFilmSwitchBackUnderConcurrentFetches() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_opus_opus_60s.mkv"))
        let master = try await session.start()
        defer { Task { await session.stop() } }
        let base = master.deletingLastPathComponent()
        let work = await session.workDirectory
        @Sendable func fetch(_ path: String) async throws -> Data {
            let (data, response) = try await URLSession.uncached.data(from: base.appendingPathComponent(path))
            try #require((response as? HTTPURLResponse)?.statusCode == 200, "\(path)")
            return data
        }
        func segment(_ directory: String, _ index: Int) -> String {
            (directory.isEmpty ? "" : directory + "/") + String(format: "seg%05d.m4s", index)
        }
        func suspended() async -> Int? {
            await session.diagnosticReport().runtime?.audioRenditionProductions
                .first { $0.streamIndex == 1 && $0.dialogueBoost == nil }?.suspensions
        }
        let variant = try String(contentsOf: work.appendingPathComponent("index.m3u8"), encoding: .utf8)
        let durations = variant.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") }
        try #require(durations.count >= 10)
        let last = durations.count - 1

        let defaultInit = try await fetch("audio0/init.mp4")
        _ = try await fetch(segment("audio0", 0))
        _ = try await fetch("audio1/init.mp4")
        for index in 1...3 {
            _ = try await fetch(segment("", index))
            _ = try await fetch(segment("audio1", index))
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while await suspended() != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await suspended() == 1)

        // The first DEFAULT segment the suspension left unmade, mid-film.
        let audio0 = work.appendingPathComponent("audio0")
        let back = try #require((4...last).first {
            !FileManager.default.fileExists(atPath: audio0.appendingPathComponent(String(format: "seg%05d.m4s", $0)).path)
        })
        try #require(back < last - 1, "the suspension came too late to leave a mid-film hole")

        // The switch back, raced by the old track's requests still in
        // flight — the way AVPlayer overlaps connections at a switch.
        let started = ContinuousClock.now
        // The resumed track's own read-ahead is pipelined too: both of its
        // missing segments are asked for at once, the later one able to
        // reach the coordinator before the producer takes the first.
        async let old1 = fetch(segment("audio1", back))
        async let old2 = fetch(segment("audio1", back + 1))
        async let resumed = fetch(segment("audio0", back))
        async let ahead = fetch(segment("audio0", back + 1))
        let (audio, next, _, _) = try await (resumed, ahead, old1, old2)
        #expect(ContinuousClock.now - started < .seconds(8), "a pending wait ran out its window")

        let planned = durations.prefix(back).reduce(0, +)
        let heard = try ReanchorTimelineTests.clickOnsets(initSegment: defaultInit, media: audio + next)
        #expect(heard.count >= 6, "\(heard)")
        if let first = heard.first {
            #expect(first >= planned - 0.05 && first < planned + 1.05, "first click \(first) s, segment opens at \(planned) s")
        }
        let seconds = heard.map { Int($0.rounded()) }
        #expect(seconds == Array((seconds.first ?? 0)...(seconds.last ?? 0)), "\(heard)")
        for click in heard { #expect(abs(click - click.rounded()) < 0.005, "click at \(click) s") }
    }
}

private final class SuspendLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&storage) } }
}
