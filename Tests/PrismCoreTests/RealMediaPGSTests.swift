import Testing
import Foundation
@testable import PrismCore

/// Opt-in verification of the OCR-rendition pipeline against real PGS media —
/// no FFmpeg build can *encode* PGS, so no committed fixture can carry it.
///
///     PRISMCORE_PGS_MEDIA=/path/to/remux.mkv swift test --filter RealMediaPGS
///
/// Plays the session's own serving path end to end: master declares the PGS
/// renditions, the producer demuxes, the decoder composites, Vision reads, and
/// the cues land in served `.vtt` segments.
@Suite(
    "Real media: PGS renditions",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_PGS_MEDIA"] != nil)
)
struct RealMediaPGSTests {

    @Test("A PGS track is served as a rendition whose segments carry recognized cues")
    func pgsBecomesReadableRendition() async throws {
        let path = ProcessInfo.processInfo.environment["PRISMCORE_PGS_MEDIA"] ?? ""
        let info = try SourceProbe.probe(url: URL(fileURLWithPath: path))
        let pgsTracks = info.subtitleTracks.filter { $0.codecName.contains("pgs") }
        try #require(!pgsTracks.isEmpty, "media has no PGS track")

        let session = try PrismCoreSession(url: URL(fileURLWithPath: path))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        // The master must declare at least as many subtitle renditions as
        // there are text + PGS tracks.
        let master = try String(contentsOf: playlist, encoding: .utf8)
        try #require(master.contains("#EXT-X-STREAM-INF"), "expected a master playlist")
        let subtitleLines = master.split(separator: "\n").filter { $0.contains("TYPE=SUBTITLES") }
        #expect(
            subtitleLines.count >= pgsTracks.count,
            "master declares \(subtitleLines.count) subtitle renditions for \(pgsTracks.count) PGS tracks"
        )

        // Walk the presentation like a player: media segment N (drives the
        // producer), then the first PGS rendition's segment N — until a cue
        // shows up. Films open quiet, so give it a few minutes of runtime.
        let mediaURI = try #require(PrismCoreSession.playlistURIs(inMaster: master).last)
        let mediaPlaylistURL = playlist.deletingLastPathComponent().appendingPathComponent(mediaURI)
        let mediaPlaylist = try String(contentsOf: mediaPlaylistURL, encoding: .utf8)
        let mediaSegments = mediaPlaylist.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }

        // First PGS rendition directory: text tracks are declared first, in
        // stream order — count the text tracks to find where PGS starts.
        let textCount = info.textSubtitleTracks.count
        let subsDirectory = "subs\(textCount)"

        var recognized: [String] = []
        for index in 0..<min(mediaSegments.count, 60) {
            let mediaURL = mediaPlaylistURL.deletingLastPathComponent()
                .appendingPathComponent(String(mediaSegments[index]))
            _ = try? Data(contentsOf: mediaURL)

            let vttURL = playlist.deletingLastPathComponent()
                .appendingPathComponent("\(subsDirectory)/seg\(String(format: "%05d", index)).vtt")
            guard let vtt = try? String(contentsOf: vttURL, encoding: .utf8) else { continue }
            let cueLines = vtt.split(separator: "\n")
                .filter { !$0.hasPrefix("WEBVTT") && !$0.hasPrefix("X-TIMESTAMP") && !$0.contains("-->") }
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            recognized.append(contentsOf: cueLines)
            if recognized.count >= 3 { break }
        }

        print("PGS OCR cues recognized: \(recognized.prefix(6))")
        #expect(recognized.count >= 1, "no cue recognized in the first minutes of the film")
    }
}
