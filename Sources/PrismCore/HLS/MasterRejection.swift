import Foundation

/// Recognizes the failures that mean *"AVPlayer refused the master playlist"*,
/// as opposed to the source being unplayable.
///
/// The distinction matters because the two look identical from the host's side —
/// an `AVPlayerItem` that went `.failed` — but the remedies are opposites: a
/// refused master plays perfectly as a media-direct session (`forceMuxedShape`),
/// while a genuinely unplayable source has to fall back to Prism. Getting it
/// wrong either way is a user-visible failure, so the codes are named here once
/// instead of being re-typed at each call site.
///
/// ## The three codes
///
/// - `-11868` `AVErrorNoCompatibleAlternatesForExternallyPausedVideo` — every
///   variant was rejected by the compatibility gate. What a `dvh1` claim gets
///   from a non-DV display, and what an over-claimed `CODECS` string gets from a
///   decoder that can't take it.
/// - `-11848` — the SDR-parked-panel rejection: a `VIDEO-RANGE=PQ`/`HLG` variant
///   offered to a display that is not going to leave SDR. `DisplayCapabilities`
///   reads readiness optimistically (Match Content is the common case and cannot
///   be distinguished from Match-Content-off), so this is the code that catches
///   the optimism being wrong.
/// - `-1002` `NSURLErrorUnsupportedURL` — every variant was filtered while
///   *parsing* the master, so AVPlayer never fetched a media playlist at all and
///   reports the manifest URL as unsupported. An HDR variant with no
///   `FRAME-RATE` is the classic cause (which `MasterPlaylistBuilder` refuses to
///   emit for exactly this reason), but a served master can still earn it.
///
/// Codes are matched **across error domains** on purpose: -11868/-11848 arrive in
/// `AVFoundationErrorDomain` while -1002 arrives in `NSURLErrorDomain`, none of
/// the three collides with a code the other domain uses, and pinning domains
/// would only add a way to miss a match.
public enum MasterRejection {

    /// The codes, as a set, so a host can match them itself.
    public static let errorCodes: Set<Int> = [-11868, -11848, -1002]

    /// Does this error mean the master was refused?
    ///
    /// Walks `NSUnderlyingErrorKey` because the code is routinely nested:
    /// `AVPlayerItem.error` is typically an `AVFoundationErrorDomain` wrapper
    /// whose underlying error carries the real reason, and checking only the
    /// outer layer misses most real rejections.
    public static func matches(_ error: (any Error)?) -> Bool {
        guard let error else { return false }
        var next: NSError? = error as NSError
        // Bounded rather than `while let`: an underlying-error chain is
        // attacker-adjacent input in the sense that it comes from a framework we
        // don't control, and a cycle here would hang the host's failure handler.
        var depth = 0
        while let current = next, depth < 8 {
            if errorCodes.contains(current.code) { return true }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
