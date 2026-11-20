import Foundation

/// A colour a subtitle source asked for, straight RGBA (not premultiplied),
/// `alpha` 255 = opaque. ASS spells transparency the other way round
/// (`&H00` is opaque); that is converted on the way in, so a host never has
/// to know which syntax a colour came from.
public struct SubtitleColor: Sendable, Hashable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// One stretch of cue text sharing one inline style.
///
/// Only what a host overlay can reasonably honour is kept: the emphasis
/// trio plus strike-through, the source's fill and outline colours, a font
/// family, and WebVTT's semantic markers (voice, classes). Karaoke timing,
/// blur, rotation and vector drawings are libass's business — a host that
/// wants those renders the track with `ASSSubtitleRenderer` instead.
public struct StyledTextRun: Sendable, Equatable, Codable {
    public var text: String
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool
    public var isStruckThrough: Bool
    /// Fill colour: SRT `<font color>`, WebVTT colour classes, ASS `\c` /
    /// `\1c` (or the style's PrimaryColour). `nil` = the host's own colour.
    public var color: SubtitleColor?
    /// ASS `\3c` / the style's OutlineColour. `nil` = the host's own.
    public var outlineColor: SubtitleColor?
    /// ASS `\fn` / the style's Fontname, or SRT `<font face>`.
    public var fontName: String?
    /// WebVTT `<v Name>` — who is speaking.
    public var voice: String?
    /// WebVTT `<c.a.b>` class names, in source order.
    public var classes: [String]

    public init(
        text: String, isBold: Bool = false, isItalic: Bool = false, isUnderlined: Bool = false,
        isStruckThrough: Bool = false, color: SubtitleColor? = nil, outlineColor: SubtitleColor? = nil,
        fontName: String? = nil, voice: String? = nil, classes: [String] = []
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStruckThrough = isStruckThrough
        self.color = color
        self.outlineColor = outlineColor
        self.fontName = fontName
        self.voice = voice
        self.classes = classes
    }
}

/// Cue text with its inline styling preserved — the structured twin of the
/// WebVTT-safe `TimedTextCue.text`, which stays exactly what it was so hosts
/// that read only the string see no change.
///
/// `runs` hold *plain* text: no tags, no entities, no ASS override blocks;
/// line breaks are `"\n"` inside a run. Concatenated they are `plainText`.
public struct StyledSubtitleText: Sendable, Equatable, Codable {
    public var runs: [StyledTextRun]
    /// Where the source asked for the cue: an ASS `\an`/`\pos` override, the
    /// ASS *style's* alignment (which `TimedTextCue.placement` has never
    /// read), or the WebVTT cue settings. `nil` = the host's default.
    public var placement: TextCuePlacement?

    public init(runs: [StyledTextRun], placement: TextCuePlacement? = nil) {
        self.runs = runs
        self.placement = placement
    }

    public var plainText: String { runs.map(\.text).joined() }

    /// The same text with every source colour removed — for a host whose
    /// "use source colours" setting is off. Emphasis, fonts and placement
    /// stay; adjacent runs that only differed by colour are merged.
    public func withoutSourceColors() -> StyledSubtitleText {
        var merged: [StyledTextRun] = []
        for var run in runs {
            run.color = nil
            run.outlineColor = nil
            if var last = merged.last, last.sameStyle(as: run) {
                last.text += run.text
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        return StyledSubtitleText(runs: merged, placement: placement)
    }
}

extension StyledTextRun {
    func sameStyle(as other: StyledTextRun) -> Bool {
        var a = self
        a.text = other.text
        return a == other
    }
}

// MARK: - Parsing

/// The style state an inline-markup walk carries. Internal: the public face
/// is `StyledTextRun`.
struct InlineStyle: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var color: SubtitleColor?
    var outlineColor: SubtitleColor?
    var fontName: String?
    var voice: String?
    var classes: [String] = []

    func run(_ text: String) -> StyledTextRun {
        StyledTextRun(
            text: text, isBold: bold, isItalic: italic, isUnderlined: underline, isStruckThrough: strike,
            color: color, outlineColor: outlineColor, fontName: fontName, voice: voice, classes: classes
        )
    }
}

/// Turns one cue's raw markup — SRT/HTML-ish tags, WebVTT tags and entities,
/// ASS override blocks, any mix of them, because real files mix them — into
/// styled runs. Separate from `TextSubtitleConverter.sanitizeStyled` on
/// purpose: that one produces the WebVTT payload the served renditions and
/// every existing host depend on byte for byte, and must not move.
///
/// Never fails: unknown tags and unbalanced braces stay visible as text,
/// which is what a viewer would rather see than a silently missing line.
enum StyledTextParser {

