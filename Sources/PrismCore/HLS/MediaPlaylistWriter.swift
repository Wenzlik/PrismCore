import Foundation

/// Writes the EVENT media playlist as segments land, atomically, so the
/// loopback never serves a half-written manifest.
///
/// Owned by the remuxer because the segmentation is ours now (see
/// `FMP4SegmentWriter` for why the `hls` muxer isn't an option): the muxer
/// makes fragments, this makes them an HLS presentation.
final class MediaPlaylistWriter {

    private let directory: URL
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

    init(directory: URL, initFileName: String? = "init.mp4") {
        self.directory = directory
        self.initFileName = initFileName
    }

    /// Record one finished segment and rewrite the playlist.
    func appendSegment(duration: Double, file: String) throws {
        entries.append((duration, file))
        appendText(duration: duration, file: file)
        try write(ended: false)
    }

    private func appendText(duration: Double, file: String) {
        entriesText += String(format: "#EXTINF:%.5f,\n", duration) + file + "\n"
        longestDuration = max(longestDuration, duration)
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

    private func write(ended: Bool, playlistType: String = "EVENT") throws {
        // TARGETDURATION must be ≥ every EXTINF rounded to the nearest int
        // (RFC 8216 §4.3.3.1) — ceil clears that bar for any duration mix.
        let target = max(1, Int(max(longestDuration, entries.isEmpty ? 1 : 0).rounded(.up)))
        var text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(target)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:\(playlistType)
        #EXT-X-INDEPENDENT-SEGMENTS

        """
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
