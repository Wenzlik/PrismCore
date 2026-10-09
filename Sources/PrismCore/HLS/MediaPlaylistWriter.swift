import Foundation

/// Writes the EVENT media playlist as segments land, atomically, so the
/// loopback never serves a half-written manifest.
///
/// Owned by the remuxer because the segmentation is ours now (see
/// `FMP4SegmentWriter` for why the `hls` muxer isn't an option): the muxer
/// makes fragments, this makes them an HLS presentation.
///
/// A sequential session that opted into `.slidingWindow` writes the same
/// playlist without `PLAYLIST-TYPE` and lets `SequentialWindow` take entries
/// off the front (`removeEntries(endingBy:)`), advancing
/// `EXT-X-MEDIA-SEQUENCE` by one per entry removed.
final class MediaPlaylistWriter {

    let directory: URL
    /// `nil` omits `EXT-X-MAP` — what a WebVTT rendition playlist needs, since
    /// its segments are plain text files with no init segment to reference.
    private let initFileName: String?
    private var entries: [(duration: Double, file: String)] = []
    /// The entries as playlist text, appended to per segment — the EVENT
    /// playlist is rewritten on every cut, and rebuilding the whole body from
    /// `entries` made that O(n) string work per segment for the length of a
    /// film (every rendition too). Only the header is recomputed (its
    /// TARGETDURATION is a running maximum).
    private var entriesText = ""
    private var longestDuration = 0.0

    /// Sliding-window publication (see `SequentialWindow`). Must be set
    /// before the first write: a playlist that went out as EVENT has promised
    /// the client that nothing will ever leave it.
    var slides = false
    /// Media sequence number of the first listed entry — how many entries
    /// have left the front.
    private(set) var mediaSequence = 0
    /// Playlist-timeline seconds of everything removed from the front, so a
    /// listed entry's position keeps meaning the same instant on every
    /// rendition's timeline after their windows moved.
    private var removedSeconds = 0.0
    /// Seconds currently listed.
    private(set) var listedSeconds = 0.0
    /// The longest this playlist has ever been, in seconds — the second term
    /// of RFC 8216 §6.2.2's availability rule for a removed segment.
    private(set) var longestListedSeconds = 0.0

    /// Two entry boundaries closer than this are the same boundary. Each
    /// rendition sums its own durations (the video's ticks, a rendition's
    /// folded silent boundaries, a subtitle's `end - start`), so the same cut
    /// arrives with float noise many orders of magnitude below a frame.
    static let boundaryTolerance = 0.000_1

    init(directory: URL, initFileName: String? = "init.mp4") {
        self.directory = directory
        self.initFileName = initFileName
    }

    /// Record one finished segment and rewrite the playlist.
    func appendSegment(duration: Double, file: String) throws {
        entries.append((duration, file))
        appendText(duration: duration, file: file)
        listedSeconds += duration
        longestListedSeconds = max(longestListedSeconds, listedSeconds)
        try write(ended: false)
    }

    private func appendText(duration: Double, file: String) {
        entriesText += Self.entryText(duration: duration, file: file)
        longestDuration = max(longestDuration, duration)
    }

    private static func entryText(duration: Double, file: String) -> String {
        String(format: "#EXTINF:%.5f,\n", duration) + file + "\n"
    }

    /// Write the COMPLETE playlist upfront from a segment plan — the
    /// demand-driven shape (phase 5). Every planned segment is listed with
    /// its planned duration and `EXT-X-ENDLIST` closes it immediately:
    /// AVPlayer then knows every URI and duration before a single segment
    /// exists, so a seek is just a fetch — the loopback's provider makes the
    /// requested segment exist. `PLAYLIST-TYPE:VOD` because nothing will be
    /// appended; the manifest is a promise the producer keeps on demand.
    func writePlannedVOD(durations: [Double], fileName: (Int) -> String) throws {
        entries = durations.enumerated().map { (index, duration) in
            (duration, fileName(index))
        }
        entriesText = ""
        longestDuration = 0
        for entry in entries { appendText(duration: entry.duration, file: entry.file) }
        try write(ended: true, playlistType: "VOD")
    }

