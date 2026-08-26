import Foundation

/// The meeting point of the demand-driven session (phase 5): the loopback's
/// provider reports which planned segment AVPlayer just asked for, and the
/// producer polls for anchor requests it should jump to.
///
/// Deliberately dumb and lock-based — both sides touch it from tight loops
/// (the producer once per packet, the provider once per request), so it holds
/// no async machinery of its own. The FILE SYSTEM stays the single source of
/// truth for "does segment N exist"; this type only carries intent.
///
/// The lock is an `NSCondition` because the producer has one state where it has
/// nothing to poll for: parked at EOF, waiting for a seek to ask for a segment
/// it skipped. It sleeps on this condition and a `requestProduction` wakes it —
/// no interval, so the first hop of a cold seek's latency is gone rather than
/// merely short (#44).
final class DemandCoordinator: @unchecked Sendable {

    private let lock = NSCondition()
    private var plan: SegmentPlan?
    private var requestedAnchor: Int?
    /// Set with `requestedAnchor` when the request must be honoured even at
    /// the index production is already on: a lazy rendition was just armed,
    /// and the muxers have to be rebuilt at a boundary for it to join with a
    /// whole first segment. Consumed together with the anchor.
    private var anchorIsForced = false
    /// The producer's current position: the segment it is producing now.
    /// `-1` until production starts.
    private var producingIndex = -1
    /// Segment indexes with an outstanding demand serve, refcounted — the
    /// variant and each rendition of the same index arrive as separate
    /// fetches. Retention consults this set so it never evicts a segment the
    /// provider is still waiting to read off disk (issue #43): production can
    /// run several segments past a just-reproduced one before the provider's
    /// poll notices the file, and "farthest from the producer" is then exactly
    /// the segment that was demanded.
    private var outstandingServes: [Int: Int] = [:]
    /// Root-relative paths production has declared it will never write — a
    /// rendition boundary that carried no audio. Consulted only on a MISS,
    /// so a later re-anchor that does produce the file is served normally.
    private var unproduciblePaths: Set<String> = []

    /// How far ahead of the producer a request may point and still be worth
    /// WAITING for instead of re-anchoring. Two segments ≈ 12 s of content —
    /// a real seek lands far outside it, AVPlayer's normal read-ahead inside.
    static let forwardWaitWindow = 2

    /// The newest segment index the provider has served or been asked for —
    /// the closest thing to a playhead the engine can see. `-1` until the
    /// first media fetch, which is also what lets startup produce freely.
    private var lastDemandedIndex = -1

    /// How far past the last demanded segment the producer may run before it
    /// parks. Ten segments ≈ 60 s of content: comfortably more than AVPlayer's
    /// forward read-ahead, comfortably less than the retention budget — which
    /// is the point. An uncapped producer sprints to EOF on a fast source, and
    /// retention's "farthest from the producer" then evicts the segments
    /// *nearest the playhead*: every ~20 s AVPlayer asks for a file that was
    /// just deleted, re-anchors the producer back, and playback hitches for
    /// the length of a demuxer seek. The cap keeps the producer trailing the
    /// playhead, which is the assumption retention was written against.
    static let producerLeadSegments = 10

    // MARK: - Producer side

    /// Publish the plan once the producer has built it. Until this, requests
    /// are served from disk only (no pending, no re-anchoring).
    func publish(plan: SegmentPlan) {
        lock.withLock { self.plan = plan }
    }

    func setProducing(index: Int) {
        lock.withLock { producingIndex = index }
    }

    /// The pending anchor request, consumed. The producer calls this once per
    /// packet; a nil answer is the hot path.
    func takeAnchorRequest() -> Int? {
        lock.withLock {
            defer { requestedAnchor = nil; anchorIsForced = false }
            return requestedAnchor
        }
    }

    /// The pending anchor request with its force flag, consumed — the copy
    /// loop's variant of `takeAnchorRequest`, which ignores a request for the
    /// index it is already producing unless `forced` says the muxers must be
    /// rebuilt anyway (a lazy rendition joining).
    func takeAnchorRequestDetailed() -> (index: Int, forced: Bool)? {
        lock.withLock {
            defer { requestedAnchor = nil; anchorIsForced = false }
            guard let requestedAnchor else { return nil }
            return (requestedAnchor, anchorIsForced)
        }
    }

    /// Park the calling thread until an anchor request is pending or
    /// `isCancelled` turns true. **Blocks a real thread** — only the producer's
    /// own thread may call it, never a cooperative-pool one.
    ///
    /// The timed wait is a backstop, not the mechanism: `requestProduction` and
    /// `wake` both signal, so an ordinary seek returns immediately. It exists so
    /// that no missed signal can strand a producer forever — the cost of being
    /// wrong is one wasted loop per second, and the cost of not having it is a
    /// session that never tears down.
    func waitForAnchorRequest(isCancelled: () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard requestedAnchor == nil, !isCancelled() else { return }
        lock.wait(until: Date(timeIntervalSinceNow: Self.parkBackstopSeconds))
    }

