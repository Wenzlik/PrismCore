import Foundation

extension PrismCoreSession {

    /// How a **sequential** session — one that got no keyframe plan: an index
    /// that did not load in time, a container without one, a live source —
    /// publishes its media playlists. A planned session always serves a
    /// complete VOD playlist and ignores this.
    public enum SequentialPlaylist: Sendable, Equatable {
        /// `EXT-X-PLAYLIST-TYPE:EVENT`: every segment ever produced stays
        /// listed. The segment cache budget still deletes old files behind
        /// the playhead, and a sequential segment cannot be produced again,
        /// so a seek back to one of those is a 404 AVPlayer counts as a
        /// failed segment. The default, and the behaviour before this option
        /// existed.
        case event
        /// A live-style window: no `PLAYLIST-TYPE`, and entries leave the
        /// front of every playlist (variant, audio and subtitle renditions,
        /// on one common instant) once they are more than `seconds` of
        /// content behind the playhead — or sooner, when the segment cache
        /// budget needs the room. `EXT-X-MEDIA-SEQUENCE` advances, segment
        /// names and media timestamps do not change, and a removed segment's
        /// files stay served for RFC 8216's grace period before they are
        /// deleted. What the player can seek back to is then exactly what
        /// the engine can still serve.
        ///
        /// The window never shrinks below three target durations, and never
        /// past the segment AVPlayer fetched last. See the README
        /// ("Sequential sessions") for what that does to the byte budget.
        case slidingWindow(seconds: Double)
    }
}

/// The sliding-window half of a sequential session
/// (`PrismCoreSession.SequentialPlaylist.slidingWindow`): decides where the
/// front of every playlist moves to, moves it, and holds on to what left
/// until a client still reading an older copy of the manifest can no longer
/// ask for it.
///
/// Pure bookkeeping over the playlist writers — the caller owns the files,
/// retires what `slide` returns and unlinks what `takeDue` returns. Time is
/// passed in, so the grace period is testable without waiting it out.
final class SequentialWindow {

    /// What left the playlists in one slide.
    struct Retired: Equatable {
        /// Variant segment indexes (`seg%05d.m4s` in the output root).
        var videoIndexes: [Int]
        /// Every rendition file that left with them — audio fragments and
        /// WebVTT segments, by full path: a rendition numbers its own
        /// segments, so the video's index does not name them.
        var renditionFiles: [URL]
    }

    let seconds: Double
    private let video: MediaPlaylistWriter
    private let renditions: [MediaPlaylistWriter]
    private var pending: [(due: TimeInterval, retired: Retired)] = []

    /// Below this many target durations a live playlist may not shrink
    /// (RFC 8216 §6.2.2) — a client joining needs that much to start from.
    static let minimumTargetDurations = 3.0

    /// Puts every writer in sliding mode, so this must exist before any of
    /// them writes its first playlist.
    init(seconds: Double, video: MediaPlaylistWriter, renditions: [MediaPlaylistWriter]) {
        self.seconds = max(0, seconds)
        self.video = video
        self.renditions = renditions
        for writer in [video] + renditions { writer.slides = true }
    }

    /// Removals whose grace period has not elapsed yet.
    var pendingCount: Int { pending.count }

    /// Move the front of every playlist as far as the window allows and
    /// return what left (`nil` when nothing did).
    ///
    /// - `playheadIndex`: the newest segment AVPlayer fetched. `nil` (nothing
    ///   fetched yet) moves nothing — the head is where the player is about
    ///   to start. A playhead that is no longer listed moves nothing either.
    /// - `budgetCutIndex`: the newest segment the byte budget wants gone; it
    ///   can move the front further than `seconds` would, never past the
    ///   playhead's own segment.
    func slide(playheadIndex: Int?, budgetCutIndex: Int?, now: TimeInterval) throws -> Retired? {
        guard let playheadIndex, let playhead = video.span(ofSequence: playheadIndex) else { return nil }
        var cut = playhead.start - seconds
        if let budgetCutIndex, let victim = video.span(ofSequence: budgetCutIndex) {
            cut = max(cut, min(victim.end, playhead.start))
        }
        let writers = [video] + renditions
        for writer in writers where writer.listedSeconds > 0 {
            cut = min(cut, writer.listedEndSeconds
                - Self.minimumTargetDurations * Double(writer.targetDuration))
        }
        // One instant for every playlist: a rendition entry that straddles
        // the cut pulls it back to that entry's start, and that can land
        // inside another rendition's entry in turn. Strictly decreasing over
        // finitely many boundaries, so this ends.
        while let earlier = writers.lazy.compactMap({ $0.startOfEntry(spanning: cut) }).first {
            cut = earlier
        }
        guard cut > video.listedStartSeconds + MediaPlaylistWriter.boundaryTolerance else { return nil }

        let firstVideoIndex = video.mediaSequence
        let removedVideo = try video.removeEntries(endingBy: cut)
        var retired = Retired(
            videoIndexes: Array(firstVideoIndex..<(firstVideoIndex + removedVideo.count)),
            renditionFiles: []
        )
        var longestSegment = removedVideo.map(\.duration).max() ?? 0
        for rendition in renditions {
            for entry in try rendition.removeEntries(endingBy: cut) {
                retired.renditionFiles.append(rendition.directory.appendingPathComponent(entry.file))
                longestSegment = max(longestSegment, entry.duration)
            }
        }
        guard !retired.videoIndexes.isEmpty || !retired.renditionFiles.isEmpty else { return nil }
        // RFC 8216 §6.2.2: a removed segment stays available for its own
        // duration plus that of the longest playlist that contained it — a
        // client may have loaded that playlist just before this rewrite and
        // still be working through it. The longest any playlist has EVER
        // been bounds that from above for every segment in the batch.
        let longestPlaylist = writers.map(\.longestListedSeconds).max() ?? 0
        pending.append((now + longestSegment + longestPlaylist, retired))
        return retired
    }

    /// The removals whose grace period has elapsed by `now`, oldest first,
    /// forgotten here — the caller unlinks them. Filtered rather than taken
    /// as a prefix: each batch's period depends on its own longest segment,
    /// so a later batch can come due first.
    func takeDue(now: TimeInterval) -> [Retired] {
        let due = pending.filter { $0.due <= now }.map(\.retired)
        pending.removeAll { $0.due <= now }
        return due
    }
}
