import Testing
import Foundation
import Libavformat
import Libavcodec
import Libavutil
@testable import PrismCore

/// A planned session whose source fails mid-film re-opens it and re-anchors
/// instead of dying (`ProducerRecoveryPolicy`), and a session that does die
/// says so on the event stream (`producerFailed`).
///
/// Two kinds of source. `ScriptedHTTPServer` serves a fixture by ranges
/// through the coordinated reader, whose fills are 1 MiB blocks: the copy
/// loop's read of the second block is the one request that starts at exactly
/// 1 MiB, so the script breaks THAT request — after startup's open and its
/// tail read for the Cues, in the middle of production. That reader rides out
/// a refusing origin itself (eight tries, paced two seconds apart once the
/// origin has refused), so an outage it gives up on costs ~15 s of test time;
/// it is used where the transport's own classification is the point (a 503,
/// a dropped socket, a 404). Everything about the producer's side — the cap,
/// `stop()` mid-recovery, a lazy rendition across the seam, the sequential
/// shape — runs on a host `PrismCoreInput` that fails where it is told to,
/// in milliseconds.
@Suite("Producer recovery", .serialized)
struct ProducerRecoveryTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func waitUntil(_ timeout: Duration = .seconds(20), _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static let unavailable = ScriptedHTTPServer.Reply.respond(
        status: 503, headers: ["Retry-After": "0"], body: Data()
    )

    private static func isRecovered(_ event: PlaybackEvent) -> Bool {
        if case .producerRecovered = event { return true }
        return false
    }

    private static func isFailed(_ event: PlaybackEvent) -> Bool {
        if case .producerFailed = event { return true }
        return false
    }

    // MARK: - The policy

    @Test("Permanent never re-opens; the cap is three inside a minute, backing off 1, 2, 4 s")
    func policyCapAndBackoff() {
        var policy = ProducerRecoveryPolicy()
        let notFound = PrismCoreError.originUnreachable(status: 404, url: nil, underlying: nil)
        #expect(policy.nextAttempt(for: notFound, at: 0, reopening: false) == nil)

        let busy = PrismCoreError.originRateLimited(status: 503, retryAfter: nil, url: nil)
        #expect(policy.nextAttempt(for: busy, at: 0, reopening: false) == .init(number: 1, delay: .seconds(1)))
        #expect(policy.nextAttempt(for: busy, at: 5, reopening: true) == .init(number: 2, delay: .seconds(2)))
        #expect(policy.nextAttempt(for: busy, at: 10, reopening: true) == .init(number: 3, delay: .seconds(4)))
        #expect(policy.nextAttempt(for: busy, at: 20, reopening: false) == nil, "the cap is hard")
        // The window slides: the first attempt is a minute old at 60 s.
        #expect(policy.nextAttempt(for: busy, at: 60, reopening: false) == .init(number: 3, delay: .seconds(4)))
    }

    @Test("Unknown re-opens, but not to fail on the same bytes again")
    func policyUnknownNeedsProgress() {
        var policy = ProducerRecoveryPolicy()
        let unknown = PrismCoreError.ffmpeg(code: -5, operation: "av_read_frame", message: "I/O error")
        #expect(policy.nextAttempt(for: unknown, at: 0, reopening: false) != nil)
        // A re-open that fails keeps trying: the source is still unreachable.
        #expect(policy.nextAttempt(for: unknown, at: 1, reopening: true) != nil)
        policy.noteRecovered()
        // Re-opened fine, and the read failed again before a segment landed.
        #expect(policy.nextAttempt(for: unknown, at: 2, reopening: false) == nil)

        var progressed = ProducerRecoveryPolicy()
        _ = progressed.nextAttempt(for: unknown, at: 0, reopening: false)
        progressed.noteRecovered()
        progressed.noteProgress()
        #expect(progressed.nextAttempt(for: unknown, at: 2, reopening: false) != nil)
    }

    // MARK: - Over HTTP

    @Test("A mid-film outage is re-opened and re-anchored; every segment verifies across the seam")
    func outageIsRecovered() async throws {
        let media = try Data(contentsOf: try fixture("h264_aac_30s.mkv"))
        // 503s, then closed sockets — more than the reader's eight tries, so
        // one fill gives up; whatever is left is ridden out after the re-open.
        let script = OriginScript(failures: Array(repeating: Self.unavailable, count: 6)
            + Array(repeating: .drop, count: 6))
        let server = try ScriptedHTTPServer { request in
            script.reply(to: request) ?? ScriptedHTTPServer.ranged(media, for: request)
        }
        let root = try await server.start()
        defer { server.stop() }

        let session = try PrismCoreSession(url: root.appendingPathComponent("film.mkv"), coordinatedHTTP: true)
        let events = EventLog(await session.playbackEvents())
        let playlist = try await session.start()

        await waitUntil(.seconds(60)) { events.contains(where: Self.isRecovered) }
        #expect(script.failuresServed > 0, "the outage was never reached")
        let recovered = events.snapshot.compactMap { event -> (Int, PrismCoreError)? in
            if case .producerRecovered(let attempt, let cause) = event { return (attempt, cause) }
            return nil
        }
        #expect(recovered.count == 1, "\(events.snapshot)")
        if let (attempt, cause) = recovered.first {
            #expect(attempt == 1)
            #expect(cause.retryability == .retryable, "\(cause)")
        }
        #expect(script.reopensAfterFirstFailure >= 1)

        try await expectEverySegmentVerifies(playlist, videoFrames: 720)
        #expect(await session.remuxFailure == nil)
        await session.stop()
        #expect(!events.contains(where: Self.isFailed))
    }

    @Test("A permanent failure is not re-opened, and is pushed once as producerFailed")
    func permanentFailureIsReported() async throws {
        let media = try Data(contentsOf: try fixture("h264_aac_30s.mkv"))
        let script = OriginScript(failures: [], forever: .respond(status: 404, body: Data()))
        let server = try ScriptedHTTPServer { request in
            script.reply(to: request) ?? ScriptedHTTPServer.ranged(media, for: request)
        }
        let root = try await server.start()
        defer { server.stop() }

        let session = try PrismCoreSession(url: root.appendingPathComponent("film.mkv"), coordinatedHTTP: true)
        let events = EventLog(await session.playbackEvents())
        _ = try await session.start()

        await waitUntil { events.contains(where: Self.isFailed) }
        let failures = events.snapshot.compactMap { event -> PrismCoreError? in
            if case .producerFailed(let failure) = event { return failure }
            return nil
        }
        #expect(failures.count == 1, "\(events.snapshot)")
        guard case .originUnreachable(status: 404, _, _)? = failures.first else {
            Issue.record("expected .producerFailed(.originUnreachable(404)), got \(failures)")
            await session.stop()
            return
        }
        #expect(!events.contains(where: Self.isRecovered))
        #expect(script.reopensAfterFirstFailure == 0, "a 404 was re-opened")
        guard case .originUnreachable(status: 404, _, _)? = await session.remuxFailure else {
            Issue.record("remuxFailure disagrees with the event: \(String(describing: await session.remuxFailure))")
            await session.stop()
            return
        }
        await session.stop()
    }

    // MARK: - A host input

    @Test("A host input is taken again from its factory, and an unclassified failure heals")
    func hostInputIsReopened() async throws {
        let factory = FlakyInputFactory(
            media: try Data(contentsOf: try fixture("h264_aac_30s.mkv")),
            behaviours: [.fail(at: 900_000)]
        )
        let session = try PrismCoreSession(url: URL(string: "prismcore-test://flaky.mkv")!, input: factory.make)
        let events = EventLog(await session.playbackEvents())
        let playlist = try await session.start()
        await waitUntil { events.contains(where: Self.isRecovered) }
        #expect(factory.made == 2, "the factory is called once per open, the re-open included")
        // The broken instance was let go before the next was asked for: a
        // host input that frees a connection slot in `deinit` needs that.
        #expect(factory.liveWhenMade == [0, 0], "\(factory.liveWhenMade)")
        guard case .producerRecovered(1, let cause)? = events.snapshot.first(where: Self.isRecovered) else {
            Issue.record("no recovery: \(events.snapshot)")
            await session.stop()
            return
        }
        // A host's own error is unclassifiable to the engine — and healed.
        #expect(cause.retryability == .unknown, "\(cause)")
        try await expectEverySegmentVerifies(playlist, videoFrames: 720)
        // Counted across both contexts, never reset by the re-open: the
        // whole file went through, plus the stretch re-read after it.
        #expect(session.sourceBytesRead > 1_000_000, "\(session.sourceBytesRead)")
        await session.stop()
    }

    @Test("A recovery that healed into the last segment still counts it as progress")
    func lastSegmentCountsAsProgress() async throws {
        // Keyframes every 2 s, ~42 KB/s. The first instance is held past
        // startup and before the middle (~9 s), so nothing behind the last
        // segment is produced; the second fails inside the middle one
        // (~15.5 s), which only a seek back after EOF reads.
        let factory = FlakyInputFactory(
            media: try Data(contentsOf: try fixture("h264_aac_30s.mkv")),
            behaviours: [.gate(at: 400_000), .fail(at: 650_000)]
        )
        let session = try PrismCoreSession(url: URL(string: "prismcore-test://tail.mkv")!, input: factory.make)
        let events = EventLog(await session.playbackEvents())
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        await waitUntil { factory.gated }
        #expect(factory.gated, "production never reached the gate")

        let master = String(decoding: try await URLSession.uncached.data(from: playlist).0, as: UTF8.self)
        let variantPath = try #require(master.split(separator: "\n").first { $0.hasSuffix(".m3u8") })
        let variant = URL(string: String(variantPath), relativeTo: playlist)!.absoluteURL
        let segments = String(decoding: try await URLSession.uncached.data(from: variant).0, as: UTF8.self)
            .split(separator: "\n").filter { $0.hasSuffix(".m4s") }.map(String.init)
        let base = variant.deletingLastPathComponent()

        // Jump to the end while the read is held, then let it fail: the
        // re-open re-anchors there and the tail lands at EOF — the one cut
        // that is not `emitSegment`'s.
        let lastURL = base.appendingPathComponent(try #require(segments.last))
        async let tail = URLSession.uncached.data(from: lastURL)
        try await Task.sleep(for: .milliseconds(200))
        factory.openGate()
        #expect(try await tail.0.range(of: Data("mdat".utf8)) != nil)
        await waitUntil { events.contains(where: Self.isRecovered) }
        #expect(events.snapshot.filter(Self.isRecovered).count == 1, "\(events.snapshot)")

        // Back into the skipped middle: fails again before its first cut.
        // The tail landed in between, so this is a new failure, not the
        // same bytes again — re-opened, not given up on.
        let (media, _) = try await URLSession.uncached.data(
            from: base.appendingPathComponent(segments[segments.count / 2]))
        #expect(media.range(of: Data("mdat".utf8)) != nil)
        await waitUntil { events.snapshot.filter(Self.isRecovered).count >= 2 || events.contains(where: Self.isFailed) }
        #expect(events.snapshot.filter(Self.isRecovered).count == 2, "\(events.snapshot)")
        #expect(!events.contains(where: Self.isFailed), "\(events.snapshot)")
        #expect(factory.made == 3)
    }

    @Test("Bytes that fail on every open are given up on after one re-open")
    func deterministicFailureIsNotRetried() async throws {
        let factory = FlakyInputFactory(
            media: try Data(contentsOf: try fixture("h264_aac_30s.mkv")),
            behaviours: [], otherwise: .fail(at: 900_000)
        )
        let session = try PrismCoreSession(url: URL(string: "prismcore-test://damaged.mkv")!, input: factory.make)
        let events = EventLog(await session.playbackEvents())
        _ = try await session.start()
        await waitUntil { events.contains(where: Self.isFailed) }
        let snapshot = events.snapshot
        #expect(snapshot.filter(Self.isRecovered).count == 1, "\(snapshot)")
        #expect(snapshot.filter(Self.isFailed).count == 1, "\(snapshot)")
        #expect(factory.made == 2)
        await session.stop()
    }

    @Test("A source that keeps failing further on is re-opened three times, then reported")
    func capEndsTheSession() async throws {
        // Each instance fails a segment or so later than the last, so every
        // recovery makes progress and only the cap can end it. ~42 KB/s of
        // media: these marks fall inside segments 1, 2, 3 and 4.
        let factory = FlakyInputFactory(
            media: try Data(contentsOf: try fixture("h264_aac_30s.mkv")),
            behaviours: [.fail(at: 300_000), .fail(at: 550_000), .fail(at: 800_000), .fail(at: 1_050_000)]
        )
        let session = try PrismCoreSession(url: URL(string: "prismcore-test://flapping.mkv")!, input: factory.make)
        let events = EventLog(await session.playbackEvents())
        _ = try await session.start()
        // 1 + 2 + 4 s of backoff.
        await waitUntil { events.contains(where: Self.isFailed) }
        let snapshot = events.snapshot
        let attempts = snapshot.compactMap { event -> Int? in
            if case .producerRecovered(let attempt, _) = event { return attempt }
            return nil
        }
        #expect(attempts == [1, 2, 3], "\(snapshot)")
        #expect(snapshot.filter(Self.isFailed).count == 1, "\(snapshot)")
        #expect(factory.made == 1 + ProducerRecoveryPolicy.maxAttempts)
        #expect(await session.remuxFailure != nil)
        await session.stop()
    }

    @Test("A sequential session still ends on a read failure, and now says so")
    func sequentialIsUnchangedButReported() async throws {
        // Written as a live stream (`-live 1`): no Duration and no Cues, so
        // there is nothing to plan on — the sequential (EVENT) shape. 12 s,
        // ~36 KB/s: the gate sits about seven seconds in.
        let factory = FlakyInputFactory(
            media: try Data(contentsOf: try fixture("h264_aac_live_12s.mkv")),
            behaviours: [.gate(at: 250_000)]
        )
        let session = try PrismCoreSession(url: URL(string: "prismcore-test://sequential.mkv")!, input: factory.make)
        let events = EventLog(await session.playbackEvents())
        let playlist = try await session.start()
        // Held at the mark until playback is up, so the failure is a
        // mid-session one rather than a startup that never finished.
        await waitUntil { factory.gated }
        factory.openGate()
        #expect(playlist.lastPathComponent == "index.m3u8" || playlist.lastPathComponent == "master.m3u8")
        await waitUntil { events.contains(where: Self.isFailed) }
        #expect(events.snapshot.filter(Self.isFailed).count == 1, "\(events.snapshot)")
        #expect(!events.contains(where: Self.isRecovered))
        #expect(factory.made == 1, "a sequential session has nothing to re-anchor on")
        let playlistText = try String(contentsOf: (await session.workDirectory).appendingPathComponent("index.m3u8"), encoding: .utf8)
        #expect(playlistText.contains("#EXT-X-PLAYLIST-TYPE:EVENT"), "this fixture was meant to be sequential")
        #expect(!playlistText.contains("#EXT-X-ENDLIST"), "a failed sequential remux must not claim it finished")
        await session.stop()
    }

    // MARK: - stop() is never held by a recovery

    @Test("stop() during the backoff returns at once")
    func stopDuringBackoff() async throws {
        let factory = FlakyInputFactory(
            media: try Data(contentsOf: try fixture("h264_aac_30s.mkv")),
            behaviours: [.fail(at: 900_000)]
        )
        let session = try PrismCoreSession(url: URL(string: "prismcore-test://flaky.mkv")!, input: factory.make)
        _ = try await session.start()
        await waitUntil { factory.failures >= 1 }
        // The first backoff is a second long; land well inside it.
        try await Task.sleep(for: .milliseconds(100))
        let began = ContinuousClock.now
        await session.stop()
        let took = ContinuousClock.now - began
        #expect(factory.made == 1, "the stop was meant to land in the backoff")
        #expect(took < .milliseconds(500), "stop() took \(took) inside a 1 s backoff")
    }

    @Test("stop() during a re-open whose read never returns is not held by it")
    func stopDuringReopen() async throws {
        // The re-open's first read parks until it is cancelled — only the
        // guard published BEFORE the open can reach it. Without that, the
        // stop bounces and waits out the producer grace (2 s).
        let factory = FlakyInputFactory(
            media: try Data(contentsOf: try fixture("h264_aac_30s.mkv")),
            behaviours: [.fail(at: 900_000), .park]
        )
        let session = try PrismCoreSession(url: URL(string: "prismcore-test://flaky.mkv")!, input: factory.make)
        _ = try await session.start()
        await waitUntil { factory.parked }
        #expect(factory.parked, "the re-open never started")
        let began = ContinuousClock.now
        await session.stop()
        let took = ContinuousClock.now - began
        #expect(took < .milliseconds(500), "stop() took \(took) inside a parked re-open")
    }

    // MARK: - Helpers

    private func expectEverySegmentVerifies(_ playlist: URL, videoFrames: Int?) async throws {
        let report = try await SegmentVerifier.verify(playlist: playlist)
        #expect(!report.hasErrors, "findings: \(report.findings)")
        let video = try #require(report.playlists.first { $0.videoFrames > 0 })
        // Every picture exactly once across segments: nothing lost at the
        // seam, nothing produced twice.
        if let videoFrames { #expect(video.videoFrames == videoFrames) }
        #expect(report.playlists.contains { $0.audioFrames > 0 })

        // And each segment sits where the playlist put it — the tfdt of a
        // re-anchored muxer is absolute, so its first picture is at the sum
        // of the `#EXTINF`s before it.
        let variantURL = URL(string: video.uri, relativeTo: playlist)!.absoluteURL
        let (text, _) = try await URLSession.uncached.data(from: variantURL)
        let durations = String(decoding: text, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") }
        let directory = variantURL.deletingLastPathComponent()
        let (initData, _) = try await URLSession.uncached.data(from: directory.appendingPathComponent("init.mp4"))
        var expectedStart = 0.0
        for (index, duration) in durations.enumerated() {
            let (segment, _) = try await URLSession.uncached.data(
                from: directory.appendingPathComponent(String(format: "seg%05d.m4s", index)))
            let first = try Self.firstPacketSeconds(initSegment: initData, media: segment)
            #expect(abs(first - expectedStart) < 0.05, "segment \(index) opens at \(first) s, planned \(expectedStart) s")
            expectedStart += duration
        }
    }

    /// Opens init + one fragment as one file and returns the first packet's
    /// presentation time — the fragment's `tfdt`, as a demuxer reads it.
    static func firstPacketSeconds(initSegment: Data, media: Data) throws -> Double {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreRecovery-\(UUID().uuidString).mp4")
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
}

/// What the scripted origin does with the copy loop's second block, and with
/// the re-opens that follow it.
final class OriginScript: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [ScriptedHTTPServer.Reply]
    private let forever: ScriptedHTTPServer.Reply?
    private var served = 0
    private var reopens = 0

    init(failures: [ScriptedHTTPServer.Reply], forever: ScriptedHTTPServer.Reply? = nil) {
        self.failures = failures
        self.forever = forever
    }

    var failuresServed: Int { lock.withLock { served } }
    /// Opens (a request for byte 0) after the first scripted failure.
    var reopensAfterFirstFailure: Int { lock.withLock { reopens } }

    /// `nil` = answer normally.
    func reply(to request: ScriptedHTTPServer.Request) -> ScriptedHTTPServer.Reply? {
        guard let range = request.headers["range"], range.hasPrefix("bytes="),
              let start = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? "")
        else { return nil }
        return lock.withLock {
            if start == 0, served > 0 { reopens += 1 }
            guard start == HTTPRangeInput.blockSize else { return nil }
            if !failures.isEmpty {
                served += 1
                return failures.removeFirst()
            }
            if let forever {
                served += 1
                return forever
            }
            return nil
        }
    }
}

/// Collects a session's events from the moment it is built.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PlaybackEvent] = []

    init(_ stream: AsyncStream<PlaybackEvent>) {
        Task { [self] in
            for await event in stream { lock.withLock { events.append(event) } }
        }
    }

    var snapshot: [PlaybackEvent] { lock.withLock { events } }

    func contains(where predicate: (PlaybackEvent) -> Bool) -> Bool {
        snapshot.contains(where: predicate)
    }
}

/// Hands out inputs over `media`, instance `n` behaving as `behaviours[n]`
/// (`otherwise` past the end) — a share that went away, bytes that never
/// read, a re-open that never answers.
final class FlakyInputFactory: @unchecked Sendable {
    enum Behaviour {
        case healthy
        /// The forward read that crosses `byte` throws.
        case fail(at: Int)
        /// The read that crosses `byte` waits for `openGate()`, then throws.
        case gate(at: Int)
        /// The first read parks until the engine cancels it.
        case park
    }

    private let condition = NSCondition()
    private let media: [UInt8]
    private let behaviours: [Behaviour]
    private let otherwise: Behaviour
    private var count = 0
    private var live = 0
    private var liveAtMake: [Int] = []
    private var failed = 0
    private var isGated = false
    private var gateOpen = false
    private var isParked = false

    init(media: Data, behaviours: [Behaviour], otherwise: Behaviour = .healthy) {
        self.media = [UInt8](media)
        self.behaviours = behaviours
        self.otherwise = otherwise
    }

    var made: Int { condition.withLock { count } }
    /// How many earlier instances were still alive at each `make`.
    var liveWhenMade: [Int] { condition.withLock { liveAtMake } }
    var failures: Int { condition.withLock { failed } }
    var gated: Bool { condition.withLock { isGated } }
    var parked: Bool { condition.withLock { isParked } }

    func openGate() {
        condition.withLock {
            gateOpen = true
            condition.broadcast()
        }
    }

    var make: PrismCoreInputFactory {
        { [self] in
            let ordinal = condition.withLock {
                liveAtMake.append(live)
                live += 1
                defer { count += 1 }
                return count
            }
            return FlakyInput(factory: self, behaviour: ordinal < behaviours.count ? behaviours[ordinal] : otherwise)
        }
    }

    fileprivate func noteFailure() { condition.withLock { failed += 1 } }

    fileprivate func noteReleased() { condition.withLock { live -= 1 } }

    fileprivate func waitAtGate() {
        condition.withLock {
            isGated = true
            while !gateOpen { condition.wait() }
            failed += 1
        }
    }

    fileprivate func park(until released: () -> Bool) {
        condition.withLock {
            isParked = true
            while !released() { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01)) }
        }
    }

    fileprivate var bytes: [UInt8] { media }
}

