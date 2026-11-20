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
