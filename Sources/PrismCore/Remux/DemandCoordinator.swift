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
}
