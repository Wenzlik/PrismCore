import Testing
import Foundation
@testable import PrismCore

/// Container chapters surface as `SourceInfo.chapters` and ride through to
/// `PrismCoreSession.chapters` — navigation metadata for the host's own
/// chrome, since HLS has no way to carry them to AVPlayer.
///
/// The fixture (`h264_aac_chapters.mkv`) is synthetic — 12 s of testsrc2 +
/// sine with three 4 s Matroska chapters. The titles are deliberately Czech
/// (`Úvod`, `Prostředek`, `Závěr`): chapter titles travel as container
/// metadata, and non-ASCII is exactly where a byte-length/character-length
/// confusion would surface.
@Suite("Container chapters")
struct ChapterTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("Probe reports Matroska chapters with titles and boundaries, in start order")
    func probeReportsChapters() throws {
        let info = try SourceProbe.probe(url: fixture("h264_aac_chapters.mkv"))

        try #require(info.chapters.count == 3)
        #expect(info.chapters.map(\.title) == ["Úvod", "Prostředek", "Závěr"])
        #expect(info.chapters.map(\.start) == [0, 4, 8])
        #expect(info.chapters.map(\.end) == [4, 8, 12])
    }

    @Test("A source without chapters reports an empty list, not a failure")
    func chapterlessSourceReportsEmpty() throws {
        let info = try SourceProbe.probe(url: fixture("h264_aac.mkv"))
        #expect(info.chapters.isEmpty)
    }

    @Test("Session exposes the source's chapters once start() returns")
    func sessionExposesChapters() async throws {
        let session = try PrismCoreSession(url: fixture("h264_aac_chapters.mkv"))
        _ = try await session.start()
        // The chapters were published before the first packet, so they are
        // readable now — and they survive the stop, being probe facts, not
        // produced artifacts. Stop first so a failed expectation can't leak
        // the producer thread.
        let chapters = await session.chapters
        await session.stop()

        try #require(chapters.count == 3)
        #expect(chapters[1].title == "Prostředek")
        #expect(chapters[1].start == 4)
        #expect(chapters[1].end == 8)
    }
}
