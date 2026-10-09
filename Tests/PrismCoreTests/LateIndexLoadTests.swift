import Testing
import Foundation
@testable import PrismCore

/// The late index load: a first play that went sequential only because its
/// index-load seek ran out of budget reads the index again in the background,
/// and stores it the moment it is in — not at EOF, which is when the harvest
/// would have it.
///
/// Every play here is held inside segment 1's landing (`HeldPlay`), because a
/// 30 s fixture otherwise reaches EOF in milliseconds — and at EOF the harvest
/// stores the same map, so "stored before EOF" is only provable while the
/// producer provably has not got there.
@Suite("Late index load", .serialized)
struct LateIndexLoadTests {

    private func media(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try Data(contentsOf: try #require(url, "fixture \(name) missing from test bundle"))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreLateIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sidecars(_ directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private static func range(_ request: ScriptedHTTPServer.Request) -> Int? {
        request.headers["range"].flatMap { Int($0.dropFirst("bytes=".count).split(separator: "-").first ?? "") }
    }

    @Test("A budget-expired first play stores the complete map before EOF, says so, and the next session plans from it")
    func budgetExpiredPlayStoresTheIndexBeforeEOF() async throws {
        let cache = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        // Cues at the tail (mkvmerge's layout). The field shape, by latency
        // rather than by a zero budget: the first request past the head — the
        // plan's nudge going for the Cues — never answers, so the budget, not
        // the file, ends the index load. Everything after that is served.
        let bytes = try media("h264_aac_30s.mkv")
        let tailStalled = LockedFlag()
        let origin = try ScriptedHTTPServer { request in
            if (Self.range(request) ?? 0) > 0, !tailStalled.isSet {
                tailStalled.set()
                return .stall
            }
            return ScriptedHTTPServer.ranged(bytes, for: request, validators: ["ETag": "\"v1\""])
        }
        let root = try await origin.start()
        defer { origin.stop() }
        let url = root.appendingPathComponent("movie.mkv")

        let play = HeldPlay(url: url, cache: cache, output: output, indexLoadBudget: .milliseconds(300))
        defer { play.release() }

        let available = await until { play.segmentPlanAvailable != nil }
        #expect(available, "no .segmentPlanAvailable while the producer sat at segment 1")
        #expect(play.planOrigin == .sequential)
        #expect(play.loaderLaunchedBeforeFirstSegment == false,
                "the late load started before the first segment — it would compete with startup")
        // Before EOF: the producer is held, its playlist still open.
        #expect(!play.thread.isFinished)
        let playlist = try String(contentsOf: output.appendingPathComponent("index.m3u8"), encoding: .utf8)
        #expect(!playlist.contains("#EXT-X-ENDLIST"))
        let stored = sidecars(cache)
        #expect(stored.count == 1)
        let entry = try JSONDecoder().decode(
            KeyframeIndexCache.Entry.self, from: Data(contentsOf: try #require(stored.first))
        )
        #expect(entry.complete)

        // The successor the event invites plans on that map, segment for
        // segment the count the event promised.
        let (successorOrigin, successorSegments) = try await Self.sessionPlan(url, cache: cache)
        #expect(successorOrigin == .keyframeIndexCache)
        #expect(successorSegments == play.segmentPlanAvailable)

        play.release()
        await play.thread.join()
        #expect(play.thread.failureIfAny == nil)
    }

    @Test("A late load whose store fails announces nothing — the successor would miss and stay sequential")
    func unwritableCacheAnnouncesNothing() async throws {
        let scratch = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The cache path is a regular file, so every store is refused.
        let cache = scratch.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: cache)
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        // The same shape as the stored-before-EOF test, which proves this
        // load reaches its store: only the cache differs.
        let bytes = try media("h264_aac_30s.mkv")
        let tailStalled = LockedFlag()
        let origin = try ScriptedHTTPServer { request in
            if (Self.range(request) ?? 0) > 0, !tailStalled.isSet {
                tailStalled.set()
                return .stall
            }
            return ScriptedHTTPServer.ranged(bytes, for: request, validators: ["ETag": "\"v1\""])
        }
        let root = try await origin.start()
        defer { origin.stop() }

        let play = HeldPlay(url: root.appendingPathComponent("movie.mkv"), cache: cache, output: output,
                            indexLoadBudget: .milliseconds(300))
        defer { play.release() }
        #expect(await until { play.isHeld })
        let loader = try #require(play.remuxer.lateIndexLoadThread, "the late load never launched — nothing was exercised")
        #expect(await loader.join(within: .seconds(20)))
        // The event is delivered through a stream; give it time to arrive.
        #expect(await until(.milliseconds(500)) { play.segmentPlanAvailable != nil } == false)

        play.release()
        await play.thread.join()
        #expect(play.thread.failureIfAny == nil)
    }

