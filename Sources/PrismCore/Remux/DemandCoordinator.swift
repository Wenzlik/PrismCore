import Foundation

/// The meeting point of the demand-driven session (phase 5): the loopback's
/// provider reports which planned segment AVPlayer just asked for, and the
/// producer polls for anchor requests it should jump to.
///
/// Deliberately dumb and lock-based — both sides touch it from tight loops
/// (the producer once per packet, the provider once per request), so it holds
/// no async machinery of its own. The FILE SYSTEM stays the single source of
/// truth for "does segment N exist"; this type only carries intent.
final class DemandCoordinator: @unchecked Sendable {

    private let lock = NSLock()
    private var plan: SegmentPlan?
    private var requestedAnchor: Int?
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

    /// How far ahead of the producer a request may point and still be worth
    /// WAITING for instead of re-anchoring. Two segments ≈ 12 s of content —
    /// a real seek lands far outside it, AVPlayer's normal read-ahead inside.
    static let forwardWaitWindow = 2

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
            defer { requestedAnchor = nil }
            return requestedAnchor
        }
    }

    /// The indexes retention must not evict right now. Snapshotted once per
    /// `record` call on the producer's thread — a Set copy under the same lock
    /// both sides already take, so the cost sits with eviction, not the
    /// per-packet hot path.
    var demandProtectedIndexes: Set<Int> {
        lock.withLock { Set(outstandingServes.keys) }
    }

    // MARK: - Provider side

    /// The plan, if published.
    var publishedPlan: SegmentPlan? {
        lock.withLock { plan }
    }

    /// A request for planned segment `index` arrived and its file doesn't
    /// exist. Decide whether the producer should jump: anything outside the
    /// forward-wait window re-anchors; inside it, the producer is about to
    /// make the segment anyway and a jump would only tear down its muxers.
    func requestProduction(of index: Int) {
        lock.withLock {
            let current = producingIndex
            if current >= 0, index >= current, index <= current + Self.forwardWaitWindow {
                return
            }
            // Last request wins: AVPlayer's newest fetch is where the
            // playhead actually is.
            requestedAnchor = index
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
