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
// Safety: every mutable field is touched only while holding `lock` (an NSCondition).
final class DemandCoordinator: @unchecked Sendable {

    private let lock = NSCondition()
    private var plan: SegmentPlan?
    private var requestedAnchor: Int?
    /// Set with `requestedAnchor` when the request must be honoured even at
    /// the index production is already on: a lazy rendition was just armed,
    /// and the muxers have to be rebuilt at a boundary for it to join with a
    /// whole first segment. Consumed together with the anchor.
    private var anchorIsForced = false
    /// Whether `requestedAnchor` is a join itself — set by a forced request,
    /// cleared by any unforced one that replaces it. Separate from
    /// `anchorIsForced`, which stays sticky (a seek over a pending join still
    /// needs the rebuild): only a join may be held against read-ahead or
    /// lowered by `lowerForcedJoin`. A seek that inherited the force used to
    /// count as a join, and the stale join's waits pulled it back down to
    /// segments the player had left.
    private var anchorIsJoin = false
    /// When the current `requestedAnchor` was made, for the scrub debounce.
    private var requestedAt: ContinuousClock.Instant?
    /// A re-anchor the producer took whose first segment has not landed yet
    /// (cleared by `setProducing` moving on). While one is in flight, a
    /// request younger than `anchorDebounce` is held back: a scrub bar
    /// drags out a burst of fetches, and honouring each one tore the muxers
    /// down several times to produce nothing. The newest still wins — it is
    /// what the burst settles on.
    private var reanchorInFlight: Int?
    /// Whether `reanchorInFlight` is a join (`anchorIsJoin` when taken).
    private var inFlightIsJoin = false
    static let anchorDebounce: Duration = .milliseconds(150)
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
    /// AVPlayer's normal read-ahead lands inside it. A request inside the
    /// window still re-anchors when it is DISCONTINUOUS with the fetch
    /// history (see `requestProduction`): a short forward seek used to wait
    /// out two whole segments of serial production because it happened to
    /// be numerically close.
    static let forwardWaitWindow = 2

    /// The newest segment index the provider has served or been asked for —
    /// the closest thing to a playhead the engine can see. `-1` until the
    /// first media fetch, which is also what lets startup produce freely.
    private var lastDemandedIndex = -1
    /// The one before it — what a new request is judged continuous against.
    /// `noteFetch` runs before the miss handling, so by the time a request
    /// is made `lastDemandedIndex` already IS the request.
    private var previousDemandedIndex = -1

    /// The read front per fetched directory — the variant (`""`) and each
    /// `audioN/` — with when it last moved, and the fetch before it. AVPlayer
    /// reads the variant and its audio rendition as separate fronts that can
    /// drift a segment or two apart; judging continuity and the lead against
    /// one shared "newest fetch" made a rendition's next segment look like a
    /// seek, and let retention evict what the slower front still needed.
    private var fronts: [String: (index: Int, at: ContinuousClock.Instant)] = [:]
    private var previousFronts: [String: Int] = [:]
    /// A front not fetched for this long is a rendition the player left (or
    /// a paused player): it no longer holds the producer or retention back.
    static let frontStaleness: Duration = .seconds(15)
    /// Segments retention keeps behind the lowest read front: a refetch after
    /// a rebuffer, an item handover or a short skip back is served from disk
    /// instead of throwing the producer back (#3795 in Aether).
    static let keepBehindFront = 15
    /// Segments retention keeps past the highest front and the producer.
    static let keepAheadOfFront = 4

    /// Diagnostics (#3795 in Aether): how often production was moved, how
    /// often a media segment was not on disk when fetched, and how many
    /// evicted segments sat at or after the read front — the one number that
    /// says retention, not production speed, starved the player.
    var reanchorCount: Int { lock.withLock { reanchors } }
    private var reanchors = 0
    private var misses = 0
    private var evictedAheadOfFront = 0
    var segmentMissCount: Int { lock.withLock { misses } }
    var evictionsAheadOfReadFrontCount: Int { lock.withLock { evictedAheadOfFront } }