private final class FlakyInput: CancellablePrismCoreInput, @unchecked Sendable {
    struct ShareWentAway: Error {}
    private let factory: FlakyInputFactory
    private let behaviour: FlakyInputFactory.Behaviour
    private let media: [UInt8]
    private var position = 0
    private let lock = NSLock()
    private var cancelled = false

    init(factory: FlakyInputFactory, behaviour: FlakyInputFactory.Behaviour) {
        self.factory = factory
        self.behaviour = behaviour
        self.media = factory.bytes
    }

    deinit { factory.noteReleased() }

    var length: Int64? { Int64(media.count) }

    func seek(to offset: Int64) throws { position = Int(offset) }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = min(buffer.count, 64 * 1024, media.count - position)
        switch behaviour {
        case .healthy:
            break
        case .fail(let byte):
            // Only the copy loop's forward read crosses the mark — the Cues
            // at the tail are reached by a seek straight past it.
            if position < byte, position + count > byte {
                factory.noteFailure()
                throw ShareWentAway()
            }
        case .gate(let byte):
            if position < byte, position + count > byte {
                factory.waitAtGate()
                throw ShareWentAway()
            }
        case .park:
            factory.park { lock.withLock { cancelled } }
            throw ShareWentAway()
        }
        guard count > 0 else { return 0 }
        media.withUnsafeBytes {
            buffer.baseAddress!.copyMemory(from: $0.baseAddress!.advanced(by: position), byteCount: count)
        }
        position += count
        return count
    }

    func cancelInFlightOperation() {
        lock.withLock { cancelled = true }
    }
}
