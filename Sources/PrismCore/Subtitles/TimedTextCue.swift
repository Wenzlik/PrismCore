import Foundation

/// One timed text cue of an embedded subtitle stream, handed to the host as
/// the demux produces it — the host-facing twin of the internal `SubtitleCue`.
///
/// Exists because the WebVTT renditions are not always the right delivery for
/// text: AVPlayer times a `SUBTITLES` rendition on its own segment schedule,
/// which is where the late-cue drift class of bugs lives, while a host that
/// draws captions itself wants the cue list on the player's own clock. Plex's
/// subtitle-only transcode turned out to answer empty documents for embedded
/// tracks (Aether#1533), so "ask the server for the text" is not a route — the
/// demux this engine already runs is the one honest source of embedded cues.
///
/// Times are **seconds on the producer's playback clock**. Remux callbacks
/// subtract the source's presentation origin for comparison with
/// `AVPlayerItem.currentTime()`. `SoftwarePlaybackPipeline.activeSubtitleCues`
/// keeps source timestamps, matching that pipeline's `currentTime`.
public struct TimedTextCue: Sendable, Equatable {
    /// The source stream this cue came from — the same index
    /// `SubtitleTrackInfo.streamIndex` reports, so a host can route cues to
    /// the track the viewer selected.
    public let streamIndex: Int32
    /// Seconds on the producing pipeline's playback clock (see above).
    public let start: Double
    public let end: Double
    /// Cue payload as the converter produced it — WebVTT-safe plain text,
    /// possibly carrying simple inline tags (`<i>`, `<b>`, `<u>`) the source
    /// had, including ones translated from ASS `{\i1}`-style overrides.
    public let text: String
    /// Where the source asked for the cue to be drawn (an ASS `\an8`, a
    /// WebVTT `line:`), or `nil` for the host's default placement — which is
    /// what nearly every cue wants. A host that ignores it draws exactly what
    /// it drew before.
    public let placement: TextCuePlacement?

    public init(
        streamIndex: Int32, start: Double, end: Double, text: String,
        placement: TextCuePlacement? = nil
    ) {
        self.streamIndex = streamIndex
        self.start = start
        self.end = end
        self.text = text
        self.placement = placement
    }
}

enum SubtitleDelay {
    /// Wider than audio's +/-2 s: a lip-sync error is a few frames, while a
    /// subtitle file cut for another release (PAL speed-up, a different
    /// intro) is routinely several seconds out.
    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(10, max(-10, value)) : 0
    }
}

extension TimedTextCue {
    /// The cue as the viewer should see it under `delay`, or `nil` when the
    /// shift pushes it wholly before zero. The start is clamped rather than
    /// allowed negative: a negative cue time is the same trap an unsigned
    /// timestamp is on the audio side, and every consumer compares against a
    /// clock that never goes below zero anyway.
    func delayed(by delay: Double) -> TimedTextCue? {
        guard delay != 0 else { return self }
        let start = Swift.max(0, self.start + delay)
        let end = self.end + delay
        guard end > start else { return nil }
        return TimedTextCue(streamIndex: streamIndex, start: start, end: end, text: text, placement: placement)
    }
}

/// How much of the remux cue tap's past a session keeps for replay — what a
/// handler registered late (`setTimedTextCueHandler`), or registered again to
/// pick up a new subtitle delay, is handed before live delivery resumes.
///
/// Live delivery is the same under both: a cue produced while a handler is
/// registered reaches it. Only the replay — and the dedup that keeps a
/// re-demuxed region from reaching the host twice — depend on this.
public enum SubtitleCueHistory: Sendable, Equatable {
    /// Every cue the session produced, for its whole lifetime. A late handler
    /// starts complete and a re-demuxed region is never delivered twice.
    /// Memory grows with the text the title carries — fine for a film, not
    /// necessarily for a long captioned stream or a disc with many tracks.
    case complete
    /// The newest cues only, at most `maxCues` of them and at most `maxBytes`
    /// of UTF-8 between their text and their dedup keys (a key is the cue's
    /// stream, source times and text, so a cue costs a little over twice its
    /// text). The oldest go first, cue and key together.
    ///
    /// What a host opting in takes on:
    /// - A replay is the retained window, not the film: a late handler, or a
    ///   re-registration after `setSubtitleDelaySeconds`, sees only what is
    ///   still held (with the delay in force now, as under `.complete`).
    /// - Dedup covers the retained window only. A seek far enough back that
    ///   the region's cues were evicted re-demuxes them, and they are
    ///   delivered again.
    /// - A single cue larger than `maxBytes` is delivered live and never
    ///   retained (keeping it would mean evicting everything else for one
    ///   cue that still would not fit). It is counted in `evictedCues`.
    /// - Cues produced before the presentation origin is known wait in a
    ///   queue bounded the same way; what overflows it was never delivered
    ///   and is counted in `droppedBeforeOrigin`.
    ///
    /// Both limits are clamped to at least 1 when the session is built, so
    /// `Options.subtitleCueHistory` reads back the bound in force. A
    /// `maxBytes` of 1 is a valid "no history": every cue is live-only.
    case bounded(maxCues: Int, maxBytes: Int)

    /// Clamped rather than trapped on: a nonsensical bound is a host
    /// configuration slip, and crashing a player over a memory knob is worse
    /// than honouring the nearest bound that makes sense — the same way the
    /// audio and subtitle delays are clamped.
    var normalized: SubtitleCueHistory {
        guard case .bounded(let maxCues, let maxBytes) = self else { return self }
        return .bounded(maxCues: Swift.max(1, maxCues), maxBytes: Swift.max(1, maxBytes))
    }
}

/// What the remux cue tap is holding right now, and what it let go of — so a
/// bounded history's truncation is never silent.
public struct SubtitleCueHistoryStats: Sendable, Equatable {
    /// Cues a handler registered now would be replayed.
    public let retainedCues: Int
    /// UTF-8 bytes of those cues' text plus their dedup keys — the figure
    /// `SubtitleCueHistory.bounded(maxBytes:)` limits.
    public let retainedBytes: Int
    /// Cues that were delivered (or would have been, to a registered handler)
    /// but are no longer replayable: evicted to make room, or too large to
    /// retain at all. Always 0 under `.complete`.
    public let evictedCues: Int
    /// Cues produced before the presentation origin that overflowed the
    /// pre-origin queue and were never delivered. Always 0 under `.complete`.
    public let droppedBeforeOrigin: Int

    public init(retainedCues: Int, retainedBytes: Int, evictedCues: Int, droppedBeforeOrigin: Int) {
        self.retainedCues = retainedCues
        self.retainedBytes = retainedBytes
        self.evictedCues = evictedCues
        self.droppedBeforeOrigin = droppedBeforeOrigin
    }
}
