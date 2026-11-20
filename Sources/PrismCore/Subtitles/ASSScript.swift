import Foundation

/// What an ASS/SSA script header says that a *text* reading of its events
/// needs: the play resolution (for `\pos`) and the named styles (each
/// event's base colours, emphasis and alignment). Everything else — margins,
/// borders, shadows, scaling, the `[Fonts]` section — is libass's to honour.
///
/// The same parser reads a Matroska ASS track's CodecPrivate (header only)
/// and a whole `.ass` file (header plus `[Events]`).
struct ASSScriptHeader: Equatable {
    struct Style: Equatable {
        var inline: InlineStyle
        /// Numpad alignment (SSA v4's legacy values already mapped).
        var alignment: Int
    }

    var playResolution: TextSubtitleConverter.PlayResolution
    var styles: [String: Style]

    init?(data: Data?) {
        guard let data, !data.isEmpty,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        self.init(text: text)
    }

    init(text: String) {
        playResolution = TextSubtitleConverter.playResolution(fromASSHeader: Data(text.utf8)) ?? .assDefault
        styles = [:]
        var section = ""
        var format: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.lowercased()
                format = []
                continue
            }
            guard section == "[v4+ styles]" || section == "[v4 styles]",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
            if key == "format" {
                format = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if key == "style", !format.isEmpty {
                let fields = value.split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                var named: [String: String] = [:]
                for (name, field) in zip(format, fields) { named[name] = field }
                guard let name = named["name"] else { continue }
                styles[name] = Self.style(named, legacy: section == "[v4 styles]")
            }
        }
    }

    private static func style(_ fields: [String: String], legacy: Bool) -> Style {
        func flag(_ key: String) -> Bool { (Int(fields[key] ?? "0") ?? 0) != 0 }
        var inline = InlineStyle()
        inline.bold = flag("bold")
        inline.italic = flag("italic")
        inline.underline = flag("underline")
        inline.strike = flag("strikeout")
        inline.color = fields["primarycolour"].flatMap(StyledTextParser.assColor)
        inline.outlineColor = fields["outlinecolour"].flatMap(StyledTextParser.assColor)
        if let font = fields["fontname"], !font.isEmpty { inline.fontName = font }
        let raw = Int(fields["alignment"] ?? "2") ?? 2
        let alignment = legacy ? TextCuePlacement.alignment(fromLegacySSA: raw) ?? 2 : ((1...9).contains(raw) ? raw : 2)
        return Style(inline: inline, alignment: alignment)
    }

    /// libass's lookup, roughly: the exact name, then without the `*` some
    /// scripts prefix, then `Default`.
    func style(named name: String?) -> Style? {
        guard let name else { return styles["Default"] }
        return style(strictlyNamed: name) ?? styles["Default"]
    }

    /// The same name matching without the `Default` fallback — what `\r`
    /// needs: an unknown name there resets to the event's *own* style, as
    /// libass does, while `{\r*Default}` / `{\r Default}` must still find
    /// Default (an exact-key lookup missed both).
    func style(strictlyNamed name: String) -> Style? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return styles[trimmed] ?? styles[String(trimmed.drop { $0 == "*" })]
    }

    /// Styled runs for one event's `Text` field under its named style.
    func styled(text: String, styleName: String?) -> StyledSubtitleText {
        let style = style(named: styleName)
        return StyledTextParser.parse(
            text, base: style?.inline ?? InlineStyle(), header: self,
            basePlacement: style.flatMap { $0.alignment == 2 ? nil : TextCuePlacement(alignment: $0.alignment) }
        )
    }
}

extension TextSubtitleConverter {

    /// The `Style` and `Text` fields of an event line, in any of the three
    /// shapes `assEventText` recognizes.
    static func assEventStyleAndText(_ line: String) -> (style: String?, text: String) {
        var body = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var fieldsBeforeText = 7
        if let range = body.range(of: "Dialogue:") {
            body = String(body[range.upperBound...])
            fieldsBeforeText = 9
        } else {
            let head = body.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            if head.count >= 2, Int(head[1].trimmingCharacters(in: .whitespaces)) != nil { fieldsBeforeText = 8 }
        }
        let parts = body.split(separator: ",", maxSplits: fieldsBeforeText, omittingEmptySubsequences: false)
        guard parts.count > fieldsBeforeText else { return (nil, body) }
        let styleIndex = fieldsBeforeText - 6   // Style sits six fields before Text in every shape
        return (parts[styleIndex].trimmingCharacters(in: .whitespaces), String(parts[fieldsBeforeText]))
    }

