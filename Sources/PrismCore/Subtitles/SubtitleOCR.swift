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
        // far better than `.fast`. No language correction: subtitles are full
        // of names the corrector would "fix".
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if let language, !language.isEmpty {
            // ISO 639 code straight in; Vision accepts identifiers it knows
            // and the request falls back to defaults for ones it doesn't.
            request.recognitionLanguages = [language]
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty
        else { return nil }

        // Top-to-bottom: Vision's normalized origin is bottom-left, so a
        // higher `minY` is a *higher* line.
        let lines = observations
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
        #else
        return nil
        #endif
    }
}
