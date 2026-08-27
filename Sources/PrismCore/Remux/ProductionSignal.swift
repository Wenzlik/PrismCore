import Foundation

/// "Something landed on disk" — the producer's broadcast to whoever is
/// waiting for a file that does not exist yet: the session's readiness gate
/// and the provider's pending serves.
///
/// Both of those used to poll the filesystem every 10 ms. That interval was
/// already a compromise (a coarser one quantized every startup up to its own
/// length, measured 103 ms returned for 33 ms ready), and it still put a poll
/// on the two latency-critical paths — the first frame and every demand
/// fetch. This replaces the interval with a wake: the producer calls
/// `broadcast()` after each write, and a waiter suspends until the next one.
///
/// The FILE SYSTEM stays the source of truth. A signal carries no payload
/// and names no file — it means "look again", nothing more — so a spurious
/// wake costs one `stat` and a missed one costs at most the backstop. The
/// wake-before-wait rule (see `DemandCoordinator`) is honoured by a
/// generation counter rather than by care: a waiter snapshots the
/// generation, checks the disk, and `wait(after:)` returns at once when the
/// generation has already moved on — so a broadcast that races the check can
/// never be lost, whichever side wins.
///
/// Waiters are `async` (cooperative-pool) code, hence continuations rather
/// than an `NSCondition`: the provider's serve must not block a pool thread
/// for the length of a segment's production (#44).
final class ProductionSignal: @unchecked Sendable {

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: Waiter] = [:]

    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        /// The backstop sleep, cancelled when a broadcast beats it so a busy
        /// producer does not leave a trail of dormant sleeps behind.
        var backstop: Task<Void, Never>?
    }

    /// The current generation — snapshot BEFORE checking the disk, then hand
    /// it to `wait(after:)`, and the check-then-wait sequence cannot lose a
    /// broadcast that lands in between.
    var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    /// Something landed. Called by the producer AFTER the file write, never
    /// before — a waiter woken early would check the disk, see nothing, and
    /// wait out the whole backstop.
    func broadcast() {
        let woken: [Waiter] = lock.withLock {
            generation &+= 1
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        // Resumed outside the lock: the resumed code may call straight back
        // in (a provider loop re-snapshots the generation immediately).
        for waiter in woken {
            waiter.backstop?.cancel()
            waiter.continuation.resume()
        }
    }

    /// Suspend until a broadcast newer than `generation` — or `backstop`
    /// elapses. Returns immediately when one already happened.
    ///
    /// The backstop is exactly that: with every write followed by a
    /// broadcast the wake is the mechanism, and the timer only guards
    /// against a landing nobody announced (a rendition file written by a
    /// path that forgot to signal). Coarse on purpose — a 10 ms backstop
    /// would be the old poll wearing a new name.
    func wait(after generation: UInt64, backstop: Duration = .milliseconds(200)) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard self.generation == generation else {
                lock.unlock()
                continuation.resume()
                return
            }
            let id = nextWaiterID
            nextWaiterID &+= 1
            waiters[id] = Waiter(continuation: continuation, backstop: nil)
            lock.unlock()

            // Registered after the waiter exists, so the timer can only ever
            // find a waiter to remove — never race an insert.
            let timer = Task { [weak self] in
                try? await Task.sleep(for: backstop)
                guard !Task.isCancelled, let self else { return }
                self.resume(waiterID: id)
            }
            lock.withLock { waiters[id]?.backstop = timer }
        }
    }

    /// Resume one waiter if it is still registered: a broadcast may have
    /// already taken it, in which case the timer finds nothing and does
    /// nothing — resuming a continuation twice is a crash, so the dictionary
    /// entry is the single-resume guard.
    private func resume(waiterID: UInt64) {
        let waiter: Waiter? = lock.withLock { waiters.removeValue(forKey: waiterID) }
        waiter?.continuation.resume()
    }
}