    /// Styled runs for one packet payload — the structured view of what
    /// `convert` turns into WebVTT text. `header` is the ASS track's script
    /// header (styles, play resolution); ignored for the other kinds.
    static func styledText(
        _ payload: Data, kind: Kind, playResolution: PlayResolution?, header: ASSScriptHeader?,
        movText: MovTextDescription? = nil
    ) -> StyledSubtitleText? {
        switch kind {
        case .subrip, .webvtt:
            return String(data: payload, encoding: .utf8)
                .map { StyledTextParser.parse($0, playResolution: playResolution) }
        case .ass:
            guard let line = String(data: payload, encoding: .utf8) else { return nil }
            let event = assEventStyleAndText(line)
            if let header { return header.styled(text: event.text, styleName: event.style) }
            return StyledTextParser.parse(event.text, playResolution: playResolution)
        case .movText:
            return movTextStyled(payload, description: movText)
        }
    }

    /// What a `tx3g` track's sample description (FFmpeg's `extradata` for
    /// mov_text: the TextSampleEntry from its display flags on, 3GPP TS
    /// 26.245 § 5.16) says about every sample: the default style, the
    /// justification, and the font table its style records point into.
    struct MovTextDescription: Equatable {
        var style = InlineStyle()
        var placement: TextCuePlacement?
        var fonts: [Int: String] = [:]

        /// `nil` when the record is shorter than the fixed part (30 bytes).
        init?(_ extradata: Data?) {
            guard let extradata, extradata.count >= 30 else { return nil }
            let bytes = [UInt8](extradata)
            // Justification: 0 left/top, 1 centre, -1 right/bottom (signed).
            let column: Int? = switch Int8(bitPattern: bytes[4]) { case 0: 1; case 1: 2; case -1: 3; default: nil }
            let row: Int? = switch Int8(bitPattern: bytes[5]) { case 0: 6; case 1: 3; case -1: 0; default: nil }
            if let column, let row, column + row != 2 { placement = TextCuePlacement(alignment: column + row) }
            // Default StyleRecord at 18: start, end, font-ID, face flags, size, RGBA.
            let fontID = Int(bytes[22]) << 8 | Int(bytes[23])
            style = MovTextDescription.style(flags: bytes[24], rgba: bytes[26..<30])
            // FontTableBox ('ftab') after the fixed part: count, then id + Pascal name.
            if bytes.count >= 40, bytes[34..<38].elementsEqual("ftab".utf8) {
                let boxEnd = min(bytes.count, 30 + (Int(bytes[30]) << 24 | Int(bytes[31]) << 16 | Int(bytes[32]) << 8 | Int(bytes[33])))
                var at = 40
                for _ in 0..<(Int(bytes[38]) << 8 | Int(bytes[39])) {
                    guard at + 3 <= boxEnd else { break }
                    let id = Int(bytes[at]) << 8 | Int(bytes[at + 1])
                    let length = Int(bytes[at + 2])
                    guard at + 3 + length <= boxEnd else { break }
                    if let name = String(bytes: bytes[(at + 3)..<(at + 3 + length)], encoding: .utf8), !name.isEmpty {
                        fonts[id] = name
                    }
                    at += 3 + length
                }
            }
            style.fontName = fonts[fontID]
        }

        static func style(flags: UInt8, rgba: ArraySlice<UInt8>) -> InlineStyle {
            var style = InlineStyle()
            style.bold = flags & 1 != 0
            style.italic = flags & 2 != 0
            style.underline = flags & 4 != 0
            let channel = Array(rgba)
            style.color = SubtitleColor(red: channel[0], green: channel[1], blue: channel[2], alpha: channel[3])
            return style
        }
    }

