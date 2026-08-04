import Foundation

/// One subtitle rendition on disk: `subs<N>/seg%05d.vtt` segments plus
/// `subs<N>/index.m3u8`, cut on the **same wall-time boundaries as the video
/// segments** so the two playlists line up 1:1 (what AVPlayer expects of a
/// `SUBTITLES` rendition, and what keeps its segment fetches predictable).
///
/// ### Timeline and `X-TIMESTAMP-MAP`
///
/// WebVTT cue times are local to the file, so HLS bridges them to the media
/// timeline with `X-TIMESTAMP-MAP=MPEGTS:<t>,LOCAL:<local>`: the player reads it
/// as "local time `LOCAL` is media timestamp `t`", where `t` is on a **90 kHz**
/// axis regardless of what timescale the media segments use (RFC 8216 §3.5).
///
/// Our media segments are fMP4 carrying the source's own stream-copied
/// timestamps, so the media timeline starts at the source's first video PTS —
/// there is no MPEG-TS 10 s convention to honour here, and assuming one is
/// exactly the bug that makes fMP4 subtitle tracks render ~10 s late elsewhere.
/// So:
///
/// - cue times are written **relative to the presentation origin** (the first
///   video PTS), i.e. a cue one second into playback prints `00:00:01.000`;
/// - every segment repeats `MPEGTS:round(origin × 90000),LOCAL:00:00:00.000`,
///   which is the offset that carries the origin back onto the media axis.
///
/// For the ordinary source whose first PTS is 0 that reduces to `MPEGTS:0`, and
/// for a mid-stream capture starting at 10 s it prints `MPEGTS:900000` because
/// the video really does start there — the map states a fact about the output
/// rather than a convention.
final class WebVTTRenditionWriter {

    /// Cue whose packet duration was missing or non-positive. Matroska text
    /// blocks carry a real duration; a `tx3g` sample or a damaged block may
    /// not, and a zero-length cue is invisible.
    static let fallbackCueSeconds = 3.0

    private let directory: URL
    private let playlist: MediaPlaylistWriter
    /// Presentation origin in source seconds. Cues and boundaries arrive on the
    /// source's own axis and are printed relative to this.
    private var originSeconds: Double = 0
    /// Cues not yet fully written out, ordered by start time. A cue that
    /// extends past the current boundary stays here so the next segment can
    /// repeat it (standard segmented-VTT practice).
    private var pending: [SubtitleCue] = []
    private var segmentIndex = 0

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // No EXT-X-MAP: a WebVTT rendition has no init segment.
        self.playlist = MediaPlaylistWriter(directory: directory, initFileName: nil)
    }

    /// Presentation origin in seconds on the source's own timeline — the value
    /// the timestamp map carries. Set before the first flush.
    func setTimelineOrigin(seconds: Double) {
        originSeconds = max(0, seconds)
    }

    /// `MPEGTS` value paired with `LOCAL:00:00:00.000`, on the 90 kHz axis.
    var mpegtsOffset: Int64 {
        Int64((originSeconds * 90_000).rounded())
    }

    func add(_ cue: SubtitleCue) {
        guard !cue.overlapsNothing, !cue.text.isEmpty else { return }
        pending.append(cue)
    }

    /// Write the segment covering `[start, end)` — **source seconds**, the same
    /// axis the cues arrive on. Always writes a file, even with no cues in
    /// range: the rendition must have as many segments as the video, and an
    /// empty segment is a header-only `.vtt`.
    func flushSegment(start: Double, end: Double) throws {
        let range = start...max(start, end)
        let inRange = pending
            .filter { $0.start < range.upperBound && $0.end > range.lowerBound }
            .map { $0.clamped(to: range) }
            .filter { !$0.overlapsNothing }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            // Printed relative to the origin; the timestamp map carries the
            // origin itself back onto the media axis.
            .map { SubtitleCue(start: $0.start - originSeconds, end: $0.end - originSeconds, text: $0.text) }

        let file = String(format: "seg%05d.vtt", segmentIndex)
        try Data(Self.render(cues: inRange, mpegtsOffset: mpegtsOffset).utf8)
            .write(to: directory.appendingPathComponent(file), options: .atomic)
        try playlist.appendSegment(duration: max(0.001, end - start), file: file)
        segmentIndex += 1

        // Keep only what a later segment still has to repeat.
        pending.removeAll { $0.end <= range.upperBound }
    }

    /// `EXT-X-ENDLIST` on the rendition playlist.
    func finish() throws {
        try playlist.finish()
    }

    /// The WebVTT body for one segment.
    static func render(cues: [SubtitleCue], mpegtsOffset: Int64) -> String {
        var text = "WEBVTT\n"
        text += "X-TIMESTAMP-MAP=MPEGTS:\(mpegtsOffset),LOCAL:00:00:00.000\n"
        for cue in cues {
            text += "\n"
            text += "\(webVTTTimestamp(cue.start)) --> \(webVTTTimestamp(cue.end))\n"
            text += cue.text + "\n"
        }
        return text
    }
}