    @Test("No version proof, or no duration: the late load never starts, and nothing is stored or announced")
    func unprovableOrUnplannableSourceDoesNotLoad() async throws {
        let cases: [(fixture: String, validators: [String: String])] = [
            ("h264_aac_30s.mkv", ["ETag": "W/\"v1\""]),
            ("h264_aac_30s.mkv", ["Last-Modified": "Wed, 07 Oct 2026 10:00:00 GMT"]),
            ("h264_aac_30s.mkv", [:]),
            // Strong tag, but no duration — no plan, the live-shaped path.
            ("h264_aac_noduration.mkv", ["ETag": "\"v1\""]),
        ]
        for (fixture, validators) in cases {
            let cache = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: cache) }
            let output = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: output) }
            let bytes = try media(fixture)
            let origin = try ScriptedHTTPServer { ScriptedHTTPServer.ranged(bytes, for: $0, validators: validators) }
            let root = try await origin.start()
            defer { origin.stop() }

            let play = HeldPlay(url: root.appendingPathComponent(fixture), cache: cache, output: output)
            play.release()
            await play.thread.join()
            #expect(play.thread.failureIfAny == nil)
            #expect(play.remuxer.lateIndexLoadThread == nil, "\(fixture) \(validators) launched a late load")
            #expect(play.segmentPlanAvailable == nil)
            #expect(sidecars(cache).isEmpty, "\(fixture) \(validators) stored \(sidecars(cache))")
        }
    }

    @Test("The file changes between the producer's open and the late load's: nothing is stored or announced")
    func versionChangeBetweenOpensStoresNothing() async throws {
        let cache = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let bytes = try media("h264_aac_30s.mkv")
        let etag = LockedValue("\"v1\"")
        let origin = try ScriptedHTTPServer { ScriptedHTTPServer.ranged(bytes, for: $0, validators: ["ETag": etag.value]) }
        let root = try await origin.start()
        defer { origin.stop() }

        // The replacement lands after the producer opened v1, right before
        // the late load opens (it launches as segment 0's landing returns).
        let play = HeldPlay(url: root.appendingPathComponent("movie.mkv"), cache: cache, output: output,
                            atFirstSegment: { etag.value = "\"v2\"" })
        defer { play.release() }

        #expect(await until { play.isHeld })
        let loader = try #require(play.remuxer.lateIndexLoadThread, "the late load never launched — nothing was exercised")
        #expect(await loader.join(within: .seconds(20)))
        #expect(sidecars(cache).isEmpty, "a map of v2 was stored under v1's identity")
        #expect(play.segmentPlanAvailable == nil)

        etag.value = "\"v1\""
        play.release()
        await play.thread.join()
        #expect(play.thread.failureIfAny == nil)
    }

    @Test("A source with no declared index ends the late load at once, stores nothing, and leaves the producer alone")
    func indexlessSourceEndsQuietly() async throws {
        let cache = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        // MPEG-TS: no index in the container, so the nudge would be a scan.
        let bytes = try media("h264_ac3_30s.ts")
        let origin = try ScriptedHTTPServer { ScriptedHTTPServer.ranged(bytes, for: $0, validators: ["ETag": "\"v1\""]) }
        let root = try await origin.start()
        defer { origin.stop() }

        let play = HeldPlay(url: root.appendingPathComponent("movie.ts"), cache: cache, output: output)
        defer { play.release() }
        #expect(await until { play.isHeld })
        let loader = try #require(play.remuxer.lateIndexLoadThread, "the late load never launched — nothing was exercised")
        // Far inside its 60 s budget: the framing names no index, so it
        // never seeks at all.
        #expect(await loader.join(within: .seconds(10)))
        #expect(sidecars(cache).isEmpty)
        #expect(play.segmentPlanAvailable == nil)

        play.release()
        await play.thread.join()
        #expect(play.thread.failureIfAny == nil)
        let playlist = try String(contentsOf: output.appendingPathComponent("index.m3u8"), encoding: .utf8)
        #expect(playlist.contains("#EXT-X-ENDLIST"), "the producer did not finish its play")
    }

    @Test("stop() while the late load is parked in a starved read comes back at once, and so does the load")
    func stopReachesARunningLateLoad() async throws {
        let cache = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        // The producer's head request is served; the plan's tail request and
        // every request after it starve — the late load's open among them.
        let bytes = try media("h264_aac_30s.mkv")
        let served = LockedFlag()
        let origin = try ScriptedHTTPServer { request in
            if served.isSet { return .stall }
            served.set()
            return ScriptedHTTPServer.ranged(bytes, for: request, validators: ["ETag": "\"v1\""])
        }
        let root = try await origin.start()
        defer { origin.stop() }

        let session = try PrismCoreSession(
            url: root.appendingPathComponent("movie.mkv"), keyframeIndexCacheDirectory: cache, coordinatedHTTP: true
        )
        _ = try await session.start()
        #expect(await until { session.lateIndexLoadThread != nil })
        let loader = try #require(session.lateIndexLoadThread)
        #expect(!loader.isFinished, "the late load finished against a starved origin")

        let started = ContinuousClock.now
        await session.stop()
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(1), "stop() took \(elapsed) with a late load in flight")
        #expect(await loader.join(within: .seconds(1)), "the late load outlived stop()")
        // The cancelled producer's harvest persists its PARTIAL prefix (that
        // is the harvest's contract); a complete map could only be the late
        // load's, and it never read the index.
        for sidecar in sidecars(cache) {
            let entry = try JSONDecoder().decode(KeyframeIndexCache.Entry.self, from: Data(contentsOf: sidecar))
            #expect(!entry.complete)
        }
    }

    // MARK: - Helpers

    private static func sessionPlan(_ url: URL, cache: URL) async throws -> (SegmentPlanOrigin?, Int?) {
        let session = try PrismCoreSession(url: url, keyframeIndexCacheDirectory: cache, coordinatedHTTP: true)
        let checkpoints = try await session.startupCheckpoints()
        async let plan: (SegmentPlanOrigin?, Int?) = {
            for await mark in checkpoints {
                if case .segmentPlanReady(let origin, let segments) = mark.phase { return (origin, segments) }
            }
            return (nil, nil)
        }()
        _ = try await session.start()
        await session.stop()
        return await plan
    }

    private func until(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// One first play, driven the way a session drives it but held inside
/// segment 1's landing until `release()`: a remuxer with a short (or zero)
/// index budget over the coordinated reader, its events and plan origin
/// recorded.
private final class HeldPlay: @unchecked Sendable {
    let remuxer: HLSRemuxer
    private(set) var thread: ProducerThread!
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var held = false
    private var released = false
    private var origin: SegmentPlanOrigin?
    private var available: Int?
    private var launchedEarly: Bool?

    var isHeld: Bool { lock.withLock { held } }
    var planOrigin: SegmentPlanOrigin? { lock.withLock { origin } }
    var segmentPlanAvailable: Int? { lock.withLock { available } }
    /// Whether a late load existed when segment 0 landed. `nil` until then.
    var loaderLaunchedBeforeFirstSegment: Bool? { lock.withLock { launchedEarly } }

    init(url: URL, cache: URL, output: URL, indexLoadBudget: Duration = .zero,
         atFirstSegment: (@Sendable () -> Void)? = nil) {
        remuxer = HLSRemuxer(
            sourceURL: url, outputDirectory: output, demand: DemandCoordinator(),
            keyframeCacheDirectory: cache, indexLoadBudget: indexLoadBudget
        )
        remuxer.coordinatedHTTP = true
        let sink = PlaybackEventSink()
        let (events, continuation) = AsyncStream<PlaybackEvent>.makeStream()
        sink.replace(with: continuation)
        remuxer.events = sink
        Task { [self] in
            for await event in events {
                if case .segmentPlanAvailable(let segments) = event { lock.withLock { available = segments } }
            }
        }
        remuxer.onStartupPhase = { [self] phase in
            if case .segmentPlanReady(let planned, _) = phase { lock.withLock { origin = planned } }
        }
        remuxer.onSegmentLanded = { [self] index in
            if index == 0 {
                let early = remuxer.lateIndexLoadThread != nil
                lock.withLock { launchedEarly = early }
                atFirstSegment?()
            }
            if index == 1 {
                lock.withLock { held = true }
                _ = gate.wait(timeout: .now() + 60)
                lock.withLock { held = false }
            }
        }
        thread = ProducerThread(name: "prismcore.tests.held-play") { [remuxer] in try remuxer.run() }
    }

    /// Lets the producer go on. Idempotent, so a `defer` can always call it.
    func release() {
        let first = lock.withLock { defer { released = true }; return !released }
        if first { gate.signal() }
    }
}

private final class LockedValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) { stored = value }
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
