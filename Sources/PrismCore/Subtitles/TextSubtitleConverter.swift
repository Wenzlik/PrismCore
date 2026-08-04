import Foundation

/// Turns text-subtitle payloads into WebVTT cue text — the whole conversion
/// half of phase 6, as pure Swift.
///
/// **Why no `avcodec_decode_subtitle2`.** libavcodec would happily decode every
/// text codec into an ASS event line, but that buys nothing here: the payloads
/// this pipeline sees (a Matroska `S_TEXT/UTF8` block, an `S_TEXT/ASS` event, a
/// `tx3g` sample) are already the text itself, so a decoder would only add a
/// codec-availability dependency on the FFmpeg build (MPVKit's trim is exactly
/// the kind of surprise that cost us the `hls` muxer, see `FMP4SegmentWriter`)
/// and make every rule untestable without a demuxer. Everything below is a
/// value-in/value-out function with a unit test.
///
/// The output is WebVTT-safe by construction: no `-->` inside a payload, no
/// blank line inside a cue (either would terminate it early), unknown markup
/// escaped rather than emitted.
enum TextSubtitleConverter {

    /// The payload shapes we know how to read.
    enum Kind: Equatable {
        /// SubRip / plain text: the payload IS the cue text (Matroska stores
        /// `S_TEXT/UTF8` that way; the timing lives in the packet).
        case subrip
        /// ASS / SSA event: comma-separated fields, text last, `{\…}` override
        /// blocks inside it.
        case ass
        /// WebVTT payload (`S_TEXT/WEBVTT`) — already the target syntax; cue
        /// settings ride in packet side data and are dropped.
        case webvtt
        /// ISO/QuickTime timed text (`tx3g`): 16-bit big-endian length, then
        /// UTF-8, then optional style boxes we ignore.
        case movText
    }

    // MARK: - Packet payloads

    /// Cue text for one packet payload, or `nil` when the payload carries no
    /// visible text (an ASS karaoke-only event, an empty tx3g sample — both
    /// real and both must not become an empty cue).
    static func cueText(from payload: Data, kind: Kind) -> String? {
        let raw: String?
        switch kind {
        case .subrip, .webvtt:
            raw = String(data: payload, encoding: .utf8)
        case .ass:
            raw = String(data: payload, encoding: .utf8).map(assEventText)
        case .movText:
            raw = movTextPayload(payload)
        }
        guard let raw else { return nil }
        let text = sanitize(raw)
        return text.isEmpty ? nil : text
    }

    /// The `Text` field of an ASS event line.
    ///
    /// Three shapes reach us, and the field count differs in each — so the
    /// shape is detected rather than assumed:
    ///
    /// - a full `Dialogue:` line (an `.ass` file, or `mp4` ASS): 9 fields
    ///   before `Text` (`Layer,Start,End,Style,Name,ML,MR,MV,Effect`);
    /// - libavcodec's internal ASS line: 8 (`ReadOrder,Layer,Style,Name,…`),
    ///   recognizable because field 2 is the numeric `Layer`;
    /// - a Matroska `S_TEXT/ASS` block: 7 (`Layer,Style,Name,…`) — the start
    ///   and end times were lifted into the block's own timing.
    static func assEventText(_ line: String) -> String {
        var body = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var fieldsBeforeText = 7

        if let range = body.range(of: "Dialogue:") {
            body = String(body[range.upperBound...])
            fieldsBeforeText = 9
        } else {
            let head = body.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            if head.count >= 2, Int(head[1].trimmingCharacters(in: .whitespaces)) != nil {
                fieldsBeforeText = 8
            }
        }

        let parts = body.split(
            separator: ",",
            maxSplits: fieldsBeforeText,
            omittingEmptySubsequences: false
        )
        // Too few fields to be an event line: treat the whole thing as text
        // rather than losing the cue.
        guard parts.count > fieldsBeforeText else { return body }
        return String(parts[fieldsBeforeText])
    }

    /// `tx3g` sample: 16-bit big-endian text length, then UTF-8. Anything after
    /// that is style/highlight boxes, which the WebVTT rendition doesn't carry.
    private static func movTextPayload(_ payload: Data) -> String? {
        guard payload.count >= 2 else { return nil }
        let bytes = [UInt8](payload)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, payload.count >= 2 + length else { return nil }
        return String(data: payload[(payload.startIndex + 2)..<(payload.startIndex + 2 + length)], encoding: .utf8)
    }

    // MARK: - Sidecar files

    /// Cues from a whole `.srt` file.
    ///
    /// Lenient on purpose — real sidecars carry a BOM, CRLF endings, missing
    /// sequence numbers and stray blank lines, and a strict parser that drops
    /// the file is worse than one that drops a malformed block.
    static func cues(fromSRT text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var timing: (start: Double, end: Double)?
        var lines: [String] = []

        func flush() {
            defer { timing = nil; lines = [] }
            guard let timing else { return }
            let body = sanitize(lines.joined(separator: "\n"))
            guard !body.isEmpty, timing.end > timing.start else { return }
            cues.append(SubtitleCue(start: timing.start, end: timing.end, text: body))
        }

        for rawLine in normalized(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let parsed = parseTimingLine(line) {
                // A second timing line without a blank separator: the previous
                // block ends here.
                if timing != nil { flush() }
                timing = parsed
                continue
            }
            // A bare number before a timing line is the sequence index.
            if timing == nil, Int(line) != nil { continue }
            if timing != nil { lines.append(line) }
        }
        flush()
        return cues
    }