    /// A `tx3g` sample with its `styl` box applied (3GPP TS 26.245 § 5.17)
    /// over the track's default style: per-range bold / italic / underline,
    /// text colour and font (through the description's font table). Ranges
    /// are character offsets; other boxes (highlight, karaoke, hyperlinks)
    /// are skipped.
    ///
    /// Style records must be ordered and must not overlap — as FFmpeg's
    /// decoder requires — or the whole box is ignored and the text keeps the
    /// default style. Applied unchecked, a damaged sample with thousands of
    /// overlapping full-length records rewrote the whole text once per record
    /// on the demux thread (review r3 P1.4); validated, every character is
    /// written at most once.
    static func movTextStyled(_ payload: Data, description: MovTextDescription? = nil) -> StyledSubtitleText? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return nil }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, bytes.count >= 2 + length,
              let text = movTextString(bytes[2..<(2 + length)]) else { return nil }
        let scalars = Array(text.unicodeScalars)
        var styleOf = [Int](repeating: 0, count: scalars.count)
        var styles = [description?.style ?? InlineStyle()]

        func be16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        var offset = 2 + length
        while offset + 8 <= bytes.count {
            let size = be16(offset) << 16 | be16(offset + 2)
            guard size >= 8, offset + size <= bytes.count else { break }
            if bytes[(offset + 4)..<(offset + 8)].elementsEqual("styl".utf8), size >= 10 {
                var records: [(start: Int, end: Int, style: InlineStyle)] = []
                var previousEnd = 0
                var valid = true
                for entry in 0..<be16(offset + 8) {
                    let at = offset + 10 + entry * 12
                    guard at + 12 <= offset + size else { break }
                    // A range past the text is clipped to it (lenient, as
                    // before); one out of order or overlapping voids the box.
                    let start = be16(at), end = min(be16(at + 2), scalars.count)
                    guard start >= previousEnd, start <= end else { valid = false; break }
                    previousEnd = end
                    guard start < end else { continue }
                    var style = MovTextDescription.style(flags: bytes[at + 6], rgba: bytes[(at + 8)..<(at + 12)])
                    style.fontName = description?.fonts[be16(at + 4)] ?? description?.style.fontName
                    records.append((start, end, style))
                }
                if valid {
                    for record in records {
                        styles.append(record.style)
                        for index in record.start..<record.end { styleOf[index] = styles.count - 1 }
                    }
                }
            }
            offset += size
        }
        let chars = zip(scalars, styleOf).map { (Character($0.0), $0.1) }
        return StyledTextParser.styled(chars: chars, styles: styles, placement: description?.placement)
    }

    /// An event's text with drawing-mode stretches (`{\p1}…{\p0}`) removed;
    /// override blocks themselves stay, so emphasis still translates. A
    /// block that does not close is text, as everywhere else. One pass.
    static func strippingDrawings(_ text: String) -> String {
        guard text.contains("\\p") else { return text }
        var output = ""
        var drawing = false
        var rest = text[...]
        while let open = rest.firstIndex(of: "{") {
            if !drawing { output += rest[..<open] }
            guard let close = rest[open...].firstIndex(of: "}") else {
                if !drawing { output += rest[open...] }
                return output
            }
            let block = rest[open...close]
            for tag in block.dropFirst().dropLast().split(separator: "\\") {
                let trimmed = tag.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("p"), let level = Int(trimmed.dropFirst()) { drawing = level > 0 }
            }
            output += block
            rest = rest[rest.index(after: close)...]
        }
        if !drawing { output += rest }
        return output
    }

    /// Cues from a whole `.ass` / `.ssa` file: every `Dialogue:` line of
    /// `[Events]` (a `Comment:` is not shown), read through the script's
    /// own `Format:` line and styles.
    static func cues(fromASS text: String) -> [SubtitleCue] {
        let header = ASSScriptHeader(text: text)
        var inEvents = false
        var format: [String] = []
        var cues: [SubtitleCue] = []
        for rawLine in text.replacingOccurrences(of: "\u{FEFF}", with: "").split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
            if key == "format" {
                format = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard key == "dialogue" else { continue }
            let fieldNames = format.isEmpty
                ? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
                : format
            let fields = value.split(separator: ",", maxSplits: fieldNames.count - 1, omittingEmptySubsequences: false)
            guard fields.count == fieldNames.count else { continue }
            var named: [String: String] = [:]
            for (name, field) in zip(fieldNames, fields) { named[name] = String(field) }
            guard let start = named["start"].flatMap({ parseTimestamp($0.trimmingCharacters(in: .whitespaces)) }),
                  let end = named["end"].flatMap({ parseTimestamp($0.trimmingCharacters(in: .whitespaces)) }),
                  end > start, let body = named["text"] else { continue }
            // Drawings out before the WebVTT payload: this rendition is what
            // PiP and AirPlay show, and the old sanitizer drops `\p1` but
            // keeps the vector commands it switched on ("m 0 0 l 10 0").
            let converted = sanitizeStyled(strippingDrawings(body), playResolution: header.playResolution)
            guard !converted.text.isEmpty else { continue }
            cues.append(SubtitleCue(
                start: start, end: end, text: converted.text,
                settings: converted.placement?.webVTTSettings, placement: converted.placement,
                styled: header.styled(text: body, styleName: named["style"])
            ))
        }
        return cues.sorted { $0.start < $1.start }
    }
}
