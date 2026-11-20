import Testing
import Foundation
import CoreGraphics
import CoreMedia
import Libavformat
import Libavcodec
import Libavutil
@testable import PrismCore

/// libass behind `ASSRenderingMode.libass`: a synthetic script rendered to
/// real bitmaps, the change detection, seeks, style override, fonts from
/// bytes, hostile input, and the on/off routing of both playback paths.
@Suite("ASS rendering with libass", .serialized)
struct ASSRenderingTests {

    static let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica Neue,36,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """

    private let canvas = SubtitleCanvas(width: 640, height: 360)

    private func renderer() throws -> ASSSubtitleRenderer {
        let renderer = try ASSSubtitleRenderer(header: Data(Self.header.utf8))
        renderer.appendEvent(Data("0,0,Default,,0,0,0,,Hello {\\c&H0000FF&}world".utf8), start: 1, duration: 2)
        renderer.appendEvent(Data("1,0,Default,,0,0,0,,{\\an8}Top line".utf8), start: 5, duration: 1)
        return renderer
    }

    private func images(_ update: ASSFrameUpdate) -> [SubtitleImage]? {
        if case .frame(let frame) = update { return frame.images }
        return nil
    }

    /// Premultiplied BGRA pixels of one image, for colour checks.
    private func pixels(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        return [UInt8](data)
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    @Test func libassIsLinkedOnThisSlice() {
        #expect(ASSSubtitleRenderer.isAvailable)
    }

    @Test func rendersVisibleBitmapsOnlyWhileAnEventIsUp() throws {
        let renderer = try renderer()
        let shown = try #require(images(renderer.frame(at: 1.5, canvas: canvas)))
        #expect(!shown.isEmpty)
        for image in shown {
            #expect(image.frame.minX >= 0 && image.frame.maxX <= 640 && image.frame.maxY <= 360)
            #expect(image.image.width == Int(image.frame.width))
        }
        // Bottom-centre default style: below the middle of the frame.
        #expect(shown.allSatisfy { $0.frame.minY > 180 })
        let all = shown.flatMap { pixels($0.image) }
        #expect(stride(from: 3, to: all.count, by: 4).contains { all[$0] == 255 }, "some glyph pixel must be opaque")
        // The `\c&H0000FF&` word: some pixel is strongly red and not blue/green.
        #expect(stride(from: 0, to: all.count, by: 4).contains { all[$0 + 2] > 200 && all[$0 + 1] < 60 && all[$0] < 60 })
        // Premultiplied: no colour channel above its alpha.
        #expect(stride(from: 0, to: all.count, by: 4).allSatisfy { all[$0] <= all[$0 + 3] && all[$0 + 1] <= all[$0 + 3] && all[$0 + 2] <= all[$0 + 3] })

        #expect(images(renderer.frame(at: 3.5, canvas: canvas))?.isEmpty == true)
        let top = try #require(images(renderer.frame(at: 5.5, canvas: canvas)))
        #expect(!top.isEmpty && top.allSatisfy { $0.frame.maxY < 180 })
    }

    @Test func unchangedFramesAreNotRecomposited() throws {
        let renderer = try renderer()
        #expect(images(renderer.frame(at: 1.2, canvas: canvas))?.isEmpty == false)
        guard case .unchanged = renderer.frame(at: 1.3, canvas: canvas) else {
            Issue.record("a static line must report .unchanged"); return
        }
        // A new canvas is a new picture even when the events are the same.
        #expect(images(renderer.frame(at: 1.3, canvas: SubtitleCanvas(width: 1280, height: 720)))?.isEmpty == false)
        // Nothing on screen and nothing changing: still `.unchanged`, not work.
        _ = renderer.frame(at: 4, canvas: canvas)
        guard case .unchanged = renderer.frame(at: 4.2, canvas: canvas) else {
            Issue.record("an idle stretch must report .unchanged"); return
        }
    }

    @Test func seeksNeedNoFlushAndReFeedsAreDeduplicated() throws {
        let renderer = try renderer()
        #expect(images(renderer.frame(at: 5.5, canvas: canvas))?.isEmpty == false)
        // Backwards, as after a seek: the earlier event is still held.
        let back = try #require(images(renderer.frame(at: 1.5, canvas: canvas)))
        #expect(!back.isEmpty && back.allSatisfy { $0.frame.minY > 180 })
        // The demux re-reading the region hands the same ReadOrder again.
        renderer.appendEvent(Data("0,0,Default,,0,0,0,,Hello {\\c&H0000FF&}world".utf8), start: 1, duration: 2)
        #expect(renderer.eventCount == 2)
        renderer.removeAllEvents()
        #expect(renderer.eventCount == 0)
        #expect(images(renderer.frame(at: 1.5, canvas: canvas))?.isEmpty == true)
    }

    @Test func styleOverrideScalesFileStylesOnlyWhenAsked() throws {
        func height(_ override: ASSStyleOverride) throws -> CGFloat {
            let renderer = try renderer()
            renderer.setStyleOverride(override)
            let shown = try #require(images(renderer.frame(at: 1.5, canvas: canvas)))
            return shown.map(\.frame.height).max() ?? 0
        }
        let file = try height(.none)
        let doubled = try height(.font(scale: 2))
        #expect(file > 0)
        #expect(doubled > file * 1.5)
    }

    @Test func safeAreaAndLetterboxMoveTheLine() throws {
        let renderer = try renderer()
        let full = try #require(images(renderer.frame(at: 1.5, canvas: canvas))).map(\.frame.maxY).max() ?? 0
        let safe = SubtitleCanvas(width: 640, height: 360, safeAreaInsets: .init(top: 18, left: 32, bottom: 18, right: 32))
        let inset = try #require(images(renderer.frame(at: 1.5, canvas: safe))).map(\.frame.maxY).max() ?? 0
        #expect(inset < full)
        // A 640×360 picture letterboxed into a 640×480 overlay: the line stays on the picture.
        let boxed = SubtitleCanvas(width: 640, height: 480, videoRect: CGRect(x: 0, y: 60, width: 640, height: 360))
        let onPicture = try #require(images(renderer.frame(at: 1.5, canvas: boxed)))
        #expect(onPicture.allSatisfy { $0.frame.maxY <= 420 && $0.frame.minY >= 60 })
    }

    @Test func externalScriptReadsThroughReadMemory() throws {
        let script = Self.header + "\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Soubor\n"
        let renderer = try ASSSubtitleRenderer(script: Data(script.utf8))
        #expect(renderer.eventCount == 1)
        #expect(images(renderer.frame(at: 1.5, canvas: canvas))?.isEmpty == false)
    }

    @Test func cjkFallsBackThroughCoreText() throws {
        let renderer = try ASSSubtitleRenderer(header: Data(Self.header.utf8))
        renderer.appendEvent(Data("0,0,Default,,0,0,0,,字幕のテスト".utf8), start: 0, duration: 5)
        let shown = try #require(images(renderer.frame(at: 1, canvas: canvas)))
        #expect(shown.map(\.frame.width).reduce(0, +) > 100, "CJK glyphs must render, not tofu-collapse to nothing")
    }

    @Test func hostileInputIsHarmless() throws {
        let renderer = try ASSSubtitleRenderer(header: Data([0xFF, 0x00, 0x7B, 0x5C]))
        var generator = SystemRandomNumberGenerator()
        for index in 0..<200 {
            let junk = (0..<Int.random(in: 0..<200, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            renderer.appendEvent(Data(junk), start: Double(index) / 10, duration: 1)
        }
        renderer.appendEvent(Data("x".utf8), start: .nan, duration: 1)
        renderer.appendEvent(Data("x".utf8), start: 1, duration: -1)
        for time in [0, 5, 10, -3, .nan, .infinity] as [Double] {
            _ = renderer.frame(at: time, canvas: canvas)
        }
        #expect(images(renderer.frame(at: 1, canvas: SubtitleCanvas(width: 0, height: 10)))?.isEmpty == true)
        #expect(images(renderer.frame(at: 1, canvas: SubtitleCanvas(width: 100_000, height: 10)))?.isEmpty == true)
        #expect(throws: (any Error).self) { try ASSSubtitleRenderer(script: Data()) }
        // Garbage "fonts" are refused by FreeType, not by a crash.
        _ = try ASSSubtitleRenderer(header: Data(Self.header.utf8), fonts: [SubtitleFont(name: "bad.ttf", data: Data(repeating: 7, count: 1000))])
            .frame(at: 0, canvas: canvas)
    }

    // MARK: - Fix round 2

    /// P1.1: how far back a libass re-anchor reads, from the plan's own
    /// entries. Pure, so the window rule is pinned without a demand seek
    /// (the producer races through any committable fixture before one).
    @Test func subtitlePrerollReachesBackByBitrateWithinPlanEntries() {
        let starts = stride(from: 0.0, through: 120, by: 6).map { $0 }   // 6 s segments
        func entry(_ anchor: Int, _ bitRate: Int64) -> Int {
            HLSRemuxer.subtitlePrerollEntry(anchor: anchor, startSeconds: { starts[$0] }, bitRate: bitRate)
        }
        // 2 Mb/s: 8 MB is 33 s, capped at 30 → five entries back from 60 s.
        #expect(starts[entry(10, 2_000_000)] == 30)
        // 5 Mb/s: 13.4 s → two entries (12 s).
        #expect(starts[entry(10, 5_000_000)] == 48)
        // 80 Mb/s 4K: under one segment — no preroll, the old seek.
        #expect(entry(10, 80_000_000) == 10)
        // Unknown bitrate: 10 s → one entry. Never before the first.
        #expect(starts[entry(10, 0)] == 54)
        #expect(entry(1, 1_000) == 0)
        #expect(entry(0, 1_000) == 0)
        // r3 P1.1: an indexed event start reaches back whatever the bitrate —
        // 4K at 80 Mb/s, sign indexed at 35 s → the entry at or before it.
        func indexed(_ anchor: Int, _ bitRate: Int64, _ start: Double) -> Int {
            HLSRemuxer.subtitlePrerollEntry(anchor: anchor, startSeconds: { starts[$0] },
                                            bitRate: bitRate, indexedStart: start)
        }
        #expect(starts[indexed(10, 80_000_000, 35)] == 30)
        #expect(starts[indexed(10, 80_000_000, 36)] == 36)
        // The blind window still wins when it reaches further.
        #expect(starts[indexed(10, 2_000_000, 50)] == 30)
        // An "event" at or after the anchor adds nothing.
        #expect(indexed(10, 80_000_000, 60) == 10)
    }

    /// r3 P1.1: the Cue walk finds the EARLIEST indexed event in the window
    /// — FFmpeg's own backtrack stops at the latest one (58 s here).
    @Test func indexedPrerollFindsTheEarliestOverlappingEvent() throws {
        let probed = try SourceProbe.open(url: try fixture("h264_aac_ass_overlap_80s.mkv"))
        let input = try #require(probed.consumeContext())
        let tracks = try #require(ASSTrackSet(input: input))
        // Matroska parses Cues on the first seek, not at open: until then
        // the subtitle index is empty.
        #expect(tracks.earliestIndexedEventStart(in: input, before: 60) == nil)
        #expect(avformat_seek_file(input, -1, Int64.min, 60 * Int64(AV_TIME_BASE), Int64.max, 0) >= 0)
        #expect(tracks.earliestIndexedEventStart(in: input, before: 60) == 50)
        #expect(tracks.earliestIndexedEventStart(in: input, before: 45) == nil)
        // At 4K bitrates the blind window is under a second; the index still reaches 50 s.
        input.pointee.bit_rate = 80_000_000
        #expect(tracks.prerollStart(in: input, before: 60) == 50)
        input.pointee.bit_rate = 0
        #expect(tracks.prerollStart(in: input, before: 45) == 35)   // blind 10 s, nothing indexed
        var closing: UnsafeMutablePointer<AVFormatContext>? = input
        avformat_close_input(&closing)
    }

    /// Both events of the overlap fixture on screen at once: the sign at the
    /// bottom and the short line at the top.
    private func showsBothOverlapEvents(_ renderer: ASSSubtitleRenderer, at time: Double) -> Bool {
        guard let shown = images(renderer.frame(at: time, canvas: canvas)) else { return false }
        return shown.contains { $0.frame.minY > 180 } && shown.contains { $0.frame.maxY < 180 }
    }

    /// r3 P1.1, software path: `load(startAt:)` and `seek(to:)` into a region
    /// never read still show the sign that started 8–10 s earlier.
    @Test func softwareSeekIntoUnreadRegionPrerollsRunningEvents() throws {
        let url = try fixture("h264_aac_ass_overlap_80s.mkv")
        let started = SoftwarePlaybackPipeline(videoSink: RecordingVideoSink(), audioSink: RecordingAudioSink(),
                                               timeline: RecordingTimeline(), allowHardwareDecode: false)
        started.setASSRendering(.libass)
        try started.load(probed: SourceProbe.open(url: url), startAt: CMTime(seconds: 58.5, preferredTimescale: 1_000))
        defer { started.stop() }
        started.waitForFeedQueue()
        let first = try #require(started.assRenderer(streamIndex: 2))
        #expect(showsBothOverlapEvents(first, at: 58.7))

        let seeking = SoftwarePlaybackPipeline(videoSink: RecordingVideoSink(), audioSink: RecordingAudioSink(),
                                               timeline: RecordingTimeline(), allowHardwareDecode: false)
        seeking.setASSRendering(.libass)
        try seeking.load(probed: SourceProbe.open(url: url))
        defer { seeking.stop() }
        seeking.waitForFeedQueue()
        let renderer = try #require(seeking.assRenderer(streamIndex: 2))
        #expect(renderer.eventCount == 0, "the head of the file has no events; nothing near 50 s was read yet")
        seeking.seek(to: CMTime(seconds: 58.5, preferredTimescale: 1_000))
        seeking.waitForFeedQueue()
        #expect(showsBothOverlapEvents(renderer, at: 58.7))
    }

    /// r3 P1.1, remux path: over a slow origin the producer is still near
    /// the head when a demand at ~58 s re-anchors into bytes never read;
    /// the re-anchor's preroll must bring both events in.
    @Test func remuxReanchorIntoUnreadRegionPrerollsRunningEvents() async throws {
        // A fast local play stores the keyframe plan under a host identity;
        // the slow origin then plans from it (cold, its index load would run
        // out of budget and leave no plan to demand from). At ~30 KB/s the
        // 313 KB fixture takes ~10 s to read, so the producer is still far
        // from 50 s when the demand lands right after `start()`.
        let local = try fixture("h264_aac_ass_overlap_80s.mkv")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("prismcore-ass-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        let identity = SourceCacheIdentity(namespace: "ass-tests", item: "overlap", etag: "1")
        let warm = try PrismCoreSession(url: local, keyframeIndexCacheDirectory: cache, keyframeIndexCacheIdentity: identity)
        _ = try await warm.start()
        await warm.stop()
        let server = try RangeFixtureServer(media: try Data(contentsOf: local), bytesPerSecond: 30_000)
        let url = try await server.start()
        defer { server.stop() }
        let session = try PrismCoreSession(url: url, keyframeIndexCacheDirectory: cache,
                                           keyframeIndexCacheIdentity: identity)
        try await session.setASSRendering(.libass)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        var variant = playlist
        let (masterData, _) = try await URLSession.uncached.data(from: playlist)
        let master = String(decoding: masterData, as: UTF8.self)
        if master.contains("#EXT-X-STREAM-INF"), let uri = PrismCoreSession.playlistURIs(inMaster: master).last {
            variant = playlist.deletingLastPathComponent().appendingPathComponent(uri)
        }
        let (variantData, _) = try await URLSession.uncached.data(from: variant)
        var segments: [(uri: String, start: Double, end: Double)] = []
        var clock = 0.0
        var duration: Double?
        for line in String(decoding: variantData, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).split(separator: ",").first ?? "")
            } else if !line.hasPrefix("#"), let length = duration {
                segments.append((String(line), clock, clock + length))
                clock += length
                duration = nil
            }
        }
        let base = variant.deletingLastPathComponent()
        try #require(await session.diagnosticReport().startup.plan?.basis == "keyframeIndex")
        let renderer = try #require(session.assRenderer(streamIndex: 2))
        let produced = session.residentRanges.map(\.endSeconds).max() ?? 0
        try #require(produced < 40, "the producer must not be near the sign's cluster before the re-anchor")
        #expect(renderer.eventCount == 0)

        let target = try #require(segments.first { $0.start <= 58.7 && 58.7 < $0.end },
                                  "\(String(decoding: variantData, as: UTF8.self).prefix(600))")
        let (media, status) = try await URLSession.uncached.data(from: base.appendingPathComponent(target.uri))
        #expect((status as? HTTPURLResponse)?.statusCode == 200 && media.count > 0)
        #expect(renderer.eventCount == 2)
        #expect(showsBothOverlapEvents(renderer, at: 58.7))
    }

    /// P1.3 / r3 P1.2: fonts a script embeds in `[Fonts]` are decoded on our
    /// side, charged to the same budget as attachments, skipped when they do
    /// not fit — and never handed to libass either way. A data line that
    /// begins with `[` (inside the encoding's alphabet) is still data.
    @Test func embeddedScriptFontsShareTheAttachmentBudget() throws {
        // The encoding's alphabet is `!`…`` ` ``: 4 chars → 3 bytes. Lines of
        // `[` are data too; r2's estimate stopped counting at the first one.
        let line = String(repeating: "[", count: 80)
        let fonts = "[Fonts]\nfontname: embedded_0.ttf\n" + Array(repeating: line, count: 50).joined(separator: "\n") + "\n"
        let script = Self.header.replacingOccurrences(of: "[Events]", with: fonts + "\n[Events]")
            + "\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,x\n"

        let roomy = try LibassLibrary(fontBudget: 10_000)
        let stripped = String(decoding: roomy.admittingEmbeddedFonts(of: Data(script.utf8)), as: UTF8.self)
        #expect(roomy.loadedFontBytes == 3_000)
        #expect(!stripped.contains("[Fonts]") && !stripped.contains("[[[[") && !stripped.contains("fontname:"))
        #expect(stripped.contains("[Events]") && stripped.contains("Dialogue:") && stripped.contains("Style: Default"))
        #expect(String(decoding: roomy.admittingEmbeddedFonts(of: Data(Self.header.utf8)), as: UTF8.self) == Self.header)

        // Decoding matches the encoding: three bytes per group, partial tail groups.
        #expect(LibassLibrary.decodeEmbeddedFont(Array("!!!!".utf8)) == [0, 0, 0])
        #expect(LibassLibrary.decodeEmbeddedFont(Array("````".utf8)) == [255, 255, 255])
        #expect(LibassLibrary.decodeEmbeddedFont(Array("````!".utf8)) == nil)
        #expect(LibassLibrary.decodeEmbeddedFont(Array("``!".utf8))?.count == 2)

        // A font larger than what is left is refused before it is buffered whole.
        let small = try LibassLibrary(fontBudget: 1_000)
        _ = small.admittingEmbeddedFonts(of: Data(script.utf8))
        #expect(small.loadedFontBytes == 0)

        let viaRenderer = try LibassLibrary(fontBudget: 10_000)
        _ = try ASSSubtitleRenderer(script: Data(script.utf8), library: viaRenderer, storageSize: nil)
        #expect(viaRenderer.loadedFontBytes == 3_000)

        // r5 P1.2: libass ends lines at CR too. A CR-only or CRLF script must
        // have its `[Fonts]` found here — admitted under the budget, refused
        // over it, never handed to libass — and still parse.
        for ending in ["\r", "\r\n"] {
            let other = script.replacingOccurrences(of: "\n", with: ending)
            let admitted = try LibassLibrary(fontBudget: 10_000)
            let out = String(decoding: admitted.admittingEmbeddedFonts(of: Data(other.utf8)), as: UTF8.self)
            #expect(admitted.loadedFontBytes == 3_000)
            #expect(!out.contains("fontname:") && !out.contains("[[[[") && out.contains("Dialogue:"))
            let refusing = try LibassLibrary(fontBudget: 1_000)
            #expect(try ASSSubtitleRenderer(script: Data(other.utf8), library: refusing, storageSize: nil).eventCount == 1)
            #expect(refusing.loadedFontBytes == 0)
        }
        let bomFirst = try LibassLibrary(fontBudget: 10_000)
        _ = bomFirst.admittingEmbeddedFonts(of: Data([0xEF, 0xBB, 0xBF]) + Data(fonts.utf8))
        #expect(bomFirst.loadedFontBytes == 3_000)

        // Attachments first, then a header whose fonts no longer fit.
        let tight = try LibassLibrary(fontBudget: 4_000)
        #expect(tight.addFont(name: "attached.ttf", bytes: Data(repeating: 1, count: 2_000)))
        let renderer = try ASSSubtitleRenderer(header: Data(script.utf8), library: tight, storageSize: nil)
        #expect(tight.loadedFontBytes == 2_000, "the embedded set would exceed the budget and must be skipped")
        // Parsing still happened: styles and events are there.
        renderer.appendEvent(Data("0,0,Default,,0,0,0,,still renders".utf8), start: 0, duration: 2)
        #expect(images(renderer.frame(at: 1, canvas: canvas))?.isEmpty == false)
    }

    /// r5 P2.7: a track with no CodecPrivate (or one without an `[Events]`
    /// Format) must still accept and draw events, not stay empty for good.
    @Test func headerlessTrackStillAcceptsEvents() throws {
        let library = try LibassLibrary()
        let renderers = [
            try ASSSubtitleRenderer(header: Data()),
            try ASSSubtitleRenderer(header: Data("[Script Info]\nPlayResY: 360\n".utf8)),
            try ASSSubtitleRenderer(header: nil, library: library, storageSize: nil),
        ]
        for renderer in renderers {
            renderer.appendEvent(Data("0,0,Default,,0,0,0,,headerless".utf8), start: 0, duration: 2)
            #expect(renderer.eventCount == 1)
            #expect(images(renderer.frame(at: 1, canvas: canvas))?.isEmpty == false)
        }
    }

    /// P2.4: a clear handed to the host invalidates libass's cached picture;
    /// `invalidate()` does the same for a host that dropped its overlay.
    @Test func aClearOrInvalidateForcesTheNextFrame() throws {
        let renderer = try renderer()
        #expect(images(renderer.frame(at: 1.5, canvas: canvas))?.isEmpty == false)
        #expect(images(renderer.frame(at: 1.5, canvas: SubtitleCanvas(width: 0, height: 360)))?.isEmpty == true)
        #expect(images(renderer.frame(at: 1.6, canvas: canvas))?.isEmpty == false,
                "after a clear the same static line must be drawn again, not .unchanged")
        guard case .unchanged = renderer.frame(at: 1.7, canvas: canvas) else {
            Issue.record("nothing changed since the redraw"); return
        }
        renderer.invalidate()
        #expect(images(renderer.frame(at: 1.8, canvas: canvas))?.isEmpty == false)
    }

    /// P2.5: absurd host geometry is clamped or ignored, never a trap.
    @Test func absurdGeometryNeverTraps() throws {
        let huge = try ASSSubtitleRenderer(header: Data(Self.header.utf8),
                                           videoSize: CGSize(width: 3_000_000_000, height: 1080))
        huge.appendEvent(Data("0,0,Default,,0,0,0,,x".utf8), start: 0, duration: 5)
        #expect(images(huge.frame(at: 1, canvas: canvas))?.isEmpty == false)
        let renderer = try renderer()
        for rect in [CGRect(x: 1e12, y: 0, width: 640, height: 360), CGRect(x: 0, y: 0, width: 1e15, height: 1e15),
                     CGRect(x: -1e18, y: -1e18, width: 1, height: 1), CGRect(x: CGFloat.nan, y: 0, width: 640, height: CGFloat.infinity)] {
            _ = renderer.frame(at: 1.5, canvas: SubtitleCanvas(width: 640, height: 360, videoRect: rect))
        }
        _ = renderer.frame(at: 1.5, canvas: SubtitleCanvas(width: 640, height: 360,
                                                           safeAreaInsets: .init(top: Double.nan, left: 1e300, bottom: -1e300, right: 0)))
    }

    @Test func regionsSplitDistantLinesAndMergeNearOnes() {
        typealias R = ASSCompositor.Rect
        func layer(_ rect: R) -> ASSCompositor.Layer {
            ASSCompositor.Layer(rect: rect, bitmap: UnsafePointer(bitPattern: 1)!, stride: 0, skipX: 0, skipY: 0, color: 0)
        }
        let regions = ASSCompositor.regions([
            layer(R(minX: 0, minY: 0, maxX: 10, maxY: 10)),
            layer(R(minX: 0, minY: 300, maxX: 10, maxY: 310)),
            layer(R(minX: 20, minY: 0, maxX: 30, maxY: 10)),        // within 16 px of the first
            layer(R(minX: 0, minY: 12, maxX: 40, maxY: 20)),
        ])
        #expect(regions.count == 2)
        #expect(regions.contains { $0.members == [0, 2, 3] && $0.rect == R(minX: 0, minY: 0, maxX: 40, maxY: 20) })
        #expect(regions.contains { $0.members == [1] })
        #expect(ASSCompositor.mul255(255, 255) == 255 && ASSCompositor.mul255(128, 255) == 128 && ASSCompositor.mul255(0, 200) == 0)
    }

    // MARK: - Fonts from container attachments

    @Test func attachmentsBecomeMemoryFontsAndASSStreamsGetRenderers() throws {
        let fontURL = URL(fileURLWithPath: "/System/Library/Fonts/Geneva.ttf")
        let font = try #require(try? Data(contentsOf: fontURL), "needs a system TrueType font to stand in for an attachment")
        let context = avformat_alloc_context()
        defer { avformat_free_context(context) }
        let input = try #require(context)

        func addStream(_ type: AVMediaType, _ codec: AVCodecID, extradata: Data, metadata: [String: String] = [:]) {
            let stream = avformat_new_stream(input, nil)!
            stream.pointee.codecpar.pointee.codec_type = type
            stream.pointee.codecpar.pointee.codec_id = codec
            stream.pointee.time_base = AVRational(num: 1, den: 1000)
            let buffer = av_mallocz(extradata.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!.assumingMemoryBound(to: UInt8.self)
            extradata.copyBytes(to: buffer, count: extradata.count)
            stream.pointee.codecpar.pointee.extradata = buffer
            stream.pointee.codecpar.pointee.extradata_size = Int32(extradata.count)
            for (key, value) in metadata { av_dict_set(&stream.pointee.metadata, key, value, 0) }
        }
        addStream(AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_SUBRIP, extradata: Data())
        addStream(AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_ASS, extradata: Data(Self.header.utf8))
        addStream(AVMEDIA_TYPE_ATTACHMENT, AV_CODEC_ID_NONE, extradata: font,
                  metadata: ["filename": "Geneva.ttf", "mimetype": "application/x-truetype-font"])
        addStream(AVMEDIA_TYPE_ATTACHMENT, AV_CODEC_ID_NONE, extradata: Data("not a font".utf8),
                  metadata: ["filename": "cover.jpg", "mimetype": "image/jpeg"])

        let set = try #require(ASSTrackSet(input: input))
        #expect(set.fontCount == 1)
        #expect(set.streamIndices == [1])
        #expect(set.renderer(streamIndex: 0) == nil)
        let renderer = try #require(set.renderer(streamIndex: 1))
        renderer.appendEvent(Data("0,0,Default,,0,0,0,,{\\fnGeneva}Font from the container".utf8), start: 0, duration: 2)
        #expect(images(renderer.frame(at: 1, canvas: canvas))?.isEmpty == false)
    }

    @Test func fontMemoryIsBudgetedAcrossTheWholeSet() throws {
        let library = try LibassLibrary(fontBudget: 2_500)
        let font = Data(repeating: 1, count: 1_000)
        #expect(library.addFont(name: "a.ttf", bytes: font))
        #expect(library.addFont(name: "b.ttf", bytes: font))
        #expect(!library.addFont(name: "c.ttf", bytes: font), "the third would take the set past its budget")
        #expect(library.addFont(name: "small.ttf", bytes: Data(repeating: 1, count: 400)), "what still fits is taken")
        #expect(library.loadedFontBytes == 2_400)
        #expect(!library.addFont(name: "empty.ttf", bytes: Data()))
        // The per-file cap still applies under a generous budget.
        let roomy = try LibassLibrary(fontBudget: .max)
        #expect(!roomy.addFont(name: "huge.ttf", bytes: Data(count: LibassLibrary.maximumFontBytes + 1)))
        #expect(LibassLibrary.maximumFontSetBytes >= LibassLibrary.maximumFontBytes)
    }

    // MARK: - Routing: off by default, on when asked

    private final class CueCollector: @unchecked Sendable {
        // Safety: `stored` is only touched under `lock`.
        private let lock = NSLock()
        private var stored: [TimedTextCue] = []
        func append(_ cue: TimedTextCue) { lock.withLock { stored.append(cue) } }
        var cues: [TimedTextCue] { lock.withLock { stored } }
    }

    private func waitForCues(_ collector: CueCollector, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while collector.cues.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func remuxSessionRoutesLibassOnlyWhenAsked() async throws {
        let url = try fixture("h264_aac_ass.mkv")
        let info = try SourceProbe.probe(url: url)
        #expect(info.subtitleTracks.map(\.isASS) == [true])

        let plain = try PrismCoreSession(url: url)
        _ = try await plain.start()
        #expect(plain.assRenderer(streamIndex: 2) == nil, "default .text must build no renderer")
        await plain.stop()

        let session = try PrismCoreSession(url: url)
        try await session.setASSRendering(.libass)
        let collector = CueCollector()
        await session.setTimedTextCueHandler { collector.append($0) }
        _ = try await session.start()
        defer { Task { await session.stop() } }
        await #expect(throws: PrismCoreSession.SessionError.self) { try await session.setASSRendering(.text) }
        try await waitForCues(collector, count: 2)

        // The text path keeps flowing, now with styled runs.
        let cues = collector.cues.sorted { $0.start < $1.start }
        #expect(cues.map(\.text) == ["Ahoj <i>světe</i>", "Nápis"])
        #expect(cues[0].styled?.runs.last?.isItalic == true)
        #expect(cues[1].styled?.runs.first?.color == SubtitleColor(red: 255, green: 0, blue: 0))
        #expect(cues[1].styled?.runs.first?.isBold == true, "the Sign style is bold")
        #expect(cues[1].styled?.placement == TextCuePlacement(alignment: 8))
        #expect(cues[1].placement == nil, "TimedTextCue.placement still never reads styles")

        let renderer = try #require(session.assRenderer(streamIndex: 2))
        #expect(session.assRenderer(streamIndex: 0) == nil)
        // Cue timeline: the frame at a cue's own start..end shows it.
        let midFirst = (cues[0].start + cues[0].end) / 2
        #expect(images(renderer.frame(at: midFirst, canvas: canvas))?.isEmpty == false)
        let gap = (cues[0].end + cues[1].start) / 2
        #expect(images(renderer.frame(at: gap, canvas: canvas))?.isEmpty == true)
        let sign = try #require(images(renderer.frame(at: (cues[1].start + cues[1].end) / 2, canvas: canvas)))
        #expect(!sign.isEmpty && sign.allSatisfy { $0.frame.maxY < 180 }, "the Sign style is top-aligned")
    }

    @Test func softwarePipelineRoutesLibassOnlyWhenAsked() throws {
        let url = try fixture("h264_aac_ass.mkv")
        for mode in [ASSRenderingMode.text, .libass] {
            let pipeline = SoftwarePlaybackPipeline(videoSink: RecordingVideoSink(), audioSink: RecordingAudioSink(),
                                                    timeline: RecordingTimeline(), allowHardwareDecode: false)
            pipeline.setASSRendering(mode)
            try pipeline.load(probed: SourceProbe.open(url: url))
            defer { pipeline.stop() }
            pipeline.waitForFeedQueue()
            guard mode == .libass else {
                #expect(pipeline.assRenderer(streamIndex: 2) == nil)
                continue
            }
            let renderer = try #require(pipeline.assRenderer(streamIndex: 2))
            // The demux reads ahead of the paused clock; wait for the first event.
            let deadline = Date().addingTimeInterval(10)
            while renderer.eventCount == 0, Date() < deadline { pipeline.waitForFeedQueue(); usleep(50_000) }
            #expect(renderer.eventCount >= 1)
            #expect(images(renderer.frame(at: 1.0, canvas: canvas))?.isEmpty == false)
        }
    }
}