    /// Cues from a whole `.vtt` file. Header, `NOTE` / `STYLE` / `REGION`
    /// blocks and cue identifiers are dropped; cue settings after the timing
    /// (`line:`, `align:`) are dropped too, since the rendition is served to
    /// AVPlayer's own caption renderer with the system style.
    static func cues(fromWebVTT text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var timing: (start: Double, end: Double)?
        var lines: [String] = []
        var skippingBlock = false

        func flush() {
            defer { timing = nil; lines = [] }
            guard let timing else { return }
            let body = sanitize(lines.joined(separator: "\n"))
            guard !body.isEmpty, timing.end > timing.start else { return }
            cues.append(SubtitleCue(start: timing.start, end: timing.end, text: body))
        }

        for rawLine in normalized(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                skippingBlock = false
                continue
            }
            if skippingBlock { continue }
            if line.hasPrefix("WEBVTT") || line.hasPrefix("X-TIMESTAMP-MAP") { continue }
            if line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
                skippingBlock = true
                continue
            }
            if let parsed = parseTimingLine(line) {
                if timing != nil { flush() }
                timing = parsed
                continue
            }
            if timing != nil { lines.append(line) }
            // else: a cue identifier line — dropped.
        }
        flush()
        return cues
    }

    /// `00:00:01,000 --> 00:00:03,000` (SRT) or `00:01.000 --> 00:03.000`
    /// (WebVTT short form), with any trailing cue settings ignored.
    static func parseTimingLine(_ line: String) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let startText = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let endField = line[arrow.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        guard let start = parseTimestamp(startText), let end = parseTimestamp(endField) else {
            return nil
        }
        return (start, end)
    }

    /// `[HH:]MM:SS[.,]mmm` → seconds. Both separators, both field counts.
    static func parseTimestamp(_ text: String) -> Double? {
        let unified = text.replacingOccurrences(of: ",", with: ".")
        let parts = unified.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var seconds = 0.0
        for part in parts.dropLast() {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        guard let last = Double(parts[parts.count - 1]) else { return nil }
        return seconds * 60 + last
    }

    // MARK: - WebVTT safety

    /// Markup WebVTT understands. Everything else is escaped so a stray `<`
    /// in dialogue can't swallow the rest of the line as a tag.
    private static let allowedTags: Set<String> = [
        "i", "b", "u", "v", "c", "lang", "ruby", "rt",
    ]

    /// Make a payload safe to sit inside a WebVTT cue: no cue-terminating
    /// blank lines, no `-->`, ASS overrides gone, unknown markup escaped.
    static func sanitize(_ text: String) -> String {
        var result = normalized(text)

        // ASS override blocks (`{\i1}`, `{\pos(…)}`) carry styling the
        // rendition deliberately drops — AVPlayer renders it in the system
        // caption style (the same trade the prior art documents).
        result = stripBracedBlocks(result)
        // ASS line breaks and hard spaces, in their literal escaped form.
        result = result.replacingOccurrences(of: "\\N", with: "\n")
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\h", with: " ")

        result = escapeAndMarkup(result)

        // A blank line inside a cue ends it, so collapse runs of newlines and
        // drop trailing whitespace per line.
        let lines = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Removes `{…}` blocks (ASS overrides). Unbalanced braces are left alone
    /// rather than eating the rest of the line.
    private static func stripBracedBlocks(_ text: String) -> String {
        guard text.contains("{") else { return text }
        var output = ""
        var depth = 0
        for character in text {
            switch character {
            case "{": depth += 1
            case "}" where depth > 0: depth -= 1
            default: if depth == 0 { output.append(character) }
            }
        }
        return depth == 0 ? output : text
    }

    /// Escapes `&`, neutralizes `-->`, keeps known tags and escapes the rest.
    private static func escapeAndMarkup(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "&":
                if let entity = entity(in: text, at: index) {
                    output += entity
                    index = text.index(index, offsetBy: entity.count)
                    continue
                }
                output += "&amp;"
            case "<":
                if let tag = tag(in: text, at: index) {
                    // `font` is the one common tag WebVTT has no equivalent for
                    // (SRT files are full of `<font color=…>`); drop the tag,
                    // keep the words.
                    if tag.name != "font" {
                        output += tag.text
                    }
                    index = text.index(index, offsetBy: tag.text.count)
                    continue
                }
                output += "&lt;"
            case "-":
                // `-->` may not appear in a cue payload at all.
                if text[index...].hasPrefix("-->") {
                    output += "--&gt;"
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                output.append(character)
            default:
                output.append(character)
            }
            index = text.index(after: index)
        }
        return output
    }

    /// An HTML character reference starting at `index`, if there is one.
    private static func entity(in text: String, at index: String.Index) -> String? {
        let tail = text[index...]
        guard let semicolon = tail.firstIndex(of: ";"), semicolon != tail.startIndex else { return nil }
        let body = tail[tail.index(after: tail.startIndex)..<semicolon]
        guard !body.isEmpty, body.count <= 10 else { return nil }
        let isNumeric = body.hasPrefix("#") && body.dropFirst().allSatisfy(\.isNumber)
        let isNamed = body.allSatisfy { $0.isLetter || $0.isNumber }
        guard isNumeric || isNamed else { return nil }
        return String(tail[tail.startIndex...semicolon])
    }

    /// A WebVTT-legal tag starting at `index`, with its name, if there is one.
    private static func tag(in text: String, at index: String.Index) -> (name: String, text: String)? {
        let tail = text[index...]
        guard let close = tail.firstIndex(of: ">") else { return nil }
        let inner = tail[tail.index(after: tail.startIndex)..<close]
        guard !inner.isEmpty, !inner.contains("<") else { return nil }
        let nameField = inner.hasPrefix("/") ? inner.dropFirst() : inner[...]
        let name = String(nameField.prefix { $0.isLetter || $0.isNumber }).lowercased()
        guard allowedTags.contains(name) || name == "font" else { return nil }
        return (name, String(tail[tail.startIndex...close]))
    }
}