    /// How far past the last demanded segment the producer may run before it
    /// parks, in seconds of content. Thirty seconds: comfortably more than
    /// AVPlayer's forward read-ahead, comfortably less than the retention
    /// budget — which is the point. An uncapped producer sprints to EOF on a
    /// fast source, and retention's "farthest from the producer" then evicts
    /// the segments *nearest the playhead*: every ~20 s AVPlayer asks for a
    /// file that was just deleted, re-anchors the producer back, and playback
    /// hitches for the length of a demuxer seek. The cap keeps the producer
    /// trailing the playhead, which is the assumption retention was written
    /// against. Seconds rather than a segment count (it was ten segments)
    /// because segments vary — a 2 s head, keyframe-stretched entries — and
    /// the buffer AVPlayer cares about is time.
    static let producerLeadSeconds = 30.0
    /// The lead a source on local disk gets instead (#3795 in Aether): a
    /// minute. Reading a file never stalls on a link, so the only thing that
    /// can drain AVPlayer's pool is production itself running slower than
    /// real time for a while (an audio transcode, a hot iPad). The produced
    /// segments sit on disk, not in memory, so the cost is retention budget,
    /// which `leadSeconds(isFileSource:budgetBytes:bitsPerSecond:)` respects.
    /// Deliberately conservative until it is measured on a device.
    static let fileSourceLeadSeconds = 60.0

    /// The lead the producer parks on — `producerLeadSeconds` unless the
    /// remuxer set it for a file source before production started.
    var leadCapSeconds: Double {
        get { lock.withLock { leadCap } }
        set { lock.withLock { leadCap = newValue } }
    }
    private var leadCap = DemandCoordinator.producerLeadSeconds

    /// The lead for a source: thirty seconds for anything remote (unchanged);
    /// for a file, `fileSourceLeadSeconds` held to HALF the retention budget
    /// at the source's average rate, never under the network lead. Half,
    /// because retention keeps everything from behind the read front up to
    /// the producer (`retentionKeepRange`): the other half is room for the
    /// segments kept behind the front, instead of the budget being spent on
    /// the lead alone. No
    /// budget (`nil`) keeps everything, so the full lead; an unknown rate
    /// can't be bounded, so the network lead.
    static func leadSeconds(isFileSource: Bool, budgetBytes: Int?, bitsPerSecond: Int?) -> Double {
        guard isFileSource else { return producerLeadSeconds }
        guard let budgetBytes else { return fileSourceLeadSeconds }
        guard let bitsPerSecond, bitsPerSecond > 0 else { return producerLeadSeconds }
        let affordable = Double(budgetBytes) / 2 / (Double(bitsPerSecond) / 8)
        return min(fileSourceLeadSeconds, max(producerLeadSeconds, affordable))
    }
    /// The sequential shape has no plan to read durations from; its
    /// `segmentSeconds` stands in (set by the producer).
    var nominalSegmentSeconds = 6.0

    // MARK: - Producer side

    /// Publish the plan once the producer has built it. Until this, requests
    /// are served from disk only (no pending, no re-anchoring).
    func publish(plan: SegmentPlan) {
        lock.withLock { self.plan = plan }
    }

    func setProducing(index: Int) {
        lock.withLock {
            // Moving past the re-anchored index means its first segment
            // landed: the debounce no longer holds requests back.
            if let inFlight = reanchorInFlight, index != inFlight { reanchorInFlight = nil; inFlightIsJoin = false }
            producingIndex = index
        }
    }

    /// The pending anchor request, consumed. The producer calls this once per
    /// packet; a nil answer is the hot path.
    func takeAnchorRequest() -> Int? {
        takeAnchorRequestDetailed()?.index
    }

    /// Whether the pending request may be handed out now: always, unless a
    /// re-anchor is in flight (its first segment not landed) and this request
    /// is younger than the debounce — the shape of a scrub burst, where the
    /// next request is about to replace this one anyway. A forced request is
    /// never held (a lazy rendition joining has nothing to coalesce with).
    private func anchorIsDue(now: ContinuousClock.Instant) -> Bool {
        guard let requestedAt, reanchorInFlight != nil, !anchorIsForced else { return true }
        return now - requestedAt >= Self.anchorDebounce
    }

