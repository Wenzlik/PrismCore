import Testing
import Foundation
@testable import PrismCore

/// The sliding window of a sequential session, driven by hand: playlists are
/// real files in a scratch directory, time is whatever the test says it is.
@Suite("Sequential sliding window")
struct SequentialWindowTests {

    /// A variant, one audio rendition and one subtitle rendition, the way the
    /// remuxer lays them out.
    private final class Presentation {
        let root: URL
        let video: MediaPlaylistWriter
        let audio: MediaPlaylistWriter
        let subtitles: MediaPlaylistWriter
        let window: SequentialWindow
        private var videoCount = 0
        private var audioCount = 0
        private var pendingAudio = 0.0

        init(seconds: Double) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrismCoreWindow-\(UUID().uuidString)", isDirectory: true)
            for directory in ["audio0", "subs0"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(directory), withIntermediateDirectories: true
                )
            }
            video = MediaPlaylistWriter(directory: root)
            audio = MediaPlaylistWriter(directory: root.appendingPathComponent("audio0"))
            subtitles = MediaPlaylistWriter(directory: root.appendingPathComponent("subs0"), initFileName: nil)
            window = SequentialWindow(seconds: seconds, video: video, renditions: [audio, subtitles])
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// One cut, as `emitSegment` makes it. `audioCarries: false` is a
        /// boundary with no audio bytes: the rendition folds its time into
        /// the next entry, and numbers its own files.
        func cut(_ duration: Double, audioCarries: Bool = true) throws {
            try video.appendSegment(duration: duration, file: String(format: "seg%05d.m4s", videoCount))
            try subtitles.appendSegment(duration: duration, file: String(format: "seg%05d.vtt", videoCount))
            videoCount += 1
            if audioCarries {
                try audio.appendSegment(
                    duration: pendingAudio + duration, file: String(format: "seg%05d.m4s", audioCount)
                )
                audioCount += 1
                pendingAudio = 0
            } else {
                pendingAudio += duration
            }
        }

        func playlist(_ directory: String = "") throws -> SegmentVerifier.MediaPlaylist {
            let url = root.appendingPathComponent(directory).appendingPathComponent("index.m3u8")
            return SegmentVerifier.parseMediaPlaylist(try String(contentsOf: url, encoding: .utf8))
        }

        func text(_ directory: String = "") throws -> String {
            let url = root.appendingPathComponent(directory).appendingPathComponent("index.m3u8")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test("The media sequence only grows and a listed URI never changes its name")
    func monotonicSequenceStableURIs() throws {
        let presentation = try Presentation(seconds: 10)
        var lastSequence = 0
        for index in 0..<40 {
            try presentation.cut(2)
            _ = try presentation.window.slide(playheadIndex: max(0, index - 3), budgetCutIndex: nil, now: 0)
            let video = try presentation.playlist()
            #expect(video.mediaSequence >= lastSequence)
            lastSequence = video.mediaSequence
            for segment in video.segments {
                #expect(segment.uri == String(format: "seg%05d.m4s", segment.sequence))
            }
            for segment in try presentation.playlist("subs0").segments {
                #expect(segment.uri == String(format: "seg%05d.vtt", segment.sequence))
            }
            #expect(try !presentation.text().contains("PLAYLIST-TYPE"))
        }
        // 40 cuts of 2 s, playhead at 36 (72 s): 10 s behind it is 62 s.
        #expect(lastSequence == 31)
    }

    @Test("Every playlist leaves on one instant, even where a rendition has no boundary")
    func commonBoundaryAcrossRenditions() throws {
        let presentation = try Presentation(seconds: 0)
        // Audio starts late: its first entry folds video 0 and 1 (0…4 s).
        try presentation.cut(2, audioCarries: false)
        for _ in 0..<9 { try presentation.cut(2) }
        // Playhead on video 2 (4 s) wants the cut at 4 s… but first at 2 s:
        // video and subtitles have a boundary there, audio does not.
        #expect(try presentation.window.slide(playheadIndex: 1, budgetCutIndex: nil, now: 0) == nil)
        #expect(try presentation.playlist().mediaSequence == 0)

        let retired = try #require(try presentation.window.slide(playheadIndex: 2, budgetCutIndex: nil, now: 0))
        #expect(retired.videoIndexes == [0, 1])
        #expect(retired.renditionFiles.map(\.lastPathComponent).sorted()
            == ["seg00000.m4s", "seg00000.vtt", "seg00001.vtt"])
        let video = try presentation.playlist()
        let audio = try presentation.playlist("audio0")
        let subtitles = try presentation.playlist("subs0")
        #expect(video.mediaSequence == 2)
        #expect(subtitles.mediaSequence == 2)
        // The audio rendition numbers its own segments (one fewer: the fold).
        #expect(audio.mediaSequence == 1)
        #expect(audio.segments.first?.uri == "seg00001.m4s")
        // Same listed span everywhere: what is left starts at 4 s in each.
        let spans = [video, audio, subtitles].map { $0.segments.compactMap(\.duration).reduce(0, +) }
        #expect(spans.allSatisfy { abs($0 - 16) < 0.001 }, "\(spans)")
    }