    static func parse(
        _ raw: String, base: InlineStyle = InlineStyle(), header: ASSScriptHeader? = nil,
        playResolution: TextSubtitleConverter.PlayResolution? = nil,
        basePlacement: TextCuePlacement? = nil
    ) -> StyledSubtitleText {
        let resolution = header?.playResolution ?? playResolution
        var chars: [(Character, Int)] = []   // character + index into `styles`
        var styles: [InlineStyle] = [base]
        var style = base
        var tagStack: [(name: String, saved: InlineStyle)] = []
        var alignment: Int?
        var anchor: TextCuePlacement.Anchor?
        var drawing = false

        func emit(_ character: Character) {
            guard !drawing else { return }
            if styles[styles.count - 1] != style { styles.append(style) }
            chars.append((character, styles.count - 1))
        }

        let text = Array(raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: ""))
        var index = 0
        while index < text.count {
            let character = text[index]
            switch character {
            case "{":
                guard let close = text[index...].firstIndex(of: "}") else {
                    emit(character); index += 1; continue
                }
                let block = String(text[(index + 1)..<close])
                if block.contains("\\") {
                    applyASS(block, to: &style, base: base, header: header, alignment: &alignment,
                             anchor: &anchor, drawing: &drawing, resolution: resolution)
                }
                index = close + 1
            case "\\" where index + 1 < text.count:
                switch text[index + 1] {
                case "N", "n": emit("\n"); index += 2
                case "h": emit(" "); index += 2
                default: emit(character); index += 1
                }
            case "<":
                guard let close = text[index...].firstIndex(of: ">"),
                      applyTag(String(text[(index + 1)..<close]), to: &style, stack: &tagStack)
                else { emit(character); index += 1; continue }
                index = close + 1
            case "&":
                if let (decoded, length) = entity(text, at: index) {
                    emit(decoded); index += length
                } else {
                    emit(character); index += 1
                }
            default:
                emit(character); index += 1
            }
        }

        let placement: TextCuePlacement?
        if let alignment {
            placement = TextCuePlacement(alignment: alignment, anchor: anchor)
        } else if anchor != nil {
            placement = TextCuePlacement(alignment: basePlacement?.alignment ?? 2, anchor: anchor)
        } else {
            placement = basePlacement
        }
        return styled(chars: chars, styles: styles, placement: placement)
    }

    static func styled(chars: [(Character, Int)], styles: [InlineStyle], placement: TextCuePlacement?) -> StyledSubtitleText {
        StyledSubtitleText(runs: runs(from: normalizedLines(chars), styles: styles), placement: placement)
    }

    /// Same line hygiene as the WebVTT payload: each line trimmed, blank
    /// lines dropped — so `plainText` and the tag-stripped `text` agree.
    private static func normalizedLines(_ chars: [(Character, Int)]) -> [(Character, Int)] {
        var lines: [[(Character, Int)]] = [[]]
        for item in chars {
            if item.0 == "\n" { lines.append([]) } else { lines[lines.count - 1].append(item) }
        }
        var output: [(Character, Int)] = []
        for var line in lines {
            while let first = line.first, first.0.isWhitespace { line.removeFirst() }
            while let last = line.last, last.0.isWhitespace { line.removeLast() }
            guard !line.isEmpty else { continue }
            if !output.isEmpty { output.append(("\n", output[output.count - 1].1)) }
            output += line
        }
        return output
    }

    private static func runs(from chars: [(Character, Int)], styles: [InlineStyle]) -> [StyledTextRun] {
        var runs: [StyledTextRun] = []
        var current = ""
        var currentStyle: Int?
        for (character, styleIndex) in chars {
            if let active = currentStyle, styles[active] != styles[styleIndex] {
                runs.append(styles[active].run(current))
                current = ""
            }
            currentStyle = styleIndex
            current.append(character)
        }
        if let active = currentStyle, !current.isEmpty { runs.append(styles[active].run(current)) }
        return runs
    }

    // MARK: HTML-ish / WebVTT tags

    /// WebVTT's predefined colour classes (§ 5.3.2 default styles).
    static let webVTTColorClasses: [String: SubtitleColor] = [
        "white": .init(red: 255, green: 255, blue: 255), "lime": .init(red: 0, green: 255, blue: 0),
        "cyan": .init(red: 0, green: 255, blue: 255), "red": .init(red: 255, green: 0, blue: 0),
        "yellow": .init(red: 255, green: 255, blue: 0), "magenta": .init(red: 255, green: 0, blue: 255),
        "blue": .init(red: 0, green: 0, blue: 255), "black": .init(red: 0, green: 0, blue: 0),
    ]

