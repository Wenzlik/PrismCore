import Testing
import Foundation
@testable import PrismCore

/// The shared diagnostics behind `prismcore-cli` — hermetic, on fixtures, so
/// what the CLI prints is pinned by the suite rather than by whoever last ran
/// it by hand.
@Suite("Diagnostics", .serialized)
struct DiagnosticsTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    // MARK: StartupCheckpointRun

    /// The line's shape is its contract: a device log and a bench run are
    /// compared term by term, so a reworded term breaks the comparison
    /// silently. The opt-in benchmark prints this same value.
    @Test("The checkpoint line has the host log's shape")
    func checkpointLineShape() async throws {
        let run = try await StartupCheckpointRun.measure(
            url: try fixture("h264_aac_30s.mkv"), budget: .seconds(10), coordinatedHTTP: false
        )
        #expect(run.failure == nil)
        #expect(run.probeLine.wholeMatch(
            of: /probe \d+ms \(open \d+ \+ info \d+ \+ describe \d+\)/) != nil,
            "probe line: \(run.probeLine)")
        let terms = run.checkpoints.map { String($0.split(separator: " ")[0]) }
        #expect(terms == ["open", "probe", "plan", "segment", "servable"], "checkpoints: \(run.checkpoints)")
        #expect(run.checkpoints.contains { $0.wholeMatch(of: /plan \d+ms \(\w+, \d+ seg\)/) != nil })
        let lines = run.rendered.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("startup open "))
        #expect(lines[2].hasPrefix("start() returned in "))
    }

    // MARK: SegmentVerifier — playlist parsing

    @Test("A media playlist parses into its init, segments, durations and end")
    func parsesMediaPlaylist() {
        let text = """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:6.00000,
            seg00000.m4s
            #EXTINF:2.5,
            seg00001.m4s
            #EXT-X-ENDLIST
            """
        let media = SegmentVerifier.parseMediaPlaylist(text)
        #expect(media.initURI == "init.mp4")
        #expect(media.segments == [.init(uri: "seg00000.m4s", duration: 6), .init(uri: "seg00001.m4s", duration: 2.5)])
        #expect(media.isEnded)
        #expect(!SegmentVerifier.parseMediaPlaylist("#EXTM3U\n#EXTINF:6,\na.m4s\n").isEnded)
    }

    // MARK: SegmentVerifier — over a served session

    @Test("Every segment of a served H.264 + AAC remux decodes on its own")
    func servedSegmentsVerify() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let report = try await SegmentVerifier.verify(playlist: playlist)
        #expect(!report.hasErrors, "findings: \(report.findings)")
        let video = try #require(report.playlists.first { $0.videoFrames > 0 })
        // 30 s at 24 fps, every picture decoded exactly once across segments.
        #expect(video.videoFrames == 720)
        #expect(report.playlists.contains { $0.audioFrames > 0 }, "the audio rendition was not checked")
    }

    /// The HEVC fixture is an open-GOP encode: its second segment opens on a
    /// CRA whose one leading picture references the first GOP (system
    /// ffprobe decodes 144 of its 145 packets too). That is the source's
    /// structure, which stream copy cannot change — so it must surface as a
    /// warning, not fail the check.
    @Test("An open-GOP leading picture is a warning, not a failure")
    func openGOPIsWarning() async throws {
        let session = try PrismCoreSession(url: try fixture("hevc_eac3.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let report = try await SegmentVerifier.verify(playlist: playlist)
        #expect(!report.hasErrors, "findings: \(report.findings)")
        #expect(report.findings.contains { $0.severity == .warning && $0.problem.contains("leading picture") })
    }

    // MARK: SegmentVerifier — broken bytes

    /// A real init + segment pair from a served session, for the corruption
    /// tests to break.
    private func servedPair() async throws -> (initSegment: Data, segment: Data) {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let base = playlist.deletingLastPathComponent()
        let (master, _) = try await URLSession.uncached.data(from: playlist)
        let variant = try #require(PrismCoreSession.playlistURIs(inMaster: String(decoding: master, as: UTF8.self)).last)
        let mediaURL = base.appendingPathComponent(variant)
        let (mediaText, _) = try await URLSession.uncached.data(from: mediaURL)
        let media = SegmentVerifier.parseMediaPlaylist(String(decoding: mediaText, as: UTF8.self))
        let initURI = try #require(media.initURI)
        let segmentURI = try #require(media.segments.dropFirst().first?.uri)
        let (initSegment, _) = try await URLSession.uncached.data(
            from: mediaURL.deletingLastPathComponent().appendingPathComponent(initURI))
        let (segment, _) = try await URLSession.uncached.data(
            from: mediaURL.deletingLastPathComponent().appendingPathComponent(segmentURI))
        return (initSegment, segment)
    }

    @Test("A clean pair passes, a truncated or garbage segment fails with a reason")
    func brokenSegmentsFail() async throws {
        let (initSegment, segment) = try await servedPair()

        let clean = SegmentVerifier.verify(initSegment: initSegment, mediaSegment: segment)
        #expect(!clean.hasErrors, "\(clean.problems)")
        #expect(clean.videoFrames > 0)

        // Cut mid-mdat: the moof still promises every sample, the bytes for
        // most of them are gone.
        let truncated = SegmentVerifier.verify(
            initSegment: initSegment, mediaSegment: segment.prefix(segment.count / 3)
        )
        #expect(truncated.hasErrors, "a truncated segment passed: \(truncated.problems)")

        let garbage = SegmentVerifier.verify(
            initSegment: initSegment, mediaSegment: Data(repeating: 0xA5, count: 4096)
        )
        #expect(garbage.hasErrors, "garbage passed: \(garbage.problems)")
        #expect(garbage.videoFrames == 0)
    }

    @Test("A declared duration far from the media's is a warning")
    func durationMismatchWarns() async throws {
        let (initSegment, segment) = try await servedPair()
        let check = SegmentVerifier.verify(initSegment: initSegment, mediaSegment: segment, expectedDuration: 60)
        #expect(!check.hasErrors)
        #expect(check.problems.contains { $0.0 == .warning && $0.1.contains("#EXTINF") })
    }
}
