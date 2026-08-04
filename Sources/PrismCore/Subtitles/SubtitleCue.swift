import Foundation

/// One timed text cue on the **presentation timeline**, in seconds.
///
/// Deliberately container- and codec-agnostic: everything upstream (a Matroska
/// `subrip` packet, an ASS event, a whole `.srt` sidecar) converges here, and
/// everything downstream (the segmented WebVTT writer) only ever sees this.
/// That is what lets the conversion rules be unit-tested without a demuxer.
struct SubtitleCue: Equatable {
    /// Seconds from the presentation origin (see `SubtitleRenditionSet` for
    /// what the origin is and why the WebVTT timestamp map carries it).
    var start: Double
    var end: Double
    /// Cue payload, already WebVTT-safe (no `-->`, no blank lines).
    var text: String

    /// Clamped copy for a segment that only partially contains this cue.
    func clamped(to range: ClosedRange<Double>) -> SubtitleCue {
        SubtitleCue(
            start: Swift.max(start, range.lowerBound),
            end: Swift.min(end, range.upperBound),
            text: text
        )
    }

    var overlapsNothing: Bool { end <= start }
}

/// `HH:MM:SS.mmm` — the only timestamp form WebVTT cue timings take (the
/// `MM:SS.mmm` short form is legal but we always print hours, which is what
/// every reference manifest does and what keeps the widths fixed).
func webVTTTimestamp(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    // Round to whole milliseconds FIRST: formatting the components separately
    // from a Double would print 59.9996 s as "00:00:60.000".
    let totalMilliseconds = Int64((clamped * 1000).rounded())
    let milliseconds = totalMilliseconds % 1000
    let totalSeconds = totalMilliseconds / 1000
    return String(
        format: "%02lld:%02lld:%02lld.%03lld",
        totalSeconds / 3600,
        (totalSeconds % 3600) / 60,
        totalSeconds % 60,
        milliseconds
    )
}