    /// Applies one `<…>` tag; `false` when it is not a tag we recognize, so
    /// the caller keeps the `<` as text (`I <3 you` must survive).
    private static func applyTag(_ inner: String, to style: inout InlineStyle,
                                 stack: inout [(name: String, saved: InlineStyle)]) -> Bool {
        guard !inner.isEmpty, !inner.contains("<") else { return false }
        if inner.first?.isNumber == true {
            // A WebVTT karaoke timestamp (`<00:00:01.500>`): invisible.
            return TextSubtitleConverter.parseTimestamp(inner) != nil
        }
        let closing = inner.hasPrefix("/")
        let body = closing ? inner.dropFirst() : inner[...]
        let name = String(body.prefix { $0.isLetter }).lowercased()
        guard ["b", "i", "u", "s", "font", "c", "v", "lang", "ruby", "rt", "span"].contains(name) else { return false }
        if closing {
            if let match = stack.lastIndex(where: { $0.name == name }) {
                style = stack[match].saved
                stack.removeSubrange(match...)
            }
            return true
        }
        stack.append((name, style))
        let rest = body.dropFirst(name.count)
        switch name {
        case "b": style.bold = true
        case "i": style.italic = true
        case "u": style.underline = true
        case "s": style.strike = true
        case "font":
            if let value = attribute("color", in: rest), let color = htmlColor(value) { style.color = color }
            if let face = attribute("face", in: rest), !face.isEmpty { style.fontName = face }
        case "c", "v":
            // `<c.yellow.bg_black>`, `<v.loud Esme>`: classes, then (for v) the voice.
            let classPart = rest.prefix { !$0.isWhitespace }
            let classes = classPart.split(separator: ".").map(String.init)
            style.classes += classes
            if let color = classes.lazy.compactMap({ webVTTColorClasses[$0] }).last { style.color = color }
            if name == "v" {
                let voice = rest.dropFirst(classPart.count).trimmingCharacters(in: .whitespaces)
                if !voice.isEmpty { style.voice = voice }
            }
        default: break
        }
        return true
    }

    private static func attribute(_ key: String, in text: Substring) -> String? {
        guard let range = text.range(of: key + "=", options: .caseInsensitive) else { return nil }
        var value = text[range.upperBound...]
        if let quote = value.first, quote == "\"" || quote == "'" {
            value = value.dropFirst()
            return String(value.prefix { $0 != quote })
        }
        return String(value.prefix { !$0.isWhitespace })
    }

    static func htmlColor(_ value: String) -> SubtitleColor? {
        let named: [String: SubtitleColor] = webVTTColorClasses.merging([
            "green": .init(red: 0, green: 128, blue: 0), "gray": .init(red: 128, green: 128, blue: 128),
            "grey": .init(red: 128, green: 128, blue: 128), "orange": .init(red: 255, green: 165, blue: 0),
            "purple": .init(red: 128, green: 0, blue: 128), "silver": .init(red: 192, green: 192, blue: 192),
        ]) { first, _ in first }
        let lowered = value.lowercased()
        if let color = named[lowered] { return color }
        var hex = lowered.hasPrefix("#") ? String(lowered.dropFirst()) : lowered
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let packed = UInt32(hex, radix: 16) else { return nil }
        return SubtitleColor(red: UInt8(packed >> 16 & 0xFF), green: UInt8(packed >> 8 & 0xFF), blue: UInt8(packed & 0xFF))
    }

