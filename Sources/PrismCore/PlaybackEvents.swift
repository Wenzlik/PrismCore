import Foundation

/// Something the running session noticed that a host can explain to a viewer.
///
/// Before these existed, every runtime trouble reached the host the same way:
/// a generic AVPlayer error some seconds later, with the cause — an origin
/// shedding load, a producer parked inside a read nobody answers — known only
/// to the engine's own log. Report-only: the events describe what happened,
/// including the one repair the engine makes on its own
/// (`producerRecovered`); a host acting on them changes nothing inside it.
///
/// `Equatable` compares a `PrismCoreError` payload by its `description`: the
/// error carries `any Error` and is not `Equatable` itself, and two failures
/// that print the same are the same thing to everything that compares
/// events (tests, a host de-duplicating a banner).
public enum PlaybackEvent: Sendable, Equatable {
    /// A served file took longer than the server's slow-serve threshold
    /// (2 s) to be ready, and was then delivered. `waited` is the whole wait.
    case slowServe(path: String, waited: Duration)

    /// A served file never landed within the production window, and the
    /// request was answered with the miss (an aborted transfer for media, an
    /// empty WebVTT for subtitles). AVPlayer usually reports an error next.
    case serveTimedOut(path: String)

    /// A request is waiting on the producer and the producer has not read a
    /// packet for `since`. `lastPTS` is the newest packet timestamp it did
    /// read, in seconds on the source's timeline (`nil` before the first).
    ///
    /// Measured only while a serve is pending, and never while the producer
    /// is deliberately parked, so a paused player does not look stalled.
    case producerStalled(since: Duration, lastPTS: Double?)

    /// The source origin answered 429/503/509. `retryAfter` is what its
    /// `Retry-After` header asked for, when it sent one.
    ///
    /// Origin admission is shared by every session reading the same origin,
    /// so **every session on that origin sees this**, including one whose own
    /// requests were never refused — they are all held back by it.
    case originThrottled(retryAfter: Duration?)

    /// The first good response from a throttled origin. Shared like
    /// `originThrottled`.
    case originRecovered

    /// A read of the source failed mid-session, and production carried on:
    /// the producer re-opened the source and re-anchored at the segment it
    /// was producing. `cause` is the failure it recovered from; `attempt`
    /// counts re-opens inside the current 60 s window, the one the cap of 3
    /// applies to — so `attempt == 3` means the next failure inside that
    /// window ends the session.
    ///
    /// Planned sessions only (see the README's *Streaming* section). While
    /// it re-opens, fetches of unproduced segments are held exactly as for a
    /// seek, so AVPlayer sees a slow segment rather than an error.
    case producerRecovered(attempt: Int, cause: PrismCoreError)

    /// The producer stopped for good: `remuxFailure` is now set, to this
    /// same classification. Sent exactly once per session that fails, and
    /// never for a `stop()`. A failure during startup sends it too — `start()`
    /// throws the same failure there.
    case producerFailed(PrismCoreError)

    public static func == (lhs: PlaybackEvent, rhs: PlaybackEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.slowServe(lp, lw), .slowServe(rp, rw)): return lp == rp && lw == rw
        case let (.serveTimedOut(l), .serveTimedOut(r)): return l == r
        case let (.producerStalled(ls, lp), .producerStalled(rs, rp)): return ls == rs && lp == rp
        case let (.originThrottled(l), .originThrottled(r)): return l == r
        case (.originRecovered, .originRecovered): return true
        case let (.producerRecovered(la, lc), .producerRecovered(ra, rc)):
            return la == ra && lc.description == rc.description
        case let (.producerFailed(l), .producerFailed(r)): return l.description == r.description
        default: return false
        }
    }
}

/// Where the engine's components drop `PlaybackEvent`s. Exists from session
/// init, so a host may register before or after `start()`; with nobody
/// registered, a yield is one lock and a nil check.
final class PlaybackEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<PlaybackEvent>.Continuation?

    var isObserved: Bool { lock.withLock { continuation != nil } }

    func yield(_ event: PlaybackEvent) {
        // Yielded outside the lock: the continuation has its own, and holding
        // ours across it would order unrelated emitters behind each other.
        lock.withLock { continuation }?.yield(event)
    }

    func replace(with next: AsyncStream<PlaybackEvent>.Continuation?) {
        let previous = lock.withLock {
            defer { continuation = next }
            return continuation
        }
        previous?.finish()
    }
}
