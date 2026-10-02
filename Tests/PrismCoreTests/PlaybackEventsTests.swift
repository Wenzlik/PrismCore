import Testing
import Foundation
@testable import PrismCore

/// A host input that parks its read once `parkAfterBytes` have been handed
/// over — a share or debrid link that stopped feeding mid-film without
/// failing. Conforming, so `stop()` can release it and join the producer.
private final class ParkingInput: CancellablePrismCoreInput, @unchecked Sendable {
    private let bytes: [UInt8]
    private let parkAfterBytes: Int
    private let lock = NSCondition()
    private var position = 0
    private var delivered = 0
    private var released = false
    private var parked = false

    struct Released: Error {}

    init(data: Data, parkAfterBytes: Int) {
        bytes = [UInt8](data)
        self.parkAfterBytes = parkAfterBytes
    }

    var length: Int64? { Int64(bytes.count) }
    var isParked: Bool { lock.withLock { parked } }

    func seek(to offset: Int64) throws {
        lock.withLock { position = Int(max(0, min(offset, Int64(bytes.count)))) }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if delivered >= parkAfterBytes {
            parked = true
            while !released { lock.wait() }
            parked = false
            throw Released()
        }
        // Small answers, like a real transport, so the park lands inside the
        // copy loop rather than inside one giant probe read.
        let count = min(buffer.count, 16 * 1024, bytes.count - position)
        guard count > 0 else { return 0 }
        bytes.withUnsafeBytes {
            buffer.baseAddress!.copyMemory(from: $0.baseAddress!.advanced(by: position), byteCount: count)
        }
        position += count
        delivered += count
        return count
    }

    func cancelInFlightOperation() {
        lock.withLock {
            released = true
            lock.broadcast()
        }
    }
}

@Suite("Playback events")
struct PlaybackEventsTests {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(
            Bundle.module.url(forResource: name, withExtension: "mkv", subdirectory: "Fixtures")
        ))
    }

    /// Everything the stream delivered until `stop()` finished it.
    private func drain(_ events: AsyncStream<PlaybackEvent>) -> Task<[PlaybackEvent], Never> {
        Task { var seen: [PlaybackEvent] = []; for await event in events { seen.append(event) }; return seen }
    }

    @Test("A 429 from the origin reaches the host, and so does the recovery")
    func originThrottledAndRecovered() async throws {
        let server = try RangeFixtureServer(media: fixture("h264_aac_30s"), refusals: 1, retryAfter: "1")
        let url = try await server.start()
        defer { server.stop() }
        let session = try PrismCoreSession(url: url, coordinatedHTTP: true)
        let seen = drain(await session.playbackEvents())
        do { _ = try await session.start() } catch { await session.stop(); throw error }
        await session.stop()

        let events = await seen.value
        let throttled = events.firstIndex(of: .originThrottled(retryAfter: .seconds(1)))
        let recovered = events.firstIndex(of: .originRecovered)
        #expect(throttled != nil, "no .originThrottled in \(events)")
        #expect(recovered != nil, "no .originRecovered in \(events)")
        if let throttled, let recovered { #expect(throttled < recovered) }
    }

    @Test("A request waiting on a producer parked inside a read reports the stall")
    func producerStalledWhileAServeWaits() async throws {
        let input = ParkingInput(data: try fixture("h264_aac_30s"), parkAfterBytes: 400_000)
        defer { input.cancelInFlightOperation() }
        let session = try PrismCoreSession(
            url: URL(fileURLWithPath: "/prismcore-tests-no-such-directory/stalled.mkv"),
            input: { input }
        )
        // Registered AFTER start(): the run-time feed has to work that way.
        let playlist = try await session.start()
        let events = await session.playbackEvents()
        let stalled = Task { () -> PlaybackEvent? in
            for await event in events { if case .producerStalled = event { return event } }
            return nil
        }

        let parkDeadline = ContinuousClock.now + .seconds(20)
        while !input.isParked, ContinuousClock.now < parkDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(input.isParked, "the producer never reached the parked read")

        // The last planned segment is far past where the producer stopped, so
        // this request goes pending on production that cannot happen.
        let (master, _) = try await URLSession.uncached.data(from: playlist)
        var variant = playlist
        if let uri = PrismCoreSession.playlistURIs(inMaster: String(decoding: master, as: UTF8.self)).last {
            variant = playlist.deletingLastPathComponent().appendingPathComponent(uri)
        }
        let (media, _) = try await URLSession.uncached.data(from: variant)
        let last = try #require(String(decoding: media, as: UTF8.self)
            .split(separator: "\n").last { $0.hasSuffix(".m4s") })
        let fetch = Task {
            _ = try? await URLSession.uncached.data(from: variant.deletingLastPathComponent().appendingPathComponent(String(last)))
        }

        let event = await withTimeout(.seconds(12)) { await stalled.value }
        fetch.cancel()
        await session.stop()

        guard case .producerStalled(let since, let lastPTS)?? = event else {
            Issue.record("no .producerStalled within 12 s: \(String(describing: event))")
            return
        }
        #expect(since >= .seconds(5))
        // The producer did read packets before it parked; the event says where.
        #expect((lastPTS ?? 0) > 0)
    }

    @Test("A serve the producer never satisfies reports its timeout")
    func serveTimedOut() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCore-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<4).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        ))
        let sink = PlaybackEventSink()
        let (stream, continuation) = AsyncStream<PlaybackEvent>.makeStream()
        sink.replace(with: continuation)
        var provider = PlanSegmentProvider(root: root, coordinator: coordinator)
        provider.events = sink
        // No producer behind this provider: the wait can only run out.
        provider.productionTimeout = .milliseconds(300)

        guard case .pending(let pending) = await provider.data(forPath: "seg00003.m4s") else {
            Issue.record("a missing planned segment must go pending")
            return
        }
        guard case .notFound = await pending.resolve() else {
            Issue.record("the timed-out serve must answer the miss")
            return
        }
        sink.replace(with: nil)
        var events: [PlaybackEvent] = []
        for await event in stream { events.append(event) }
        #expect(events == [.serveTimedOut(path: "seg00003.m4s")])
    }
}
