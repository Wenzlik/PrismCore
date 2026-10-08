import Testing
import Foundation
@testable import PrismCore
#if os(macOS)
@testable import prismcore_cli
#endif

/// The report is a contract read by people who were not there: it has to say
/// what the session actually did, read back what it wrote, and above all never
/// carry a secret a host handed the engine.
@Suite("Session diagnostic report", .serialized, .timeLimit(.minutes(1)))
struct SessionDiagnosticReportTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func text(_ report: SessionDiagnosticReport) throws -> String {
        String(decoding: try report.jsonData(), as: UTF8.self)
    }

    // MARK: - What a session reports

    @Test("A planned session reports its plan, checkpoints, renditions and verdict")
    func reportPlannedSession() async throws {
        let source = try fixture("hevc_eac3.mkv")
        let session = try PrismCoreSession(url: source)
        _ = try await session.start()
        let report = await session.diagnosticReport()
        let renditions = await session.audioRenditionProductions
        let workDirectory = await session.workDirectory
        await session.stop()

        #expect(report.schemaVersion == SessionDiagnosticReport.currentSchemaVersion)
        #expect(report.engine.prismCoreVersion == PrismCoreVersion.current)
        #expect(report.engine.libraries.count == FFmpegBuild.libraries.count)
        #expect(report.startup.checkpoints.map(\.phase) == [
            "sourceOpened", "streamInfoResolved", "segmentPlanReady",
            "firstVideoSegmentWritten", "playlistServable",
        ])
        #expect(report.startup.planOrigin == SegmentPlanOrigin.builtFromSource.rawValue)
        #expect((report.startup.planSegments ?? 0) > 0)
        #expect(report.startup.failure == nil)
        #expect(report.decision?.engine == "remux")
        #expect(report.source.info?.video?.codecName == "hevc")
        #expect(report.source.info?.audio.first?.codecName == "eac3")
        #expect(!renditions.isEmpty)
        #expect(report.runtime?.audioRenditionSummary == AudioRenditionProduction.summary(renditions))
        #expect(report.runtime?.started == true)
        #expect(report.runtime?.retention.budgetBytes == 1 << 30)
        #expect(report.options?.keyframeIndexCacheEnabled == false)

        // A local source is named, never located.
        #expect(report.source.fileName == "hevc_eac3.mkv")
        #expect(report.source.url == nil)
        let json = try text(report)
        #expect(!json.contains(source.deletingLastPathComponent().path))
        #expect(!json.contains(workDirectory.path))
    }

    @Test("A sequential session reports its origin, and the repairs it made")
    func reportSequentialSessionWithRepairs() async throws {
        // No container duration, no plan (`SegmentPlan.build`): the one
        // sequential shape a local fixture reaches through a plain session.
        let sequential = try PrismCoreSession(url: try fixture("h264_aac_noduration.mkv"))
        _ = try await sequential.start()
        let sequentialReport = await sequential.diagnosticReport()
        await sequential.stop()
        #expect(sequentialReport.startup.planOrigin == SegmentPlanOrigin.sequential.rawValue)
        #expect(sequentialReport.startup.planSegments == 0)

        // Driven to the end by the verifier, so every repair is counted.
        let broken = try BrokenTimestampFixture.write(from: try fixture("h264_aac_30s.mkv"))
        defer { try? FileManager.default.removeItem(at: broken.deletingLastPathComponent()) }
        let session = try PrismCoreSession(url: broken)
        _ = try await SegmentVerifier.verify(playlist: try await session.start())
        let report = await session.diagnosticReport()
        let repairs = try #require(await session.timestampRepairs)
        await session.stop()
        let reported = try #require(report.runtime?.timestampRepairs)
        #expect(reported.nonMonotonicDTSBumped == repairs.nonMonotonicDTSBumped)
        #expect(reported.ptsRaisedToDTS == repairs.ptsRaisedToDTS)
        #expect(reported.total == repairs.total)
    }

    @Test("The JSON reads back to the same report, byte-stable and key-sorted")
    func roundTrip() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        _ = try await session.start()
        let report = await session.diagnosticReport()
        await session.stop()

        let data = try report.jsonData()
        #expect(try SessionDiagnosticReport(jsonData: data) == report)
        #expect(try report.jsonData() == data)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["decision", "engine", "options", "runtime", "schemaVersion", "source", "startup"])
        // Top-level keys sit at two spaces of indent, in sorted order.
        let json = String(decoding: data, as: UTF8.self)
        let positions = object.keys.sorted().compactMap { json.range(of: "\n  \"\($0)\"")?.lowerBound }
        #expect(positions.count == object.count)
        #expect(positions == positions.sorted())
    }

    // MARK: - Redaction

    @Test("Headers, query, fragment, credentials and disk paths never reach the report")
    func redactsSecrets() async throws {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyframeCacheSecretDir-\(UUID().uuidString)", isDirectory: true)
        let subtitle = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarSecretDir-\(UUID().uuidString)/movie.srt")
        // Port 9 refuses at once: the failed start puts the error's own
        // description, which can quote the URL whole, into the report.
        let url = try #require(URL(string:
            "http://alice:hunter22pass@127.0.0.1:9/library/movie.mkv?X-Plex-Token=PLEXSECRET123&q=1#fragsecret"))
        let session = try PrismCoreSession(
            url: url,
            httpHeaders: ["Authorization": "Bearer TOPSECRETBEARER", "X-Api-Key": "HEADERKEY99"],
            display: .conservative,
            keyframeIndexCacheDirectory: cache
        )
        try await session.addExternalSubtitle(url: subtitle, language: "cs")
        await #expect(throws: (any Error).self) { try await session.start(startupTimeout: .seconds(10)) }
        let report = await session.diagnosticReport()
        let workDirectory = await session.workDirectory
        await session.stop()

        #expect(report.source.url == "http://127.0.0.1:9/library/movie.mkv")
        #expect(report.source.httpHeaderCount == 2)
        #expect(report.startup.failure != nil, "the failed start should be in the report")
        #expect(report.options?.keyframeIndexCacheEnabled == true)
        #expect(report.options?.externalSubtitleCount == 1)

        let json = try text(report)
        for secret in [
            "Authorization", "Bearer", "TOPSECRETBEARER", "X-Api-Key", "HEADERKEY99",
            "X-Plex-Token", "PLEXSECRET123", "fragsecret", "alice", "hunter22pass",
            "KeyframeCacheSecretDir", "SidecarSecretDir", workDirectory.path,
        ] {
            #expect(!json.contains(secret), "\(secret) leaked into the report")
        }
    }

    /// The second layer: free text the engine did not write, quoting the
    /// source URL whole the way a Foundation error does.
    @Test("An error that quotes the URL is scrubbed of its secrets")
    func scrubsErrorText() throws {
        let url = try #require(URL(string: "https://bob:pw1234@media.example/v.mkv?X-Plex-Token=PLEXSECRET123"))
        let redaction = Redaction(url: url, httpHeaders: ["Authorization": "Bearer TOPSECRETBEARER"])
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            "NSErrorFailingURLStringKey": url.absoluteString,
            NSLocalizedDescriptionKey: "token PLEXSECRET123 sent with Bearer TOPSECRETBEARER",
        ])
        let failure = redaction.failure(error)
        for secret in ["PLEXSECRET123", "TOPSECRETBEARER", "pw1234"] {
            #expect(!failure.description.contains(secret), "\(secret) survived: \(failure.description)")
        }
        #expect(Redaction.location(of: url).url == "https://media.example/v.mkv")
    }

    /// A redirect target is a URL the session never held: its query token
    /// only exists inside the error, so only the generic URL pass can see it.
    /// The redirect carries the source's own token too, ahead of the CDN's:
    /// cutting the known one first used to end the URL match at its
    /// `<redacted>` and leave the CDN token behind it.
    @Test("A redirect URL quoted by an error loses credentials and query")
    func scrubsRedirectURL() throws {
        let url = try #require(URL(string: "https://origin.example/movie.mkv?X-Plex-Token=ORIG1234"))
        let redaction = Redaction(url: url, httpHeaders: [:])
        let cdn = "https://user:cdnpass9@cdn.example/file.mkv?old=ORIG1234&token=CDNSECRET99#frag77"
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            "NSErrorFailingURLStringKey": cdn,
            NSURLErrorFailingURLErrorKey: try #require(URL(string: cdn)),
        ])
        let failure = redaction.failure(PrismCoreError.originUnreachable(
            status: nil, url: try #require(URL(string: cdn)), underlying: underlying))
        for secret in ["CDNSECRET99", "cdnpass9", "frag77", "ORIG1234"] {
            #expect(!failure.description.contains(secret), "\(secret) survived: \(failure.description)")
        }
        #expect(failure.description.contains("cdn.example/file.mkv"))
    }

    /// Track names are the muxer's free text: a signed URL or the path a
    /// subtitle was read from must not ride out in them, ordinary names must.
    @Test("Track titles and languages are scrubbed, ordinary names kept")
    func scrubsTrackMetadata() throws {
        let url = try #require(URL(string: "https://origin.example/movie.mkv?X-Plex-Token=ORIG1234"))
        let redaction = Redaction(url: url, httpHeaders: [:])
        let audio = ["https://media.example/movie?token=SECRET123", "Commentary AC3/DTS 5.1 / 2.0"].enumerated().map {
            AudioTrackInfo(
                streamIndex: $0.offset + 1, codecName: "aac", profileName: nil, channelCount: 2,
                channelLayoutDescription: "stereo", sampleRate: 48_000, language: "eng",
                title: $0.element, isObjectAudio: false, copyability: .streamCopy
            )
        }
        let subtitle = SubtitleTrackInfo(
            streamIndex: 3, codecName: "subrip", language: "ORIG1234",
            title: "/Users/alice/private/movie.srt", kind: .textRendition, isDefault: false,
            isForced: false, isHearingImpaired: false, isOCRReadable: false
        )
        let info = SourceInfo(formatName: "matroska", duration: 60, video: nil,
                              audioTracks: audio, subtitleTracks: [subtitle])
        let source = redaction.source(url: url, httpHeaders: [:], hostInput: false, info: info, structure: nil)
        let json = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        for secret in ["SECRET123", "ORIG1234", "alice", "private"] {
            #expect(!json.contains(secret), "\(secret) leaked: \(json)")
        }
        #expect(source.info?.audio.last?.title == "Commentary AC3/DTS 5.1 / 2.0")
        #expect(source.info?.audio.first?.language == "eng")
    }

    /// A path the session never held — a host `input:` factory's cache file,
    /// a Windows subtitle path a muxer stored — has no known value to cut,
    /// so free text loses any absolute path by shape. A URL keeps its host
    /// and path, an error its wording.
    @Test("Unknown absolute paths leave error text and track metadata")
    func scrubsUnknownPaths() throws {
        let url = try #require(URL(string: "https://origin.example/movie.mkv"))
        let redaction = Redaction(url: url, httpHeaders: [:])
        let failure = redaction.failure(NSError(domain: "Factory", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Cannot open /Users/alice/private/cache/movie.mkv: Input/output error; "
                + "also file:///Users/alice/private/x.mkv, /Users/alice/My Private/y.mkv and https://cdn.example/a/b.mkv",
        ]))
        let decision = redaction.decision(.failure(NSError(domain: "Factory", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Cannot open /Users/alice/private/cache/movie.mkv",
        ])))
        let titles = [#"C:\Users\alice\private\movie.srt"#, "D:/alice/private/movie.srt",
                      #"\\nas\alice\private\movie.srt"#]
        let subtitles = titles.enumerated().map {
            SubtitleTrackInfo(
                streamIndex: $0.offset, codecName: "subrip", language: nil, title: $0.element,
                kind: .textRendition, isDefault: false, isForced: false, isHearingImpaired: false,
                isOCRReadable: false
            )
        }
        let info = SourceInfo(formatName: "matroska", duration: 60, video: nil,
                              audioTracks: [], subtitleTracks: subtitles)
        let source = redaction.source(url: url, httpHeaders: [:], hostInput: true, info: info, structure: nil)
        let json = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        for text in [failure.description, decision.reason, json] {
            for secret in ["alice", "private", "Private"] {
                #expect(!text.contains(secret), "\(secret) leaked: \(text)")
            }
        }
        #expect(failure.description.contains("Input/output error"))
        #expect(failure.description.contains("https://cdn.example/a/b.mkv"))
    }

    // MARK: - Without a session

    @Test("A software-routed source gets a report from its probe alone")
    func reportWithoutSession() async throws {
        let probed = try SourceProbe.open(url: try fixture("vp9.webm"))
        let report = PrismCoreEngine.diagnosticReport(
            for: probed, decision: Result { try PrismCoreEngine.decide(for: probed.info) }
        )
        #expect(report.decision?.engine == "software")
        #expect(report.source.info?.video?.codecName == "vp9")
        #expect(report.startup.probeTiming != nil)
        #expect(report.options == nil)
        #expect(report.runtime == nil)

        let declined = PrismCoreEngine.diagnosticReport(
            for: probed, decision: .failure(PrismCoreEngine.RoutingFailure.noDecoderForVideo(codecName: "vp9"))
        )
        #expect(declined.decision?.engine == nil)
        #expect(declined.decision?.reason.contains("vp9") == true)
    }

    #if os(macOS)
    @Test("probe --json prints one parseable report")
    func cliProbeJSON() throws {
        let probed = try SourceProbe.open(url: try fixture("vp9.webm"))
        let output = try ProbeCommand.jsonReport(probed, decision: Result { try PrismCoreEngine.decide(for: probed.info) })
        let report = try SessionDiagnosticReport(jsonData: Data(output.utf8))
        #expect(report.decision?.engine == "software")
        #expect(try JSONSerialization.jsonObject(with: Data(output.utf8)) is [String: Any])
    }
    #endif

    // MARK: - Bounds and version

    @Test("The session keeps only the newest playback events")
    func retainedEventsAreBounded() {
        let sink = PlaybackEventSink()
        for index in 0..<100 { sink.yield(.serveTimedOut(path: "seg\(index).m4s")) }
        let retained = sink.retained
        #expect(retained.events.count == PlaybackEventSink.retainedCount)
        #expect(retained.dropped == 100 - PlaybackEventSink.retainedCount)
        #expect(retained.events.last?.event == .serveTimedOut(path: "seg99.m4s"))
    }

    /// The constant is hand-written (SwiftPM cannot read a package's tag), so
    /// the release that forgets it must fail here rather than ship reports
    /// naming the previous version.
    @Test("PrismCoreVersion matches the newest released CHANGELOG heading")
    func versionMatchesChangelog() throws {
        let changelog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        let newest = try #require(text.firstMatch(of: /\n## \[(\d+\.\d+\.\d+)\]/)?.1)
        #expect(String(newest) == PrismCoreVersion.current)
    }
}
