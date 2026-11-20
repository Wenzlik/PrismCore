import Testing
import Foundation
import Libavcodec
import Libavutil
@testable import PrismCore

/// ASS drawing mode (`{\p1}…{\p0}`) is vector commands, never dialogue. Since
/// 4.0.7 the plain/WebVTT text drops it exactly like the styled runs do —
/// before, `TimedTextCue.text` and every WebVTT rendition showed
/// "m 0 0 l 10 0" as a line of subtitles.
@Suite("ASS drawings stay out of plain text")
struct ASSDrawingStripTests {

    /// One Matroska ASS block (ReadOrder,Layer,Style,…,Effect) around `text`.
    private func event(_ text: String) -> Data { Data("0,0,Default,,0,0,0,,\(text)".utf8) }

    private func convert(_ text: String, _ kind: TextSubtitleConverter.Kind = .ass) -> TextSubtitleConverter.Converted? {
        TextSubtitleConverter.convert(kind == .ass ? event(text) : Data(text.utf8), kind: kind, playResolution: nil)
    }

    @Test func pureDrawingEventsProduceNoCue() {
        #expect(convert("{\\p1}m 0 0 l 10 0 l 10 10 l 0 10{\\p0}") == nil)
        // To the end of the event, no `\p0`.
        #expect(convert("{\\p1}m 0 0 l 100 0 100 100 0 100") == nil)
        #expect(convert("{\\an7\\pos(10,10)\\p2}m 0 0 b 10 0 10 10 0 10") == nil)
        // An unclosed brace inside a drawing is dropped with it.
        #expect(convert("{\\p1}m 0 0 l 1 1 {unclosed") == nil)
        // Line breaks inside a drawing are not dialogue either.
        #expect(convert("{\\p1}m 0 0\\Nl 5 5") == nil)
    }

    @Test func drawingThenDialogueKeepsOnlyDialogue() throws {
        let mixed = try #require(convert("{\\p1}m 0 0 l 10 0{\\p0}Ahoj {\\i1}světe{\\i0}"))
        #expect(mixed.text == "Ahoj <i>světe</i>")
        #expect(mixed.styled?.plainText == "Ahoj světe")
        let after = try #require(convert("Před {\\p1}m 0 0 l 10 0{\\p0}po"))
        #expect(after.text == "Před po")
        #expect(after.styled?.plainText == "Před po")
        let lines = try #require(convert("{\\p1}m 0 0{\\p0}první\\N{\\p1}l 1 1{\\p0}druhý"))
        #expect(lines.text == "první\ndruhý")
    }

    @Test func pZeroResetsIncludingInsideTheSameBlock() throws {
        #expect(convert("{\\p1\\p0}Ahoj")?.text == "Ahoj")
        #expect(convert("{\\p0\\p1}m 0 0 l 1 1") == nil, "the last \\p in a block wins")
        #expect(convert("{\\i1\\p1}m 0 0{\\p0\\i0} text")?.text == "text")
        #expect(convert("{\\p3}m 0 0{\\p-1}Ahoj")?.text == "Ahoj", "\\p with a level ≤ 0 ends the drawing")
    }

    @Test func oddTagsDoNotStartADrawing() throws {
        // Text before a block's first backslash is not a tag (libass skips it).
        #expect(convert("{p1\\i1}Ahoj")?.text == "<i>Ahoj</i>")
        #expect(convert("{p1\\i1}Ahoj")?.styled?.plainText == "Ahoj")
        // A comment block (no backslash) is no tag at all.
        #expect(convert("{p1}Ahoj")?.text == "Ahoj")
        // `\t(…)` targets are animation, not state; `\pos` and `\pbo` are not `\p`.
        #expect(convert("{\\t(0,100,\\p1)}Ahoj")?.text == "Ahoj")
        #expect(convert("{\\t(0,100,\\p1)}Ahoj")?.styled?.plainText == "Ahoj")
        #expect(convert("{\\pos(10,10)}Ahoj")?.text == "Ahoj")
        #expect(convert("{\\pbo5}Ahoj")?.text == "Ahoj")
        // A non-numeric level is no switch at all.
        #expect(convert("{\\pX}Ahoj")?.text == "Ahoj")
    }

    @Test func plainAndStyledAgreeOnWhatIsDialogue() {
        let samples = [
            "{\\p1}m 0 0{\\p0}a", "a{\\p1}m 1 1", "{\\p1\\p0}a{\\p2}m{\\p0}b", "{p1\\p1}m{\\p0}c",
            "{\\t(\\p1)}d", "{\\p1}{x}{\\p0}e", "{\\p1}\\N{\\p0}f\\Ng",
        ]
        for sample in samples {
            let converted = convert(sample)
            // `text` is WebVTT (tags, entities); with none here it is the plain view.
            #expect(converted?.text == converted?.styled?.plainText, "\(sample)")
        }
    }

    @Test func otherTextKindsAndDocumentsStripToo() throws {
        // An SRT author pasting ASS overrides gets the same rule.
        #expect(convert("{\\p1}m 0 0 l 1 1{\\p0}Ahoj", .subrip)?.text == "Ahoj")

        let srt = TextSubtitleConverter.cues(fromSRT: "1\n00:00:01,000 --> 00:00:02,000\n{\\p1}m 0 0{\\p0}Text\n\n2\n00:00:03,000 --> 00:00:04,000\n{\\p1}m 0 0 l 9 9\n")
        #expect(srt.map(\.text) == ["Text"])

        let script = """
        [Script Info]
        PlayResX: 640
        PlayResY: 360
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 0{\\p0}Nápis
        Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\an7\\p1}m 0 0 l 10 0 l 10 10
        """
        let cues = TextSubtitleConverter.cues(fromASS: script)
        #expect(cues.map(\.text) == ["Nápis"])
        #expect(SubtitleTextParser.cues(from: script, format: .ass).map(\.webVTTText) == ["Nápis"])

        // The external-file rendition loader (what PiP and AirPlay show).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prismcore-\(UUID()).ass")
        try Data(script.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try #require(SubtitleRenditionSet.loadExternalCues(url)).map(\.text) == ["Nápis"])
    }

    @Test func softwareCueStoreDropsDrawingsFromPackets() throws {
        let store = SoftwareSubtitleCueStore()
        func feed(_ text: String, pts: Int64) throws {
            let bytes = Array(event(text))
            let packet = try #require(av_packet_alloc())
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            #expect(av_new_packet(packet, Int32(bytes.count)) == 0)
            let payload = try #require(packet.pointee.data)
            bytes.withUnsafeBufferPointer { payload.update(from: $0.baseAddress!, count: bytes.count) }
            packet.pointee.pts = pts
            packet.pointee.duration = 1_000
            packet.pointee.stream_index = 3
            store.ingest(packet, timeBase: AVRational(num: 1, den: 1_000), kind: .ass, currentTime: .nan)
        }
        try feed("{\\p1}m 0 0 l 10 0{\\p0}Dialog", pts: 1_000)
        try feed("{\\p1}m 0 0 l 10 0 l 10 10", pts: 3_000)
        #expect(store.active(streamIndex: 3, at: 1.5).map(\.text) == ["Dialog"])
        #expect(store.active(streamIndex: 3, at: 3.5).isEmpty, "a pure drawing is no cue")
    }
}