    /// Where a lazy rendition's arming re-anchors to when the fetch that
    /// armed it named no segment (an `init.mp4` fetch): the newest demanded
    /// index — the closest thing to the playhead, and where the rendition's
    /// own segment fetches are about to start — else the segment being
    /// produced; `nil` before production started. The rebuilt muxers restart
    /// that segment from its boundary, so the new rendition's first file is
    /// whole and the abandoned partial fragment was never on disk anyway.
    var armAnchorIndex: Int? {
        lock.withLock {
            if lastDemandedIndex >= 0 { return lastDemandedIndex }
            return producingIndex >= 0 ? producingIndex : nil
        }
    }

    /// Park the calling thread while the producer is more than
    /// `producerLeadSegments` ahead of the last demanded segment. Same
    /// contract as `waitForAnchorRequest`: **blocks a real thread**, producer's
    /// own thread only. Returns as soon as demand catches up, an anchor
    /// request lands (the copy loop's per-packet check will take it), or the
    /// session is cancelled; the timed wait is only the missed-signal backstop.
    ///
    /// A `lastDemandedIndex` of `-1` (nothing fetched yet) never parks:
    /// startup must produce the first segments before AVPlayer has anything
    /// to ask for. A demand *behind* the producer — a backward seek being
    /// replayed from disk — parks too: the files are already there, and the
    /// right move is to wait for the playhead to catch up, not to produce on.
    func parkWhileAhead(producing: Int, isCancelled: () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        while requestedAnchor == nil, !isCancelled(), lastDemandedIndex >= 0,
              producing > lastDemandedIndex + Self.producerLeadSegments {
            lock.wait(until: Date(timeIntervalSinceNow: Self.parkBackstopSeconds))
        }
    }

    /// Wake every parked producer without offering it an anchor — what
    /// cancellation uses to get its thread back promptly.
    ///
    /// Only meaningful **after** the state the park re-checks has changed
    /// (`HLSRemuxer.cancel()` sets its flag first, then calls this). A condition
    /// signal with nothing behind it can be lost to a producer that has not yet
    /// reached its wait, and would then be waited out by the backstop instead.
    func wake() {
        lock.withLock { lock.broadcast() }
    }

    private static let parkBackstopSeconds: TimeInterval = 1

    /// The indexes retention must not evict right now. Snapshotted once per
    /// `record` call on the producer's thread — a Set copy under the same lock
    /// both sides already take, so the cost sits with eviction, not the
    /// per-packet hot path.
    var demandProtectedIndexes: Set<Int> {
        lock.withLock { Set(outstandingServes.keys) }
    }

    /// Production skipped `path` for good (planned rendition slot with no
    /// audio). A fetch of it answers 404 at once instead of waiting out the
    /// pending window for a file that is not coming.
    func markUnproducible(path: String) {
        lock.withLock { _ = unproduciblePaths.insert(path) }
    }

    func isUnproducible(path: String) -> Bool {
        lock.withLock { unproduciblePaths.contains(path) }
    }

    /// Production DID write `path` after all (a re-anchor landed on audio the
    /// first pass missed). Cleared so that, once retention evicts the file,
    /// the next miss re-anchors instead of answering a stale 404.
    func clearUnproducible(path: String) {
        lock.withLock { _ = unproduciblePaths.remove(path) }
    }

    // MARK: - Provider side

    /// The plan, if published.
    var publishedPlan: SegmentPlan? {
        lock.withLock { plan }
    }

    /// A media-segment fetch arrived — hit or miss. The newest fetch is where
    /// AVPlayer's read-ahead front is, so it moves `lastDemandedIndex` and
    /// wakes a producer parked on its lead cap.
    func noteFetch(of index: Int) {
        lock.withLock {
            lastDemandedIndex = index
            lock.broadcast()
        }
    }

    /// A request for planned segment `index` arrived and its file doesn't
    /// exist. Decide whether the producer should jump: anything outside the
    /// forward-wait window re-anchors; inside it, the producer is about to
    /// make the segment anyway and a jump would only tear down its muxers.
    ///
    /// `force` skips the window AND the producer's "already there" check:
    /// used when a lazy rendition has just been armed, because its bridge
    /// can only join at a muxer rebuild, and the segment AVPlayer is asking
    /// for has to come out whole — even if production is on that very index.
    func requestProduction(of index: Int, force: Bool = false) {
        lock.withLock {
            let current = producingIndex
            if !force, current >= 0, index >= current, index <= current + Self.forwardWaitWindow {
                return
            }
            // Last request wins: AVPlayer's newest fetch is where the
            // playhead actually is.
            requestedAnchor = index
            anchorIsForced = force || anchorIsForced
            // Signalled under the lock, so a producer that is between its
            // `requestedAnchor == nil` check and its `wait` cannot miss this.
            lock.broadcast()
        }
    }

    /// A demand serve of segment `index` starts waiting for its file. Must be
    /// balanced with `endServing` — the protection lasts exactly as long as
    /// the wait, and an unbalanced begin would pin the segment (and its bytes)
    /// against the budget forever.
    func beginServing(index: Int) {
        lock.withLock { outstandingServes[index, default: 0] += 1 }
    }

    /// The serve of segment `index` finished — served, timed out, or the
    /// connection died; every exit counts, only the refcount matters.
    func endServing(index: Int) {
        lock.withLock {
            guard let count = outstandingServes[index] else { return }
            if count > 1 {
                outstandingServes[index] = count - 1
            } else {
                outstandingServes.removeValue(forKey: index)
            }
        }
    }
}
