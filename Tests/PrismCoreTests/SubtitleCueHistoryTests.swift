import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import PrismCore

/// `SubtitleCueHistory.bounded`: the cue tap's replay history is capped by
/// count and by UTF-8 bytes (text plus dedup key), each cue leaving with its
/// key, while live delivery stays whole. The default `.complete` is covered by
/// the unchanged `SubtitleRenditionTests` cue-tap and delay tests.
@Suite("Subtitle cue history", .serialized)
struct SubtitleCueHistoryTests {

    private final class CueBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TimedTextCue] = []
        var cues: [TimedTextCue] { lock.withLock { stored } }
        func append(_ cue: TimedTextCue) { lock.withLock { stored.append(cue) } }
    }

    private func set(_ history: SubtitleCueHistory) -> SubtitleRenditionSet {
        SubtitleRenditionSet(
            outputDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("cue-history-\(UUID().uuidString)", isDirectory: true),
            cueHistory: history
        )
    }

    /// One unique cue per second of source time.
    private func cue(_ index: Int, text: String? = nil) -> SubtitleCue {
        SubtitleCue(start: Double(index), end: Double(index) + 0.5, text: text ?? "line \(index)")
    }

    /// What the history charges a cue: its key and its text, as UTF-8. Spelled
    /// out here rather than read from the engine, so the test pins the format.
    private func cost(stream: Int32 = 0, _ cue: SubtitleCue) -> Int {
        "\(stream)|\(cue.start)|\(cue.end)|\(cue.text)".utf8.count + cue.text.utf8.count
    }

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// Follow a master to its variant and wait for `EXT-X-ENDLIST`, as the
    /// other subtitle suites do.
    private func waitForFinishedPlaylist(_ playlistURL: URL, timeout: Duration = .seconds(30)) async throws {
        var mediaURL = playlistURL
        let (firstData, _) = try await URLSession.uncached.data(from: playlistURL)
        let first = String(decoding: firstData, as: UTF8.self)
        if first.contains("#EXT-X-STREAM-INF") {
            let variant = try #require(PrismCoreSession.playlistURIs(inMaster: first).last)
            mediaURL = playlistURL.deletingLastPathComponent().appendingPathComponent(variant)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let (data, _) = try await URLSession.uncached.data(from: mediaURL)
            if String(decoding: data, as: UTF8.self).contains("#EXT-X-ENDLIST") { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw PrismCoreSession.SessionError.startupTimedOut(underlying: nil)
    }

    // MARK: - The bound itself

    @Test("Thousands of cues: every one delivered live, only the newest retained")
    func countBoundKeepsNewestAndDeliversAll() {
        let renditions = set(.bounded(maxCues: 50, maxBytes: 1 << 20))
        renditions.setTimelineOrigin(seconds: 0)
        let live = CueBox()
        renditions.setCueHandler { live.append($0) }
        for index in 0..<5_000 { renditions.emitHostCue(streamIndex: 0, cue(index)) }

        #expect(live.cues.count == 5_000, "the bound limits the replay, never live delivery")
        let stats = renditions.historyStats
        #expect(stats.retainedCues == 50)
        #expect(stats.evictedCues == 4_950)
        #expect(stats.droppedBeforeOrigin == 0)
        #expect(stats.retainedBytes == (4_950..<5_000).map { cost(cue($0)) }.reduce(0, +))

        let late = CueBox()
        renditions.setCueHandler { late.append($0) }
        #expect(late.cues.map(\.text) == (4_950..<5_000).map { "line \($0)" })
    }

    @Test("The byte bound counts text and key as UTF-8, multibyte characters included")
    func byteBoundCountsKeysAndMultibyteText() {
        // 2 + 2 + 4 bytes per character class: the bound must see bytes, not
        // characters, or a Czech or emoji-heavy track would run past it.
        let text = "Žluťoučký kůň 😀"
        #expect(text.utf8.count > text.count)
        let one = cost(cue(0, text: text))
        // Room for exactly two of these cues (all the same length: indices
        // 0…9 print as one digit), not three.
        let renditions = set(.bounded(maxCues: 1_000, maxBytes: 2 * one + one - 1))
        renditions.setTimelineOrigin(seconds: 0)
        let live = CueBox()
        renditions.setCueHandler { live.append($0) }
        for index in 0..<10 { renditions.emitHostCue(streamIndex: 0, cue(index, text: text)) }

        #expect(live.cues.count == 10)
        let stats = renditions.historyStats
        #expect(stats.retainedCues == 2)
        #expect(stats.retainedBytes == 2 * one)
        #expect(stats.evictedCues == 8)
        // Charging text alone would have fit more than twice as many.
        #expect(text.utf8.count * 5 <= 2 * one + one - 1)

        let late = CueBox()
        renditions.setCueHandler { late.append($0) }
        #expect(late.cues.map(\.start) == [8, 9])
    }

    @Test("An evicted cue's text and key are released at eviction, not at the next compaction")
    func evictionReleasesThePayloadBeforeCompaction() {
        // Five equal-cost cues under room for four: the fifth evicts the
        // first, and one dead slot against three live ones is too little to
        // compact — the slot must still let go of its text and key.
        let texts = (0..<5).map { String(repeating: Character(String($0)), count: 100) }
        let one = cost(cue(0, text: texts[0]))
        let renditions = set(.bounded(maxCues: 4, maxBytes: 4 * one))
        renditions.setTimelineOrigin(seconds: 0)
        for index in 0..<5 { renditions.emitHostCue(streamIndex: 0, cue(index, text: texts[index])) }

        let stats = renditions.historyStats
        #expect(stats.retainedCues == 4)
        #expect(stats.retainedBytes == 4 * one)
        let held = renditions.heldHistoryForTesting
        #expect(held.cues == stats.retainedCues)
        #expect(held.bytes == stats.retainedBytes)
    }

    @Test("Dedup is the retained window: an evicted cue re-demuxed after a seek back arrives again")
    func evictedCueIsRedeliveredAfterSeekBack() {
        let renditions = set(.bounded(maxCues: 3, maxBytes: 1 << 20))
        renditions.setTimelineOrigin(seconds: 0)
        let live = CueBox()
        renditions.setCueHandler { live.append($0) }
        for index in 0..<10 { renditions.emitHostCue(streamIndex: 0, cue(index)) }
        #expect(live.cues.count == 10)

        // A re-demux of a region still retained is deduplicated…
        renditions.emitHostCue(streamIndex: 0, cue(9))
        #expect(live.cues.count == 10)
        // …one whose cues were evicted is delivered again: cue and key left
        // together, so the key is gone too.
        renditions.emitHostCue(streamIndex: 0, cue(0))
        #expect(live.cues.count == 11)
        #expect(live.cues.last?.text == "line 0")
        // And it is history again, evicting the oldest retained cue (7).
        let late = CueBox()
        renditions.setCueHandler { late.append($0) }
        #expect(late.cues.map(\.text) == ["line 8", "line 9", "line 0"])
        #expect(renditions.historyStats.retainedCues == 3)
    }

    @Test("A replay after a delay change carries the delay in force now, over the retained window")
    func boundedReplayTakesTheCurrentDelay() {
        let renditions = set(.bounded(maxCues: 2, maxBytes: 1 << 20))
        renditions.setTimelineOrigin(seconds: 10)
        for index in 10..<15 { renditions.emitHostCue(streamIndex: 0, cue(index)) }

        renditions.setDelay(1.5)
        let shifted = CueBox()
        renditions.setCueHandler { shifted.append($0) }
        // Source 13 and 14, origin 10, delay +1.5 — stored unshifted, shifted
        // at replay.
        #expect(shifted.cues.map(\.start) == [4.5, 5.5])
        #expect(shifted.cues.map(\.end) == [5.0, 6.0])

        // Pulled back past zero: the start clamps, the cue survives.
        renditions.setDelay(-3.25)
        let pulled = CueBox()
        renditions.setCueHandler { pulled.append($0) }
        #expect(pulled.cues.map(\.start) == [0, 0.75])
        #expect(pulled.cues.map(\.end) == [0.25, 1.25])
    }

    @Test("A cue larger than the byte bound is delivered live and never retained")
    func oversizedCueIsLiveOnly() {
        let renditions = set(.bounded(maxCues: 10, maxBytes: 256))
        renditions.setTimelineOrigin(seconds: 0)
        let live = CueBox()
        renditions.setCueHandler { live.append($0) }
        renditions.emitHostCue(streamIndex: 0, cue(0))
        renditions.emitHostCue(streamIndex: 0, cue(1, text: String(repeating: "ř", count: 500)))
        renditions.emitHostCue(streamIndex: 0, cue(2))

        #expect(live.cues.count == 3)
        let stats = renditions.historyStats
        // It evicted nothing to make room it could not use.
        #expect(stats.retainedCues == 2)
        #expect(stats.evictedCues == 1)
        let late = CueBox()
        renditions.setCueHandler { late.append($0) }
        #expect(late.cues.map(\.text) == ["line 0", "line 2"])
    }

    @Test("The pre-origin queue is bounded too, and what it drops is counted")
    func preOriginQueueIsBoundedAndReported() {
        let renditions = set(.bounded(maxCues: 4, maxBytes: 1 << 20))
        let live = CueBox()
        renditions.setCueHandler { live.append($0) }
        for index in 0..<10 { renditions.emitHostCue(streamIndex: 0, cue(index)) }
        // Too large for the queue as well: with no origin it cannot go live.
        renditions.emitHostCue(streamIndex: 0, cue(10, text: String(repeating: "x", count: 1 << 20)))
        #expect(live.cues.isEmpty, "nothing reaches the host before the origin")
        #expect(renditions.historyStats.droppedBeforeOrigin == 7)
        #expect(renditions.historyStats.retainedCues == 0)

        renditions.setTimelineOrigin(seconds: 0)
        #expect(live.cues.map(\.text) == (6..<10).map { "line \($0)" })
        let stats = renditions.historyStats
        #expect(stats.retainedCues == 4)
        #expect(stats.evictedCues == 0)
        #expect(stats.droppedBeforeOrigin == 7)
    }

    @Test("Complete history keeps everything and reports no evictions")
    func completeHistoryIsUnbounded() {
        let renditions = set(.complete)
        renditions.setTimelineOrigin(seconds: 0)
        for index in 0..<2_000 { renditions.emitHostCue(streamIndex: 0, cue(index)) }
        let stats = renditions.historyStats
        #expect(stats.retainedCues == 2_000)
        #expect(stats.retainedBytes == (0..<2_000).map { cost(cue($0)) }.reduce(0, +))
        #expect(stats.evictedCues == 0)
        #expect(stats.droppedBeforeOrigin == 0)
    }

    @Test("Nonsensical bounds are clamped to one, not trapped on")
    func boundsAreClamped() {
        #expect(SubtitleCueHistory.bounded(maxCues: 0, maxBytes: -5).normalized == .bounded(maxCues: 1, maxBytes: 1))
        #expect(SubtitleCueHistory.complete.normalized == .complete)
        // maxBytes 1 is a working "no history": every cue is live-only.
        let renditions = set(.bounded(maxCues: 0, maxBytes: 0))
        renditions.setTimelineOrigin(seconds: 0)
        let live = CueBox()
        renditions.setCueHandler { live.append($0) }
        for index in 0..<3 { renditions.emitHostCue(streamIndex: 0, cue(index)) }
        #expect(live.cues.count == 3)
        #expect(renditions.historyStats.retainedCues == 0)
        #expect(renditions.historyStats.evictedCues == 3)
    }

    // MARK: - Through a real remux

    @Test("A bounded session delivers every embedded cue live and replays only the retained window")
    func boundedSessionReplaysRetainedWindow() async throws {
        let session = try PrismCoreSession(
            url: try fixture("h264_aac_srt.mkv"),
            subtitleCueHistory: .bounded(maxCues: 2, maxBytes: 1 << 20)
        )
        let live = CueBox()
        await session.setTimedTextCueHandler { live.append($0) }
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        try await waitForFinishedPlaylist(playlist)

        // The fixture's three SRT cues all arrive live…
        #expect(live.cues.count == 3)
        let stats = session.subtitleCueHistoryStats
        #expect(stats.retainedCues == 2)
        #expect(stats.evictedCues == 1)
        #expect(stats.droppedBeforeOrigin == 0)

        // …and a late handler, after a delay change, gets the newest two with
        // the delay in force now.
        #expect(await session.setSubtitleDelaySeconds(0.5) == .appliesToNewSegments)
        let late = CueBox()
        await session.setTimedTextCueHandler { late.append($0) }
        #expect(late.cues.count == 2)
        #expect(late.cues.first?.text.contains("Ahoj") == false)
        #expect(late.cues.last?.text.contains("Konec") == true)
        let konec = try #require(live.cues.last)
        #expect(late.cues.last?.start == konec.start + 0.5)
        #expect(late.cues.last?.end == konec.end + 0.5)
    }

    @Test("A closed caption larger than the history still reaches the host live")
    func closedCaptionIsDeliveredLiveUnderATinyBound() async throws {
        // hevc_captioned.mkv carries one CC1 pop-on caption ("HI"). With a
        // one-byte bound nothing can be retained; the caption must still go
        // out live, under CC1's synthetic index.
        let session = try PrismCoreSession(
            url: try fixture("hevc_captioned.mkv"),
            subtitleCueHistory: .bounded(maxCues: 1, maxBytes: 1)
        )
        let live = CueBox()
        await session.setTimedTextCueHandler { live.append($0) }
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        try await waitForFinishedPlaylist(playlist)

        let caption = try #require(live.cues.first)
        #expect(caption.streamIndex == -1)
        #expect(caption.text.contains("HI"))
        let stats = session.subtitleCueHistoryStats
        #expect(stats.retainedCues == 0)
        #expect(stats.evictedCues == live.cues.count)

        let late = CueBox()
        await session.setTimedTextCueHandler { late.append($0) }
        #expect(late.cues.isEmpty)
    }

    #if canImport(Vision)
    @Test("OCR'd bitmap cues obey the same bound")
    func ocrCuesAreBounded() throws {
        let renditions = set(.bounded(maxCues: 2, maxBytes: 1 << 20))
        let counter = CueBox()
        let pgs = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in "Hello" }
        )
        renditions.adoptHostOnlyBitmapsForTesting([5: pgs])
        renditions.requestHostOCR(streamIndex: 5)
        renditions.setTimelineOrigin(seconds: 0)
        renditions.setCueHandler { counter.append($0) }

        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        // Five standing compositions, each released at its segment cut.
        for index in 0..<5 {
            let start = Double(index) * 6
            _ = pgs.process([.init(startSeconds: start + 1, endSeconds: nil, image: image)])
            try renditions.flushSegment(start: start, end: start + 6)
        }

        #expect(counter.cues.count == 5)
        #expect(counter.cues.allSatisfy { $0.streamIndex == 5 && $0.text == "Hello" })
        #expect(renditions.historyStats.retainedCues == 2)
        #expect(renditions.historyStats.evictedCues == 3)
        let late = CueBox()
        renditions.setCueHandler { late.append($0) }
        #expect(late.cues.map(\.start) == [19, 25])
    }
    #endif
}
