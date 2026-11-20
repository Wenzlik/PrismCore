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
    }

    /// P1.3: fonts a script embeds in `[Fonts]` are charged to the same
    /// budget as attachments, and skipped when they do not fit.
    @Test func embeddedScriptFontsShareTheAttachmentBudget() throws {
        // libass's uuencoding alphabet is `!`…`` ` ``: 4 chars → 3 bytes.
        let line = String(repeating: "!", count: 80)
        let fonts = "[Fonts]\nfontname: embedded_0.ttf\n" + Array(repeating: line, count: 50).joined(separator: "\n") + "\n"
        let script = Self.header.replacingOccurrences(of: "[Events]", with: fonts + "\n[Events]")
            + "\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,x\n"
        #expect(LibassLibrary.embeddedFontBytes(in: Data(script.utf8)) == 3_000)
        #expect(LibassLibrary.embeddedFontBytes(in: Data(Self.header.utf8)) == 0)

        let roomy = try LibassLibrary(fontBudget: 10_000)
        _ = try ASSSubtitleRenderer(script: Data(script.utf8), library: roomy, storageSize: nil)
        #expect(roomy.loadedFontBytes == 3_000)

        // Attachments first, then a header whose fonts no longer fit.
        let tight = try LibassLibrary(fontBudget: 4_000)
        #expect(tight.addFont(name: "attached.ttf", bytes: Data(repeating: 1, count: 2_000)))
        let renderer = try ASSSubtitleRenderer(header: Data(script.utf8), library: tight, storageSize: nil)
        #expect(tight.loadedFontBytes == 2_000, "the embedded set would exceed the budget and must be skipped")
        // Parsing still happened: styles and events are there.
        renderer.appendEvent(Data("0,0,Default,,0,0,0,,still renders".utf8), start: 0, duration: 2)
        #expect(images(renderer.frame(at: 1, canvas: canvas))?.isEmpty == false)
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