    private static func entity(_ text: [Character], at index: Int) -> (Character, Int)? {
        guard let semicolon = text[index...].prefix(12).firstIndex(of: ";") else { return nil }
        let body = String(text[(index + 1)..<semicolon])
        let named: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "lrm": "\u{200E}", "rlm": "\u{200F}",
        ]
        if let character = named[body] { return (character, semicolon - index + 1) }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let value = digits.hasPrefix("x") || digits.hasPrefix("X")
            ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
        return (Character(scalar), semicolon - index + 1)
    }

    // MARK: ASS override blocks

    private static func applyASS(
        _ block: String, to style: inout InlineStyle, base: InlineStyle, header: ASSScriptHeader?,
        alignment: inout Int?, anchor: inout TextCuePlacement.Anchor?, drawing: inout Bool,
        resolution: TextSubtitleConverter.PlayResolution?
    ) {
        for rawTag in block.split(separator: "\\", omittingEmptySubsequences: true) {
            let tag = rawTag.trimmingCharacters(in: .whitespaces)
            // Longest names first: `\bord` must not read as `\b`, `\shad` as `\s`.
            if tag.hasPrefix("pos(") {
                guard let resolution, resolution.width > 0, resolution.height > 0,
                      let close = tag.firstIndex(of: ")") else { continue }
                let args = tag[tag.index(tag.startIndex, offsetBy: 4)..<close].split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard args.count == 2 else { continue }
                // Finite inputs can still overflow the division (`1e308` over a
                // tiny PlayRes); an infinite anchor is unencodable and unplaceable.
                let point = TextCuePlacement.Anchor(x: args[0] / resolution.width, y: args[1] / resolution.height)
                guard point.x.isFinite, point.y.isFinite else { continue }
                anchor = point
            } else if tag.hasPrefix("an"), let value = Int(tag.dropFirst(2)) {
                if (1...9).contains(value) { alignment = value }
            } else if tag.hasPrefix("alpha") {
                if let alpha = assAlpha(tag.dropFirst(5)) {
                    style.color = (style.color ?? .init(red: 255, green: 255, blue: 255)).with(alpha: alpha)
                    style.outlineColor = style.outlineColor.map { $0.with(alpha: alpha) }
                }
            } else if tag.hasPrefix("a"), let value = Int(tag.dropFirst(1)) {
                if let mapped = TextCuePlacement.alignment(fromLegacySSA: value) { alignment = mapped }
            } else if tag.hasPrefix("1a") {
                if let alpha = assAlpha(tag.dropFirst(2)) {
                    style.color = (style.color ?? .init(red: 255, green: 255, blue: 255)).with(alpha: alpha)
                }
            } else if tag.hasPrefix("3a") {
                if let alpha = assAlpha(tag.dropFirst(2)) { style.outlineColor = style.outlineColor?.with(alpha: alpha) }
            } else if tag.hasPrefix("1c") || (tag.hasPrefix("c") && !tag.hasPrefix("clip")) {
                if let color = assColor(tag.drop { $0 != "&" && $0 != "H" && $0 != "h" }) {
                    style.color = color.with(alpha: style.color?.alpha ?? 255)
                }
            } else if tag.hasPrefix("3c") {
                if let color = assColor(tag.dropFirst(2)) { style.outlineColor = color }
            } else if tag.hasPrefix("fn") {
                let name = tag.dropFirst(2).trimmingCharacters(in: .whitespaces)
                style.fontName = name.isEmpty ? base.fontName : name
            } else if tag.hasPrefix("p"), let value = Int(tag.dropFirst(1)) {
                // Drawing mode: what follows is vector commands, never text.
                drawing = value > 0
            } else if tag.hasPrefix("i"), let value = Int(tag.dropFirst(1)) {
                style.italic = value != 0
            } else if tag.hasPrefix("u"), let value = Int(tag.dropFirst(1)) {
                style.underline = value != 0
            } else if tag.hasPrefix("s"), let value = Int(tag.dropFirst(1)) {
                style.strike = value != 0
            } else if tag.hasPrefix("b"), let value = Int(tag.dropFirst(1)) {
                style.bold = value != 0   // `\b1` and `\b700` (a weight) are both bold
            } else if tag.hasPrefix("r"), !tag.hasPrefix("rnd") {
                let name = String(tag.dropFirst(1))
                style = name.isEmpty ? base : header?.styles[name]?.inline ?? base
            }
        }
    }

    /// `&HBBGGRR&` / `&HAABBGGRR&` (ASS byte order, alpha inverted), or a
    /// bare decimal as SSA v4 styles write it.
    static func assColor<S: StringProtocol>(_ raw: S) -> SubtitleColor? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "&"))
        let packed: UInt32?
        if text.hasPrefix("H") || text.hasPrefix("h") {
            packed = UInt32(text.dropFirst().prefix(8), radix: 16)
        } else {
            packed = Int64(text).map { UInt32(truncatingIfNeeded: $0) }
        }
        guard let packed else { return nil }
        return SubtitleColor(
            red: UInt8(packed & 0xFF), green: UInt8(packed >> 8 & 0xFF), blue: UInt8(packed >> 16 & 0xFF),
            alpha: 255 - UInt8(packed >> 24 & 0xFF)
        )
    }

    private static func assAlpha<S: StringProtocol>(_ raw: S) -> UInt8? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "&Hh "))
        guard let value = UInt8(text.suffix(2), radix: 16) else { return nil }
        return 255 - value
    }
}

extension SubtitleColor {
    func with(alpha: UInt8) -> SubtitleColor {
        var copy = self
        copy.alpha = alpha
        return copy
    }
}
