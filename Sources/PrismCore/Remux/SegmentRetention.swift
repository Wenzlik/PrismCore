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
/// The policy is distance-from-playhead: when the recorded total exceeds the
/// budget, the segment farthest from the one being produced goes first — the
/// producer trails the playhead, so distance from it approximates "least
/// likely to be fetched next". A keep window around the playhead is exempt
/// even over budget: evicting what AVPlayer is about to fetch would turn the
/// budget into a reproduction loop.
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
    /// `producing` first — until the total fits the budget again.
    mutating func record(index: Int, bytes: Int, producing: Int) -> [Int] {
        totalBytes += bytes - (sizes[index] ?? 0)
        sizes[index] = bytes

        var victims: [Int] = []
        while totalBytes > budgetBytes {
            let candidate = sizes.keys
                .filter { abs($0 - producing) > keepWindow }
                .max { abs($0 - producing) < abs($1 - producing) }
            guard let victim = candidate else { break }
            totalBytes -= sizes.removeValue(forKey: victim) ?? 0
            victims.append(victim)
        }
        return victims
    }
}