    /// The pending anchor request with its force flag, consumed — the copy
    /// loop's variant of `takeAnchorRequest`, which ignores a request for the
    /// index it is already producing unless `forced` says the muxers must be
    /// rebuilt anyway (a lazy rendition joining).
    func takeAnchorRequestDetailed() -> (index: Int, forced: Bool)? {
        lock.withLock {
            guard let anchor = requestedAnchor, anchorIsDue(now: .now) else { return nil }
            defer { requestedAnchor = nil; anchorIsForced = false; anchorIsJoin = false; requestedAt = nil }
            reanchorInFlight = anchor
            inFlightIsJoin = anchorIsJoin
            reanchors += 1
            return (index: anchor, forced: anchorIsForced)
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
        guard requestedAnchor == nil || !anchorIsDue(now: .now), !isCancelled() else { return }
        // A held-back request (debounce) is re-checked when it comes due, not
        // after the whole backstop.
        let wait = requestedAnchor == nil ? Self.parkBackstopSeconds : Self.anchorDebounce / .seconds(1)
        lock.wait(until: Date(timeIntervalSinceNow: wait))
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
    /// `leadCapSeconds` ahead of the lowest live read front (else the last
    /// demanded segment). Same
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
              leadSeconds(from: activeFrontBounds(now: .now)?.lowest ?? lastDemandedIndex, to: producing) > leadCap {
            lock.wait(until: Date(timeIntervalSinceNow: Self.parkBackstopSeconds))
        }
    }

    /// Content seconds between the start of segment `from` and the start of
    /// segment `to` — from the plan when there is one, else the nominal
    /// stride. Under the lock.
    private func leadSeconds(from: Int, to: Int) -> Double {
        guard to > from else { return 0 }
        if let plan, plan.entries.indices.contains(from), plan.timeBaseDen > 0 {
            let toPTS = plan.entries.indices.contains(to)
                ? plan.entries[to].startPTS
                : plan.entries[plan.entries.count - 1].startPTS
            return Double(toPTS - plan.entries[from].startPTS) * Double(plan.timeBaseNum) / Double(plan.timeBaseDen)
        }
        return Double(to - from) * nominalSegmentSeconds
    }

    /// The lowest and highest read fronts fetched within `frontStaleness`;
    /// `nil` when none is (before the first fetch, or a long pause). Under
    /// the lock.
    private func activeFrontBounds(now: ContinuousClock.Instant) -> (lowest: Int, highest: Int)? {
        let active = fronts.values.filter { now - $0.at <= Self.frontStaleness }.map(\.index)
        guard let lowest = active.min(), let highest = active.max() else { return nil }
        return (lowest, highest)
    }

    /// What retention must never evict while `producing`: from
    /// `keepBehindFront` segments behind the lowest read front up to
    /// `keepAheadOfFront` past the highest front or the producer, whichever
    /// is further — so nothing between the player and the producer goes.
    /// Anchored on the read front rather than the producer: with the
    /// producer a lead ahead, a window around it alone left the segments
    /// AVPlayer was about to fetch unprotected. Falls back to the newest
    /// fetch when every front is stale; `nil` before the first fetch.
    func retentionKeepRange(producing: Int) -> ClosedRange<Int>? {
        lock.withLock {
            guard lastDemandedIndex >= 0 else { return nil }
            let bounds = activeFrontBounds(now: .now) ?? (lastDemandedIndex, lastDemandedIndex)
            let lower = max(0, bounds.lowest - Self.keepBehindFront)
            let upper = max(bounds.highest, producing) + Self.keepAheadOfFront
            return lower...max(lower, upper)
        }
    }

    /// Retention evicted `victims`: count the ones at or after the lowest
    /// read front (diagnostics).
    func noteEvictions(_ victims: [Int]) {
        guard !victims.isEmpty else { return }
        lock.withLock {
            let front = activeFrontBounds(now: .now)?.lowest ?? lastDemandedIndex
            guard front >= 0 else { return }
            evictedAheadOfFront += victims.filter { $0 >= front }.count
        }
    }

    /// A media segment was fetched and was not on disk (diagnostics).
    func noteMiss() {
        lock.withLock { misses += 1 }
    }

    /// The newest demanded index, or `nil` before the first fetch — what
    /// sequential retention must never evict ahead of.
    var playheadIndex: Int? {
        lock.withLock { lastDemandedIndex >= 0 ? lastDemandedIndex : nil }
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

    /// Forget every "never coming" mark at once: the producer changed
    /// something that decides which slots carry audio at all (the audio
    /// offset), so each one has to be answered by production again.
    func clearUnproducible() {
        lock.withLock { unproduciblePaths.removeAll() }
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
    ///
    /// `track` is the fetched path's directory — `""` for the variant,
    /// `audioN` for a rendition — so each front is followed on its own.
    func noteFetch(of index: Int, track: String = "") {
        lock.withLock {
            if index != lastDemandedIndex {
                previousDemandedIndex = lastDemandedIndex
                lastDemandedIndex = index
            }
            if let front = fronts[track], front.index != index {
                previousFronts[track] = front.index
            }
            fronts[track] = (index, .now)
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
    ///
    /// Inside the window the request still re-anchors when it is
    /// discontinuous with the fetch history: AVPlayer's read-ahead asks for
    /// N after N-1 (the variant and each rendition of one index arrive
    /// together, so ±1 of the previous fetch counts as continuous); a request
    /// that jumps further is a seek, however close it lands, and waiting for
    /// serial production to reach it was up to two segments of silence.
    ///
    /// `track` (see `noteFetch`) judges continuity against that front's own
    /// previous fetch; without one, against the newest fetch of any.
    func requestProduction(of index: Int, force: Bool = false, track: String? = nil) {
        lock.withLock {
            // Judged against where production is HEADED, not where it is: a
            // pending anchor, else a taken re-anchor whose first segment has
            // not landed (`producingIndex` still names the old position
            // until the demuxer seek is done), else the producer itself.
            // Read-ahead right behind a seek's or a forced join's anchor N
            // (N+1 pipelined before production reached N) used to move the
            // anchor to N+1 — honoured once the debounce ran out — and N's
            // wait timed out, though production from N reaches N+1 anyway.
            let headed = requestedAnchor ?? reanchorInFlight ?? producingIndex
            let previous = track.flatMap { previousFronts[$0] } ?? previousDemandedIndex
            let continuous = previous < 0 || abs(index - previous) <= 1
            // A forced join is held even against a jump inside the window,
            // waiting to be taken or taken with its first segment not landed:
            // the rendition re-armed by its fetch of N needs N whole, and
            // production from N gets to the jump soon. (Taken, it used to lose
            // that hold — a cached old-track fetch of N-1 between N and N+1
            // made N+1 look like a seek, and N's wait timed out.) A request
            // outside the window is a seek elsewhere and wins.
            let headedIsJoin = requestedAnchor != nil ? anchorIsJoin : inFlightIsJoin
            if !force, continuous || headedIsJoin, headed >= 0,
               index >= headed, index <= headed + Self.forwardWaitWindow {
                return
            }
            // Last request wins: AVPlayer's newest fetch is where the
            // playhead actually is.
            requestedAnchor = index
            requestedAt = .now
            anchorIsForced = force || anchorIsForced
            anchorIsJoin = force
            // Signalled under the lock, so a producer that is between its
            // `requestedAnchor == nil` check and its `wait` cannot miss this.
            lock.broadcast()
        }
    }

    /// A pending wait of a joining rendition found production headed for a
    /// forced join ABOVE its segment `index` (pending or taken, first
    /// segment not landed): production from there never writes `index`, so
    /// the join moves down to it. Only a forced join within the forward-wait
    /// window is moved, and never a seek that replaced a join (it keeps the
    /// force, not the join): a seek is where the player is.
    /// Returns `true` when moved.
    @discardableResult
    func lowerForcedJoin(to index: Int) -> Bool {
        lock.withLock {
            let join = requestedAnchor.map { anchorIsJoin ? $0 : nil }
                ?? (inFlightIsJoin ? reanchorInFlight : nil)
            guard let join, join > index, join - index <= Self.forwardWaitWindow else { return false }
            requestedAnchor = index
            requestedAt = .now
            anchorIsForced = true
            anchorIsJoin = true
            lock.broadcast()
            return true
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
