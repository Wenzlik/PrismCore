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

    init(directory: URL, initFileName: String? = "init.mp4") {
        self.directory = directory
        self.initFileName = initFileName
    }

    /// Record one finished segment and rewrite the playlist.
    func appendSegment(duration: Double, file: String) throws {
        entries.append((duration, file))
        try write(ended: false)
    }

    /// Append `EXT-X-ENDLIST`, flipping the event into a finished VOD.
    func finish() throws {
        try write(ended: true)
    }

    private func write(ended: Bool) throws {
        // TARGETDURATION must be ≥ every EXTINF rounded to the nearest int
        // (RFC 8216 §4.3.3.1) — ceil clears that bar for any duration mix.
        let target = max(1, Int((entries.map(\.duration).max() ?? 1).rounded(.up)))
        var text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(target)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:EVENT
        #EXT-X-INDEPENDENT-SEGMENTS

        """
        if let initFileName {
            text += "#EXT-X-MAP:URI=\"\(initFileName)\"\n"
        }
        for entry in entries {
            text += String(format: "#EXTINF:%.5f,\n", entry.duration)
            text += entry.file + "\n"
        }
        if ended {
            text += "#EXT-X-ENDLIST\n"
        }
        try Data(text.utf8).write(
            to: directory.appendingPathComponent("index.m3u8"),
            options: .atomic
        )
    }
}