    @Test("A rendition whose first audio comes after the window moved starts on the common front")
    func lateRenditionJoinsTheFront() throws {
        let presentation = try Presentation(seconds: 10)
        // 40 s with no audio at all: the rendition lists nothing and the
        // others slide without it — playhead 38 s, front at 28 s.
        for _ in 0..<20 { try presentation.cut(2, audioCarries: false) }
        let first = try #require(try presentation.window.slide(playheadIndex: 19, budgetCutIndex: nil, now: 0))
        #expect(first.videoIndexes == Array(0..<14))

        // The first audio folds 0…42 s; only 28…42 s is still in the window.
        try presentation.cut(2)
        let audio = try presentation.playlist("audio0")
        #expect(audio.mediaSequence == 0)
        #expect(audio.segments.compactMap(\.duration) == [14])
        #expect(try presentation.text("audio0").contains("#EXT-X-TARGETDURATION:14\n"))

        // The window keeps moving: 86 s produced, playhead at 84 s. The
        // audio's own floor (3 × 14 s) holds the cut at 44 s, a boundary
        // every playlist has. With the fold left at 0…42 s, its 42 s target
        // put that floor below zero and nothing moved again.
        for _ in 0..<22 { try presentation.cut(2) }
        _ = try #require(try presentation.window.slide(playheadIndex: 42, budgetCutIndex: nil, now: 0))
        let video = try presentation.playlist()
        let late = try presentation.playlist("audio0")
        let subtitles = try presentation.playlist("subs0")
        #expect(video.mediaSequence == 22)
        #expect(late.mediaSequence == 2)
        let spans = [video, late, subtitles].map { $0.segments.compactMap(\.duration).reduce(0, +) }
        #expect(spans.allSatisfy { abs($0 - 42) < 0.001 }, "\(spans)")
    }

    @Test("A rendition that stops delivering does not pin the window where it stopped")
    func interruptedRenditionDoesNotPinTheWindow() throws {
        let presentation = try Presentation(seconds: 0)
        // Audio for 30 s, then nothing while the video runs on to 120 s.
        for _ in 0..<5 { try presentation.cut(6) }
        for _ in 0..<15 { try presentation.cut(6, audioCarries: false) }
        let retired = try #require(try presentation.window.slide(playheadIndex: 19, budgetCutIndex: nil, now: 0))
        // The variant's own floor (120 − 3 × 6 s), not the audio's (30 − 18 s).
        #expect(retired.videoIndexes == Array(0..<17))
        let audio = try presentation.playlist("audio0")
        #expect(audio.segments.isEmpty)
        #expect(audio.mediaSequence == 5)

        // Audio resumes: its entry starts on the front (102 s), not at 30 s.
        try presentation.cut(6)
        #expect(try presentation.playlist("audio0").segments.compactMap(\.duration) == [24])
    }

