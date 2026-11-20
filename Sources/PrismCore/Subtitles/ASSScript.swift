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
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return styles[trimmed]
            ?? styles[String(trimmed.drop { $0 == "*" })]
            ?? styles["Default"]
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
        _ payload: Data, kind: Kind, playResolution: PlayResolution?, header: ASSScriptHeader?
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
            return movTextStyled(payload)
        }
    }

    /// A `tx3g` sample with its `styl` box applied (3GPP TS 26.245 § 5.17):
    /// per-range bold / italic / underline and text colour. Ranges are
    /// character offsets; other boxes (highlight, karaoke, hyperlinks) are
    /// skipped.
    static func movTextStyled(_ payload: Data) -> StyledSubtitleText? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return nil }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, bytes.count >= 2 + length,
              let text = String(bytes: bytes[2..<(2 + length)], encoding: .utf8) else { return nil }
        let scalars = Array(text.unicodeScalars)
        var styleOf = [Int](repeating: 0, count: scalars.count)
        var styles = [InlineStyle()]

        func be16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        var offset = 2 + length
        while offset + 8 <= bytes.count {
            let size = be16(offset) << 16 | be16(offset + 2)
            guard size >= 8, offset + size <= bytes.count else { break }
            if bytes[(offset + 4)..<(offset + 8)].elementsEqual("styl".utf8), size >= 10 {
                let count = be16(offset + 8)
                for entry in 0..<count {
                    let at = offset + 10 + entry * 12
                    guard at + 12 <= offset + size else { break }
                    let start = be16(at), end = min(be16(at + 2), scalars.count)
                    guard start < end else { continue }
                    let flags = bytes[at + 6]
                    var style = InlineStyle()
                    style.bold = flags & 1 != 0
                    style.italic = flags & 2 != 0
                    style.underline = flags & 4 != 0
                    style.color = SubtitleColor(red: bytes[at + 8], green: bytes[at + 9], blue: bytes[at + 10], alpha: bytes[at + 11])
                    styles.append(style)
                    for index in start..<end { styleOf[index] = styles.count - 1 }
                }
            }
            offset += size
        }
        let chars = zip(scalars, styleOf).map { (Character($0.0), $0.1) }
        return StyledTextParser.styled(chars: chars, styles: styles, placement: nil)
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
            let converted = sanitizeStyled(body, playResolution: header.playResolution)
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
