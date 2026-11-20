import Testing
import Foundation
@testable import PrismCore

/// The styled-run cue model: what each source's markup turns into, and that
/// the WebVTT text every existing host reads did not move. Pure values.
@Suite("Styled subtitle text")
struct StyledSubtitleTextTests {

    private let red = SubtitleColor(red: 255, green: 0, blue: 0)
    private let white = SubtitleColor(red: 255, green: 255, blue: 255)

    private func styled(_ payload: String, _ kind: TextSubtitleConverter.Kind = .subrip,
                        header: String? = nil) -> StyledSubtitleText? {
        let parsed = header.map { ASSScriptHeader(text: $0) }
        return TextSubtitleConverter.convert(Data(payload.utf8), kind: kind,
                                             playResolution: parsed?.playResolution, assHeader: parsed)?.styled
    }

    @Test func srtTagsAndFontColorBecomeRuns() throws {
        let text = try #require(styled("<i>Ahoj</i> <font color=\"#ff0000\" face=\"Arial\">světe</font>"))
        #expect(text.runs.map(\.text) == ["Ahoj", " ", "světe"])
        #expect(text.runs[0].isItalic && !text.runs[1].isItalic)
        #expect(text.runs[2].color == red)
        #expect(text.runs[2].fontName == "Arial")
        #expect(text.plainText == "Ahoj světe")
        // The string every existing host reads is byte for byte what it was.
        #expect(TextSubtitleConverter.convert(Data("<i>Ahoj</i> <font color=\"#ff0000\">světe</font>".utf8),
                                              kind: .subrip, playResolution: nil)?.text == "<i>Ahoj</i> světe")
    }

    @Test func assOverridesColoursFontsAndDrawings() throws {
        let text = try #require(styled("0,0,Default,,0,0,0,,{\\c&H0000FF&\\3c&HFF0000&}red{\\r} {\\fnComic\\b1}bold{\\p1}m 0 0 l 10 0{\\p0}!", .ass))
        #expect(text.plainText == "red bold!")
        #expect(text.runs[0].color == red)
        #expect(text.runs[0].outlineColor == SubtitleColor(red: 0, green: 0, blue: 255))
        let bold = try #require(text.runs.first { $0.text.contains("bold") })
        #expect(bold.isBold && bold.fontName == "Comic" && bold.color == nil)
        // A `\t` animation's target is not the starting colour.
        #expect(styled("{\\c&H0000FF&\\t(0,500,\\c&HFF0000&\\fscx120)\\i1}x")?.runs.first
                == StyledTextRun(text: "x", isItalic: true, color: red))
        #expect(styled("<font bgcolor=\"#00ff00\" color=\"#ff0000\">x</font>")?.runs.first?.color == red)
        // `\bord`, `\blur`, `\shad` and `\clip` are not emphasis or colour.
        #expect(styled("{\\bord2\\blur3\\shad1\\clip(0,0,1,1)}x", .subrip)?.runs == [StyledTextRun(text: "x")])
    }

    @Test func assAlphaIsInvertedAndHeaderStylesAreTheBase() throws {
        let header = """
        [Script Info]
        PlayResX: 640
        PlayResY: 360
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, Bold, Italic, Alignment
        Style: Default,Helvetica Neue,36,&H00FFFFFF,&H00000000,0,0,2
        Style: Sign,Gill Sans,30,&H8000FFFF,&H00000000,-1,0,8
        """
        let sign = try #require(styled("1,0,Sign,,0,0,0,,Nápis {\\rDefault}dole", .ass, header: header))
        #expect(sign.runs[0].color == SubtitleColor(red: 255, green: 255, blue: 0, alpha: 127))
        #expect(sign.runs[0].isBold && sign.runs[0].fontName == "Gill Sans")
        #expect(sign.runs[1].color == white && !sign.runs[1].isBold)
        // The style's own alignment is a placement here (TimedTextCue.placement
        // never read styles, and still does not).
        #expect(sign.placement == TextCuePlacement(alignment: 8))
        let positioned = try #require(styled("1,0,Default,,0,0,0,,{\\an7\\pos(320,180)}x", .ass, header: header))
        #expect(positioned.placement == TextCuePlacement(alignment: 7, anchor: .init(x: 0.5, y: 0.5)))
        #expect(styled("1,0,Default,,0,0,0,,{\\alpha&HFF&}gone", .ass, header: header)?.runs.first?.color?.alpha == 0)
    }

    @Test func resetFindsNamedStylesLikeLibass() throws {
        let header = """
        [V4+ Styles]
        Format: Name, Fontname, PrimaryColour, Bold
        Style: Default,Helvetica Neue,&H00FFFFFF,0
        Style: Sign,Gill Sans,&H0000FFFF,-1
        """
        // `*`-prefixed and space-separated names reach Default, not the event's Sign.
        for reset in ["\\r*Default", "\\r Default", "\\rDefault"] {
            let text = try #require(styled("1,0,Sign,,0,0,0,,{\\c&H0000FF&}x{\(reset)}y", .ass, header: header))
            let y = try #require(text.runs.last)
            #expect(y.text == "y" && y.color == white && !y.isBold && y.fontName == "Helvetica Neue", "\(reset)")
        }
        // An unknown name resets to the event's own style (libass), not to Default.
        let unknown = try #require(styled("1,0,Sign,,0,0,0,,{\\c&H0000FF&}x{\\rNope}y", .ass, header: header))
        #expect(unknown.runs.last?.isBold == true && unknown.runs.last?.fontName == "Gill Sans")
        #expect(unknown.runs.last?.color == SubtitleColor(red: 255, green: 255, blue: 0))
    }

    @Test func webVTTVoiceClassesEntitiesAndTimestamps() throws {
        let text = try #require(styled("<v.loud Esme>Hi &amp; <c.yellow.bg_black>bye</c><00:00:01.500>!</v>", .webvtt))
        #expect(text.plainText == "Hi & bye!")
        #expect(text.runs.allSatisfy { $0.voice == "Esme" })
        let bye = try #require(text.runs.first { $0.text == "bye" })
        #expect(bye.classes == ["loud", "yellow", "bg_black"])
        #expect(bye.color == SubtitleColor(red: 255, green: 255, blue: 0))
    }

    @Test func unknownMarkupStaysVisible() {
        #expect(styled("I <3 you & {no override} {unclosed")?.plainText == "I <3 you &  {unclosed")
        #expect(styled("line one\\Nline two\n\n\nthree")?.plainText == "line one\nline two\nthree")
        #expect(styled("   ") == nil)
    }

    /// Lines built to hit the old quadratic paths — every unclosed `{` and
    /// stray `<` searched the rest of the line, and leading padding was
    /// trimmed one `removeFirst()` at a time. 40 000 characters each: the
    /// quadratic shapes took tens of seconds here, linear takes well under
    /// one even unoptimized.
    @Test func hostileLinesParseInLinearTime() {
        let length = 40_000
        let hostile = [
            String(repeating: "{", count: length) + "x",
            String(repeating: "<", count: length) + "x>",
            String(repeating: "<a ", count: length / 3) + ">",
            String(repeating: " ", count: length) + "x",
            String(repeating: "{\\i1}", count: length / 5) + "y",
        ]
        let clock = ContinuousClock()
        for line in hostile {
            let started = clock.now
            let parsed = StyledTextParser.parse(line)
            #expect(clock.now - started < .seconds(3), "\(line.prefix(8))… took \(clock.now - started)")
            #expect(!parsed.plainText.isEmpty)
        }
        #expect(StyledTextParser.parse(String(repeating: " ", count: length) + "x").plainText == "x")
    }

    /// r3 P1.3: thousands of nested classed spans with one visible word —
    /// each saved style used to copy every class before it (quadratic
    /// memory). Bounded depth and classes keep it linear and the word intact.
    @Test func deeplyNestedClassedSpansStayBounded() throws {
        let depth = 20_000
        let line = String(repeating: "<c.a.b.c.d>", count: depth) + "word" + String(repeating: "</c>", count: depth)
            + " <i>after</i>"
        let clock = ContinuousClock()
        let started = clock.now
        let parsed = StyledTextParser.parse(line)
        #expect(clock.now - started < .seconds(3))
        #expect(parsed.plainText == "word after")
        let word = try #require(parsed.runs.first)
        #expect(word.classes.count == StyledTextParser.maximumClasses)
        // The spans past the bound closed themselves, so the outer ones did
        // too: the trailing italic run carries no leftover classes.
        #expect(parsed.runs.last == StyledTextRun(text: "after", isItalic: true))
        // Style changes past the bound stop adding runs, not text.
        let flicker = (0..<5_000).map { "<b>\($0 % 10)</b><i>.</i>" }.joined()
        let many = StyledTextParser.parse(flicker)
        #expect(many.runs.count <= StyledTextParser.maximumStyles * 2)
        #expect(many.plainText.count == 10_000)
    }

    private func tx3gSample(_ text: String, records: [(start: Int, end: Int, font: Int, flags: UInt8)]) -> Data {
        let utf8 = Array(text.utf8)
        var sample: [UInt8] = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)] + utf8
        let size = 10 + records.count * 12
        sample += [0, 0, UInt8(size >> 8), UInt8(size & 0xFF)] + Array("styl".utf8)
        sample += [UInt8(records.count >> 8), UInt8(records.count & 0xFF)]
        for record in records {
            sample += [UInt8(record.start >> 8), UInt8(record.start & 0xFF), UInt8(record.end >> 8), UInt8(record.end & 0xFF),
                       UInt8(record.font >> 8), UInt8(record.font & 0xFF), record.flags, 18, 255, 0, 0, 255]
        }
        return Data(sample)
    }

    /// r3 P1.4: overlapping or out-of-order `styl` records void the box
    /// (text kept, default style) — and thousands of them cost nothing.
    @Test func tx3gOverlappingStyleRecordsAreRefused() throws {
        let overlapping = TextSubtitleConverter.movTextStyled(
            tx3gSample("Hello world", records: [(0, 5, 1, 1), (3, 8, 1, 2)]))
        #expect(overlapping?.runs == [StyledTextRun(text: "Hello world")])
        let backwards = TextSubtitleConverter.movTextStyled(
            tx3gSample("Hello world", records: [(6, 11, 1, 1), (0, 5, 1, 1)]))
        #expect(backwards?.runs == [StyledTextRun(text: "Hello world")])
        let ordered = try #require(TextSubtitleConverter.movTextStyled(
            tx3gSample("Hello world", records: [(0, 5, 1, 1), (6, 11, 1, 2)])))
        #expect(ordered.runs.map(\.text) == ["Hello", " ", "world"])
        #expect(ordered.runs.first?.isBold == true && ordered.runs.last?.isItalic == true)

        let long = String(repeating: "x", count: 4_000)
        let hostile = tx3gSample(long, records: Array(repeating: (0, 4_000, 1, 1), count: 5_000))
        let clock = ContinuousClock()
        let started = clock.now
        let parsed = TextSubtitleConverter.movTextStyled(hostile)
        #expect(clock.now - started < .seconds(2))
        #expect(parsed?.plainText == long && parsed?.runs.count == 1 && parsed?.runs.first?.isBold == false)
    }

    /// r3 P2.6: the track's sample description gives every sample its
    /// default style, justification and fonts; a record's font id resolves
    /// through the `ftab`.
    @Test func tx3gSampleDescriptionGivesDefaultsAndFonts() throws {
        func pascal(_ id: Int, _ name: String) -> [UInt8] { [0, UInt8(id), UInt8(name.utf8.count)] + Array(name.utf8) }
        let fonts = pascal(1, "Gill Sans") + pascal(2, "Menlo")
        let ftabSize = 10 + fonts.count
        var description: [UInt8] = [0, 0, 0, 0, 0x00, 0x00]          // display flags; left, top
        description += [0, 0, 0, 0] + [UInt8](repeating: 0, count: 8)  // background, text box
        description += [0, 0, 0, 0, 0, 1, 0x02, 18, 255, 255, 0, 255]  // default: font 1, italic, yellow
        description += [0, 0, UInt8(ftabSize >> 8), UInt8(ftabSize & 0xFF)] + Array("ftab".utf8) + [0, 2] + fonts

        let sample = tx3gSample("Hello world", records: [(0, 5, 2, 1)])
        let text = try #require(SubtitleTextParser.styledText(
            payload: sample, format: .tx3g, tx3gSampleDescription: Data(description)))
        #expect(text.placement == TextCuePlacement(alignment: 7))
        let hello = try #require(text.runs.first)
        #expect(hello.text == "Hello" && hello.isBold && !hello.isItalic && hello.fontName == "Menlo")
        let rest = try #require(text.runs.last)
        #expect(rest.text == " world" && rest.isItalic && rest.fontName == "Gill Sans")
        #expect(rest.color == SubtitleColor(red: 255, green: 255, blue: 0))

        // No styl box at all: the defaults alone.
        let plain = try #require(SubtitleTextParser.styledText(
            payload: tx3gSample("Ahoj", records: []), format: .tx3g, tx3gSampleDescription: Data(description)))
        #expect(plain.runs == [StyledTextRun(text: "Ahoj", isItalic: true, color: SubtitleColor(red: 255, green: 255, blue: 0),
                                             fontName: "Gill Sans")])
        // Bottom-centre (FFmpeg's encoder default) is the host default: no placement.
        var bottom = description
        bottom[4] = 1; bottom[5] = 0xFF
        #expect(TextSubtitleConverter.MovTextDescription(Data(bottom))?.placement == nil)
        #expect(TextSubtitleConverter.MovTextDescription(Data(description.prefix(29))) == nil)
    }

    /// r3 P2.7: classes on any WebVTT tag, not only `c` and `v`.
    @Test func classesOnEmphasisTagsAreKept() throws {
        let text = try #require(styled("<i.yellow>Ahoj</i> <b.loud.red>pozor</b> <u>u</u>", .webvtt))
        let ahoj = try #require(text.runs.first { $0.text == "Ahoj" })
        #expect(ahoj.isItalic && ahoj.classes == ["yellow"] && ahoj.color == SubtitleColor(red: 255, green: 255, blue: 0))
        let pozor = try #require(text.runs.first { $0.text == "pozor" })
        #expect(pozor.isBold && pozor.classes == ["loud", "red"] && pozor.color == red)
        #expect(text.runs.last == StyledTextRun(text: "u", isUnderlined: true))
    }

    /// P2.6: two events of one track at one time with the same word but
    /// different styling both reach the host; the same event re-demuxed
    /// (identical styling) is still deduplicated.
    @Test func sameTextDifferentStyleIsNotDeduplicated() {
        let set = SubtitleRenditionSet(outputDirectory: FileManager.default.temporaryDirectory)
        let received = StyledCueBox<[TimedTextCue]>([])
        set.setCueHandler { cue in received.withLock { $0.append(cue) } }
        set.setTimelineOrigin(seconds: 0)
        func exit(_ alignment: Int, x: Double) -> SubtitleCue {
            let placement = TextCuePlacement(alignment: alignment, anchor: .init(x: x, y: 0.4))
            return SubtitleCue(start: 10, end: 12, text: "EXIT", placement: placement,
                               styled: StyledSubtitleText(runs: [StyledTextRun(text: "EXIT")], placement: placement))
        }
        set.emitHostCue(streamIndex: 2, exit(5, x: 0.2))
        set.emitHostCue(streamIndex: 2, exit(5, x: 0.8))
        set.emitHostCue(streamIndex: 2, exit(5, x: 0.2))   // re-demuxed after a seek
        set.emitHostCue(streamIndex: 2, SubtitleCue(start: 20, end: 21, text: "plain"))
        set.emitHostCue(streamIndex: 2, SubtitleCue(start: 20, end: 21, text: "plain"))
        let cues = received.withLock { $0 }
        #expect(cues.map(\.text) == ["EXIT", "EXIT", "plain"])
        #expect(cues.compactMap(\.placement?.anchor?.x) == [0.2, 0.8])
    }

    /// P2.7: an external `.ass` drawing never reaches the WebVTT rendition
    /// (PiP / AirPlay) as text; dialogue after it does.
    @Test func externalASSDrawingsStayOutOfWebVTT() {
        let script = """
        [Events]
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 0 l 10 10{\\p0}
        Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 0{\\p0}{\\i1}Hello
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\\an8}Sign {\\p2}m 1 1{\\p0}after
        """
        let cues = TextSubtitleConverter.cues(fromASS: script)
        #expect(cues.map(\.text) == ["<i>Hello</i>", "Sign after"])
        #expect(cues.map(\.start) == [3, 5])
        #expect(TextSubtitleConverter.strippingDrawings("a {\\p1}m 0 0 {unclosed") == "a {\\p1}")
        #expect(TextSubtitleConverter.strippingDrawings("{\\pos(1,2)}keep") == "{\\pos(1,2)}keep")
    }

    /// P2.8: the 4.0.6 initializer still exists as its own symbol, so a
    /// function reference to it compiles.
    @Test func originalTimedTextCueInitializerStillResolves() {
        let make: (Int32, Double, Double, String, TextCuePlacement?) -> TimedTextCue =
            TimedTextCue.init(streamIndex:start:end:text:placement:)
        let cue = make(1, 0, 1, "x", nil)
        #expect(cue.styled == nil && cue.text == "x")
        #expect(TimedTextCue(streamIndex: 1, start: 0, end: 1, text: "x") == cue)
    }

    @Test func tx3gStyleBoxAppliesPerRange() throws {
        // "Hello world", bold+red on 0..<5, then an unknown box that must be skipped.
        var sample: [UInt8] = [0, 11] + Array("Hello world".utf8)
        sample += [0, 0, 0, 22] + Array("styl".utf8) + [0, 1]
        sample += [0, 0, 0, 5, 0, 1, 0x01, 18, 255, 0, 0, 255]
        sample += [0, 0, 0, 9] + Array("hlit".utf8) + [7]
        let text = try #require(TextSubtitleConverter.movTextStyled(Data(sample)))
        #expect(text.runs.map(\.text) == ["Hello", " world"])
        #expect(text.runs[0].isBold && text.runs[0].color == red)
        #expect(!text.runs[1].isBold)
        // A styl box whose ranges run past the text is clipped, not trusted.
        var hostile: [UInt8] = [0, 2] + Array("Hi".utf8) + [0, 0, 0, 22] + Array("styl".utf8) + [0, 1]
        hostile += [0, 0, 0xFF, 0xFF, 0, 1, 0x02, 18, 0, 0, 0, 255]
        #expect(TextSubtitleConverter.movTextStyled(Data(hostile))?.runs.first?.isItalic == true)
    }

    @Test func withoutSourceColorsMergesRuns() {
        let text = StyledSubtitleText(runs: [
            StyledTextRun(text: "a", color: red), StyledTextRun(text: "b", color: white),
            StyledTextRun(text: "c", isItalic: true),
        ])
        #expect(text.withoutSourceColors().runs == [StyledTextRun(text: "ab"), StyledTextRun(text: "c", isItalic: true)])
    }

    @Test func styledTextIsCodableAndPlacementValidated() throws {
        let text = StyledSubtitleText(runs: [StyledTextRun(text: "x", isBold: true, color: red, voice: "V")],
                                      placement: TextCuePlacement(alignment: 8, anchor: .init(x: 0.1, y: 0.2)))
        let data = try JSONEncoder().encode(text)
        #expect(try JSONDecoder().decode(StyledSubtitleText.self, from: data) == text)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TextCuePlacement.self, from: Data(#"{"alignment":0}"#.utf8))
        }
    }

    @Test func documentParserCoversSRTWebVTTAndASS() {
        let srt = SubtitleTextParser.cues(from: "1\n00:00:01,000 --> 00:00:02,000\n{\\an8}<b>Top</b>\n", format: .srt)
        #expect(srt.count == 1)
        #expect(srt.first?.text.runs.first?.isBold == true)
        #expect(srt.first?.text.placement == TextCuePlacement(alignment: 8))
        #expect(srt.first?.webVTTText == "<b>Top</b>")

        let vtt = SubtitleTextParser.cues(from: Data("WEBVTT\n\n00:01.000 --> 00:02.000 line:10%\n<i>hi</i>\n".utf8))
        #expect(vtt.first?.text.runs.first?.isItalic == true)
        #expect(vtt.first?.text.placement?.row == .top)

        let ass = SubtitleTextParser.cues(from: Data("""
        [Script Info]
        PlayResY: 360
        [V4+ Styles]
        Format: Name, Fontname, PrimaryColour, Alignment
        Style: Default,Arial,&H000000FF,2
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Comment: 0,0:00:00.00,0:00:09.00,Default,,0,0,0,,hidden
        Dialogue: 0,0:00:03.00,0:00:04.50,Default,,0,0,0,,second, with a comma
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\i1}first
        """.utf8))
        #expect(ass.map(\.start) == [1, 3])
        #expect(ass.map(\.end) == [2, 4.5])
        #expect(ass[0].text.runs.first?.isItalic == true)
        #expect(ass[1].text.plainText == "second, with a comma")
        #expect(ass[1].text.runs.first?.color == red)

        #expect(SubtitleTextParser.styledText(payload: Data("<u>u</u>".utf8), format: .subrip)?.runs.first?.isUnderlined == true)
        #expect(SubtitleTextParser.styledText(payload: Data("{\\p1}m 0 0 l 1 1".utf8), format: .assEvent) == nil)
    }

    @Test func externalASSFileBecomesARendition() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prismcore-\(UUID()).ass")
        try Data("[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\i1}ahoj\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cues = try #require(SubtitleRenditionSet.loadExternalCues(url))
        #expect(cues.map(\.text) == ["<i>ahoj</i>"])
    }
}

/// Cross-thread box for the cue handler.
// Safety: `value` is only touched under `lock`.
private final class StyledCueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
