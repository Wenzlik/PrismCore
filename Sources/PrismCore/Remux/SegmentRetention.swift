import Foundation

/// Byte-budgeted retention for demand-produced segments (the cache half of
/// phase 5).
///
/// A planned session's segments are REPRODUCIBLE: the playlist promises them,
/// and a fetch of a missing one re-anchors the producer to make it again. That
/// is what makes eviction safe at all — in the sequential (EVENT) shape a
/// deleted segment would be gone for good, so retention only runs in planned
/// mode.
///
/// The policy is distance-from-the-reader: when the recorded total exceeds
/// the budget, the segment farthest from the `keep` range — a little behind
/// AVPlayer's read front up to the producer (`DemandCoordinator
/// .retentionKeepRange`) — goes first, and the range itself is exempt even
/// over budget: evicting what AVPlayer is about to fetch would turn the
/// budget into a reproduction loop. Before the first fetch there is no
/// front, and a window of `keepWindow` around the producing index stands in.
///
/// Pure bookkeeping — the caller owns the files and deletes what `record`
/// returns.
struct SegmentRetention {

    let budgetBytes: Int
    /// Segments within ±window of the producing index are never evicted.
    /// 4 × 6 s covers AVPlayer's typical forward read-ahead plus a step back.
    let keepWindow: Int

    private(set) var totalBytes = 0
    private var sizes: [Int: Int] = [:]

    init(budgetBytes: Int, keepWindow: Int = 4) {
        self.budgetBytes = budgetBytes
        self.keepWindow = keepWindow
    }

    /// Record segment `index` as present with `bytes` on disk (a reproduction
    /// replaces the old size), and return the indices to evict — farthest from
    /// `keep` (else from `producing`) first — until the total fits the budget
    /// again.
    ///
    /// `protected` indexes are never evicted, budget notwithstanding: they
    /// have an outstanding demand serve, and the whole reason the segment was
    /// just (re-)produced may be that fetch. Evicting one hands the provider a
    /// 15 s timeout and AVPlayer a lost connection (issue #43) — the distance
    /// policy can't see that on its own, because a demanded segment stops
    /// being near the producer the moment production runs on past it.
    mutating func record(
        index: Int, bytes: Int, producing: Int, keep: ClosedRange<Int>? = nil, protected: Set<Int> = []
    ) -> [Int] {
        totalBytes += bytes - (sizes[index] ?? 0)
        sizes[index] = bytes

        let kept = keep ?? (producing - keepWindow)...(producing + keepWindow)
        func distance(_ segment: Int) -> Int {
            segment < kept.lowerBound ? kept.lowerBound - segment
                : segment > kept.upperBound ? segment - kept.upperBound : 0
        }
        var victims: [Int] = []
        while totalBytes > budgetBytes {
            let candidate = sizes.keys
                .filter { !kept.contains($0) && !protected.contains($0) }
                .max { distance($0) < distance($1) }
            guard let victim = candidate else { break }
            totalBytes -= sizes.removeValue(forKey: victim) ?? 0
            victims.append(victim)
        }
        return victims
    }

    /// Stop accounting `indexes`: they left by another route. A sliding
    /// window (`SequentialWindow`) drops segments on time as well as on
    /// bytes, and a segment it dropped that stayed on the books here would
    /// keep the total over budget long after the playlist let go of it.
    mutating func forget(_ indexes: [Int]) {
        for index in indexes {
            totalBytes -= sizes.removeValue(forKey: index) ?? 0
        }
    }
}
