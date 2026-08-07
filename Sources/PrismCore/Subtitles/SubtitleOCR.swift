import Foundation
import CoreGraphics
#if canImport(Vision)
import Vision
#endif

/// On-device text recognition over a decoded subtitle composition — the piece
/// that turns a bitmap subtitle track into a WebVTT rendition.
///
/// Lossy by design: typography, colour and exact positioning die here, and a
/// stylized karaoke font can defeat the recognizer entirely. What survives is
/// the part that matters on the native path — text that rides the rendition
/// machinery and therefore PiP, AirPlay and the system's subtitle menu, for
/// tracks that otherwise would not exist there at all.
enum SubtitleOCR {

    /// Whether this platform can recognize at all. `false` compiles the whole
    /// bitmap-rendition feature out of the session's behaviour.
    static var isAvailable: Bool {
        #if canImport(Vision)
        return true
        #else
        return false
        #endif
    }

    /// Recognize the composition's text, top line first. `nil` when nothing
    /// legible was found (an empty cue must not be written — a blank entry in
    /// the subtitle menu is worse than none).
    static func recognize(_ image: CGImage, language: String?) -> String? {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        // Subtitle glyphs are large and high-contrast; `.accurate` still runs
        // in tens of milliseconds at these sizes and survives stylized fonts
        // far better than `.fast`. Correction stays ON: it repairs the glyph
        // confusions OCR actually makes (l/I, rn/m) and the occasional
        // "corrected" name costs less than a line of garbage.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let match = visionLanguage(for: language, in: request) {
            request.recognitionLanguages = [match]
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty
        else { return nil }

        // Top-to-bottom: Vision's normalized origin is bottom-left, so a
        // higher `midY` is a *higher* line.
        let lines = observations
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
        #else
        return nil
        #endif
    }

    #if canImport(Vision)
    /// The Vision identifier for a container language tag, or `nil` to let
    /// the recognizer use its defaults.
    ///
    /// Containers speak ISO 639 — Matroska metadata is usually the
    /// *three*-letter 639-2 form ("cze", "ger") — while Vision wants BCP-47
    /// ("cs-CZ"). A raw pass-through therefore silently fell back to default
    /// languages for exactly the tracks that most need the hint, so the tag
    /// is normalized to two letters first and then matched against what this
    /// OS version actually supports.
    static func visionLanguage(
        for language: String?, in request: VNRecognizeTextRequest
    ) -> String? {
        guard var tag = language?.lowercased(), !tag.isEmpty else { return nil }
        tag = iso639_1[tag] ?? tag
        guard let supported = try? request.supportedRecognitionLanguages() else { return nil }
        return supported.first {
            let identifier = $0.lowercased()
            return identifier == tag || identifier.hasPrefix(tag + "-")
        }
    }

    /// The 639-2 → 639-1 pairs that occur in real libraries; both the B and T
    /// variants where they differ. An unmapped tag just skips the hint.
    private static let iso639_1: [String: String] = [
        "cze": "cs", "ces": "cs", "eng": "en", "ger": "de", "deu": "de",
        "fre": "fr", "fra": "fr", "spa": "es", "ita": "it", "por": "pt",
        "dut": "nl", "nld": "nl", "pol": "pl", "slo": "sk", "slk": "sk",
        "rus": "ru", "ukr": "uk", "jpn": "ja", "kor": "ko", "chi": "zh",
        "zho": "zh", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi",
        "hun": "hu", "gre": "el", "ell": "el", "tur": "tr", "ara": "ar",
    ]
    #endif
}
