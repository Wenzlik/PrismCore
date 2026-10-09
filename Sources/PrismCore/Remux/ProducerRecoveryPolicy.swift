import Foundation

/// When a planned producer re-opens its source after a read failure, and when
/// it stops trying.
///
/// Before this, any read error that survived the transport's own retries
/// ended the remux an hour into a film: a Wi-Fi roam, a host range proxy
/// restarting, one 5xx from a media server. The host's only remedy was a new
/// session — a new probe (a full bite each through a host proxy), a new
/// display handshake, a seek back — for an origin that was answering again a
/// second later. A planned session already knows how to start production at
/// any segment (`reanchor`), so a fresh context and a re-anchor is the whole
/// repair.
///
/// Pure bookkeeping, like `SegmentRetention`: the remuxer owns the context
/// and asks this what to do with each failure.
///
/// - `.permanent` never re-opens. The origin answered about this request
///   (404, 403, a 4xx) and the same request gets the same answer.
/// - `.retryable` re-opens, within the cap.
/// - `.unknown` re-opens too — it is how a host input's own error arrives
///   (an SMB mount that blinked surfaces as an unclassifiable `-EIO`), and
///   that is one of the failures this exists for. But `.unknown` also covers
///   bytes that will never read (a damaged cluster), where a re-open lands
///   on the same segment and fails on the same packet. So an `.unknown`
///   failure of the READ that follows a recovery before any segment landed
///   ends it at once: the re-open worked, the source is reachable, and the
///   read still failed in the same place — that is evidence about the bytes,
///   not the link. A failing re-open keeps the cap's budget, since there the
///   source is still unreachable and time is what fixes that.
/// - The cap is hard: `maxAttempts` re-opens inside `window`, whatever the
///   classification. A token that expired behind a server answering 503
///   instead of 401 looks retryable forever; the cap is what ends it.
struct ProducerRecoveryPolicy {

    static let maxAttempts = 3
    static let window: TimeInterval = 60
    /// Waited BEFORE each re-open, indexed by the attempts already made in
    /// the window. Short on purpose: a pending serve has `productionTimeout`
    /// (15 s) before AVPlayer is told anything, and the three delays together
    /// (7 s) leave room for the re-opens themselves.
    static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    struct Attempt: Equatable {
        /// 1-based, counted inside the current window — the number the cap
        /// is applied to, so `maxAttempts` means the next failure ends it.
        let number: Int
        let delay: Duration
    }

    private var attempts: [TimeInterval] = []
    private var recovered = false
    private var progressedSinceRecovery = false

    /// The next re-open for `cause`, or `nil` to give up.
    ///
    /// - Parameter reopening: the failure came from a re-open (or the seek
    ///   right after it), not from production reading a context that opened.
    mutating func nextAttempt(
        for cause: PrismCoreError, at now: TimeInterval, reopening: Bool
    ) -> Attempt? {
        switch cause.retryability {
        case .permanent: return nil
        case .unknown where !reopening && recovered && !progressedSinceRecovery: return nil
        case .unknown, .retryable: break
        }
        attempts.removeAll { now - $0 >= Self.window }
        guard attempts.count < Self.maxAttempts else { return nil }
        let delay = Self.backoff[min(attempts.count, Self.backoff.count - 1)]
        attempts.append(now)
        return Attempt(number: attempts.count, delay: delay)
    }

    /// A re-open and re-anchor succeeded.
    mutating func noteRecovered() {
        recovered = true
        progressedSinceRecovery = false
    }

    /// A segment landed: production has moved past wherever it last failed.
    mutating func noteProgress() {
        progressedSinceRecovery = true
    }
}