    /// Append `EXT-X-ENDLIST`, flipping the event into a finished VOD.
    func finish() throws {
        try write(ended: true)
    }

    // MARK: - Sliding window

    /// The `EXT-X-TARGETDURATION` the next write declares.
    var targetDuration: Int {
        max(1, Int(max(longestDuration, entries.isEmpty ? 1 : 0).rounded(.up)))
    }

    /// Playlist-timeline end of the last listed entry.
    var listedEndSeconds: Double { removedSeconds + listedSeconds }

    /// Playlist-timeline start of the first listed entry.
    var listedStartSeconds: Double { removedSeconds }

    /// Playlist-timeline span of the entry with media sequence number
    /// `sequence`, or `nil` when it is not listed (gone, or not written yet).
    func span(ofSequence sequence: Int) -> (start: Double, end: Double)? {
        let position = sequence - mediaSequence
        guard entries.indices.contains(position) else { return nil }
        var start = removedSeconds
        for entry in entries[..<position] { start += entry.duration }
        return (start, start + entries[position].duration)
    }

    /// Start of the listed entry that `seconds` falls strictly inside, or
    /// `nil` when `seconds` is one of this playlist's boundaries (or outside
    /// what is listed). What lets every playlist of a presentation be cut on
    /// one common instant: an audio entry that folded a silent boundary into
    /// itself has no boundary where the video has one.
    func startOfEntry(spanning seconds: Double) -> Double? {
        var start = removedSeconds
        for entry in entries {
            let end = start + entry.duration
            if seconds > start + Self.boundaryTolerance, seconds < end - Self.boundaryTolerance {
                return start
            }
            if end > seconds { return nil }
            start = end
        }
        return nil
    }

    /// Take every leading entry that ends at or before `seconds` off the
    /// playlist and rewrite it, advancing the media sequence by one per
    /// entry. Returns what left, oldest first — files the caller still has to
    /// keep serving for a while (RFC 8216 §6.2.2) before it may unlink them.
    func removeEntries(endingBy seconds: Double) throws -> [(duration: Double, file: String)] {
        var removed: [(duration: Double, file: String)] = []
        var end = removedSeconds
        for entry in entries {
            end += entry.duration
            guard end <= seconds + Self.boundaryTolerance else { break }
            removed.append(entry)
        }
        guard !removed.isEmpty else { return [] }
        entries.removeFirst(removed.count)
        mediaSequence += removed.count
        for entry in removed { removedSeconds += entry.duration }
        listedSeconds = entries.reduce(0) { $0 + $1.duration }
        // Rebuilt rather than trimmed: a sliding playlist is bounded by its
        // window, so this is the O(window) work the append-only text exists
        // to avoid for an EVENT playlist that grows with the film.
        entriesText = entries.map { Self.entryText(duration: $0.duration, file: $0.file) }.joined()
        try write(ended: false)
        return removed
    }

    private func write(ended: Bool, playlistType: String = "EVENT") throws {
        // TARGETDURATION must be ≥ every EXTINF rounded to the nearest int
        // (RFC 8216 §4.3.3.1) — ceil clears that bar for any duration mix.
        // A running maximum over everything ever listed, never recomputed
        // from what is left: the tag may not change under a sliding window.
        var text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(targetDuration)
        #EXT-X-MEDIA-SEQUENCE:\(mediaSequence)

        """
        // No type at all for a sliding window: EVENT forbids removing a
        // segment, and that is the whole of what this mode does.
        if !slides {
            text += "#EXT-X-PLAYLIST-TYPE:\(playlistType)\n"
        }
        text += "#EXT-X-INDEPENDENT-SEGMENTS\n"
        if let initFileName {
            text += "#EXT-X-MAP:URI=\"\(initFileName)\"\n"
        }
        text += entriesText
        if ended {
            text += "#EXT-X-ENDLIST\n"
        }
        try Data(text.utf8).write(
            to: directory.appendingPathComponent("index.m3u8"),
            options: .atomic
        )
    }
}
