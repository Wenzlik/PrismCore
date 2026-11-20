import Foundation

/// One cue of a parsed subtitle document, with its styling kept.
public struct StyledSubtitleCue: Sendable, Equatable, Codable {
    /// Seconds on the document's own timeline.
    public var start: Double
    public var end: Double
    public var text: StyledSubtitleText
    /// The same cue as a WebVTT-safe payload — what PrismCore's own WebVTT
    /// renditions carry, for a host that still needs one (an AVPlayer
    /// fallback for PiP or AirPlay).
    public var webVTTText: String

    public init(start: Double, end: Double, text: StyledSubtitleText, webVTTText: String) {
        self.start = start
        self.end = end
        self.text = text
        self.webVTTText = webVTTText
    }
}

/// PrismCore's text-subtitle parsers for sources PrismCore does not demux —
/// a server's sidecar, a downloaded `.srt`, a cue another engine hands the
/// host — so every subtitle a host shows can come through one cue model and
/// one set of rules, whichever engine plays the video.
///
/// Pure functions, no I/O, safe from any thread. The rules are the ones the
/// demuxed path uses: the same markup becomes the same runs.
public enum SubtitleTextParser {

    public enum DocumentFormat: Sendable, Equatable {
        case srt
        case webVTT
        /// `.ass` and `.ssa` alike: styles, `Format:` lines and `Dialogue:`
        /// events. For the file's real look, give the same bytes to
        /// `ASSSubtitleRenderer(script:)` instead.
        case ass

        /// The format a file name implies, or `nil` for an unknown extension.
        public init?(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "srt": self = .srt
            case "vtt", "webvtt": self = .webVTT
            case "ass", "ssa": self = .ass
            default: return nil
            }
        }
    }

    /// The payload of one timed sample, as a demuxer or player hands it over.
    public enum PayloadFormat: Sendable, Equatable {
        /// SubRip / plain text (Matroska `S_TEXT/UTF8`).
        case subrip
        /// WebVTT cue payload (no timing line; settings travel separately).
        case webVTT
        /// One ASS event line: a `Dialogue:` line, a Matroska `S_TEXT/ASS`
        /// block, or libavcodec's ASS line.
        case assEvent
        /// ISO timed text (`tx3g` / mov_text) sample, `styl` box included.
        case tx3g
    }

    /// Every cue of a whole document, sorted by start. Unparseable blocks
    /// are skipped, never fatal; an empty result means nothing was readable.
    public static func cues(from text: String, format: DocumentFormat) -> [StyledSubtitleCue] {
        let cues: [SubtitleCue]
        switch format {
        case .srt: cues = TextSubtitleConverter.cues(fromSRT: text)
        case .webVTT: cues = TextSubtitleConverter.cues(fromWebVTT: text)
        case .ass: cues = TextSubtitleConverter.cues(fromASS: text)
        }
        return cues.map { cue in
            StyledSubtitleCue(
                start: cue.start, end: cue.end,
                text: cue.styled ?? StyledSubtitleText(runs: [StyledTextRun(text: cue.text)], placement: cue.placement),
                webVTTText: cue.text
            )
        }
    }

    /// `cues(from:format:)` on raw bytes: UTF-8, else Latin-1 (old sidecars),
    /// and — with no format — WebVTT, then ASS, then SRT, by content.
    public static func cues(from data: Data, format: DocumentFormat? = nil) -> [StyledSubtitleCue] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return [] }
        if let format { return cues(from: text, format: format) }
        let head = text.prefix(4_096)
        if head.contains("WEBVTT") { return cues(from: text, format: .webVTT) }
        if head.contains("[Script Info]") || head.contains("[Events]") { return cues(from: text, format: .ass) }
        return cues(from: text, format: .srt)
    }

    /// One sample's styled text, or `nil` when it has no visible text.
    /// `assHeader` is the ASS track's script header (Matroska CodecPrivate,
    /// or a `.ass` file's head) — without it, events get no style colours
    /// and `\pos` is dropped. `tx3gSampleDescription` is a tx3g track's
    /// TextSampleEntry from its display flags on (what FFmpeg exposes as the
    /// stream's extradata) — without it, samples get no default style,
    /// justification or fonts.
    public static func styledText(
        payload: Data, format: PayloadFormat, assHeader: Data? = nil, tx3gSampleDescription: Data? = nil
    ) -> StyledSubtitleText? {
        let kind: TextSubtitleConverter.Kind
        switch format {
        case .subrip: kind = .subrip
        case .webVTT: kind = .webvtt
        case .assEvent: kind = .ass
        case .tx3g: kind = .movText
        }
        let header = kind == .ass ? ASSScriptHeader(data: assHeader) : nil
        guard let converted = TextSubtitleConverter.convert(
            payload, kind: kind, playResolution: header?.playResolution, assHeader: header,
            movText: kind == .movText ? TextSubtitleConverter.MovTextDescription(tx3gSampleDescription) : nil
        ), let styled = converted.styled, !styled.runs.isEmpty else { return nil }
        return styled
    }
}