    @Test("The window never drops below three target durations, nor past the playhead")
    func minimumWindow() throws {
        let presentation = try Presentation(seconds: 0)
        for _ in 0..<10 { try presentation.cut(6) }
        // Playhead on the last segment: zero seconds of history asked for,
        // but a live playlist must keep three target durations (18 s).
        _ = try presentation.window.slide(playheadIndex: 9, budgetCutIndex: nil, now: 0)
        for directory in ["", "audio0", "subs0"] {
            let listed = try presentation.playlist(directory).segments.compactMap(\.duration).reduce(0, +)
            #expect(listed >= 18 - 0.001, "\(directory): \(listed)")
            #expect(listed < 24, "\(directory): \(listed)")
        }

        // The budget may cut deeper than the time window — never into the
        // segment AVPlayer fetched last.
        let budgeted = try Presentation(seconds: 1_000)
        for _ in 0..<10 { try budgeted.cut(6) }
        let retired = try #require(try budgeted.window.slide(playheadIndex: 3, budgetCutIndex: 8, now: 0))
        #expect(retired.videoIndexes == [0, 1, 2])
        #expect(try budgeted.playlist().segments.first?.uri == "seg00003.m4s")
    }

    @Test("Nothing moves before the first fetch, or for a playhead that is not listed")
    func noPlayheadNoSlide() throws {
        let presentation = try Presentation(seconds: 0)
        for _ in 0..<20 { try presentation.cut(2) }
        #expect(try presentation.window.slide(playheadIndex: nil, budgetCutIndex: 15, now: 0) == nil)
        #expect(try presentation.window.slide(playheadIndex: 99, budgetCutIndex: nil, now: 0) == nil)
        #expect(try presentation.playlist().mediaSequence == 0)
    }

    @Test("A removed segment is handed back for unlinking only after RFC 8216's grace period")
    func gracePeriodBeforeUnlink() throws {
        let presentation = try Presentation(seconds: 10)
        for _ in 0..<20 { try presentation.cut(2) }   // 40 s listed, the longest so far
        let retired = try #require(try presentation.window.slide(playheadIndex: 19, budgetCutIndex: nil, now: 100))
        #expect(retired.videoIndexes == Array(0..<14))
        // Segment duration (2 s) plus the longest playlist that held it (40 s).
        #expect(presentation.window.takeDue(now: 100).isEmpty)
        #expect(presentation.window.takeDue(now: 141.9).isEmpty)
        #expect(presentation.window.pendingCount == 1)
        let due = presentation.window.takeDue(now: 142)
        #expect(due == [retired])
        // The WebVTT segments go with their media, not just `.m4s`.
        #expect(due.first?.renditionFiles.contains { $0.lastPathComponent == "seg00013.vtt" } == true)
        #expect(presentation.window.takeDue(now: 1_000).isEmpty)
    }

    @Test("EOF closes whatever window is left with ENDLIST, still without a type")
    func endOfSourceEndsTheWindow() throws {
        let presentation = try Presentation(seconds: 4)
        for _ in 0..<12 { try presentation.cut(2) }
        _ = try presentation.window.slide(playheadIndex: 11, budgetCutIndex: nil, now: 0)
        try presentation.video.finish()
        try presentation.audio.finish()
        try presentation.subtitles.finish()
        for directory in ["", "audio0", "subs0"] {
            let playlist = try presentation.playlist(directory)
            #expect(playlist.isEnded)
            #expect(playlist.mediaSequence > 0)
            #expect(try !presentation.text(directory).contains("PLAYLIST-TYPE"))
        }
    }

    @Test("Retention stops counting what the window dropped")
    func retentionForgets() {
        var retention = SegmentRetention(budgetBytes: 1_000, keepWindow: 0)
        _ = retention.record(index: 0, bytes: 400, producing: 0)
        _ = retention.record(index: 1, bytes: 400, producing: 1)
        retention.forget([0, 7])
        #expect(retention.totalBytes == 400)
        #expect(retention.record(index: 2, bytes: 400, producing: 2).isEmpty)
    }
}
