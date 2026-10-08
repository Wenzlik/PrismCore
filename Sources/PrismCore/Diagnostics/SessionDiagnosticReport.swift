import Foundation

/// Everything the engine knows about one playback, as one value a host can
/// attach to a bug report: which build, what the source turned out to be,
/// where it was routed and why, where startup spent its time, and what the
/// running session ran into.
///
/// It exists because all of that was already known, but in a dozen places
/// and in no serializable shape, so every field report started with the
/// same round of questions (which build, which container, planned or
/// sequential, how many repairs) the engine could have answered itself.
///
/// Take one with `PrismCoreSession.diagnosticReport()`, or, for a source that
/// never got a session (declined, or routed to the software path), with
/// `PrismCoreEngine.diagnosticReport(for:decision:)`. `jsonData()` is the
/// shape to paste.
///
/// **The JSON is a contract.** `schemaVersion` names it; fields are only ever
/// added, never renamed or repurposed, so a reader written against version 1
/// keeps reading every later report.
///
/// **Nothing secret leaves in it** — see `Redaction` for what is withheld:
/// HTTP headers, the URL's query, fragment and credentials, and every path on
/// this device's disk. Only values the engine actually holds are reported;
/// anything it did not measure is absent rather than guessed.
public struct SessionDiagnosticReport: Sendable, Equatable, Codable {

    /// The schema this build writes. Bumped only for an additive change a
    /// reader might want to detect; never for a breaking one, which this
    /// schema does not make.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var engine: Engine
    public var source: Source
    /// The routing verdict. `nil` only when the source was never described
    /// (a session reporting before its remux opened anything).
    public var decision: Decision?
    /// What the session was built with. `nil` for a report taken from a
    /// probe alone, where no session existed to have options.
    public var options: Options?
    public var startup: Startup
    /// The running session. `nil` for a report taken from a probe alone.
    public var runtime: Runtime?

    /// Pretty-printed with sorted keys, so two reports diff line by line and
    /// the same report always prints the same bytes.
    ///
    /// Never throws for want of a finite number: a non-finite double (a
    /// frame rate libavformat could not work out, say) is written as the
    /// string `"nan"`/`"inf"`/`"-inf"`, because a "copy diagnostics" button
    /// that fails on the very source it is meant to describe is no button.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = Self.floatStrategy.encoding
        return try encoder.encode(self)
    }

    /// Reads what `jsonData()` wrote.
    public init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = Self.floatStrategy.decoding
        self = try decoder.decode(Self.self, from: jsonData)
    }

    private static let floatStrategy = (
        encoding: JSONEncoder.NonConformingFloatEncodingStrategy.convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"),
        decoding: JSONDecoder.NonConformingFloatDecodingStrategy.convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    )

    init(
        engine: Engine = .current,
        source: Source,
        decision: Decision?,
        options: Options?,
        startup: Startup,
        runtime: Runtime?
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.engine = engine
        self.source = source
        self.decision = decision
        self.options = options
        self.startup = startup
        self.runtime = runtime
    }

    // MARK: - Engine

    /// Which build answered. `FFmpegBuild.configuration` is deliberately not
    /// here: the configure line carries the build machine's paths.
    public struct Engine: Sendable, Equatable, Codable {
        public var prismCoreVersion: String
        /// FFmpeg's own build identity (`FFmpegBuild.versionInfo`).
        public var ffmpegVersion: String
        public var libraries: [Library]
        /// Names of the libraries whose major version disagrees with the
        /// headers this build saw. Empty on a sane install.
        public var mismatchedLibraries: [String]
        public var capabilities: Capabilities
        /// `iOS`, `tvOS`, `visionOS` or `macOS`.
        public var platform: String
        public var osVersion: String

        public struct Library: Sendable, Equatable, Codable {
            public var name: String
            public var compiled: String
            public var loaded: String
            public var isABIMatched: Bool
        }

        /// `FFmpegBuild.Capabilities`, field for field.
        public struct Capabilities: Sendable, Equatable, Codable {
            public var hasEAC3Encoder: Bool
            public var audioBridgeEncoder: String?
            public var av1Decoder: String?
            public var isAV1HardwareSupported: Bool
            public var hasDialogueBoost: Bool
            public var gpuDeinterlacer: String?
        }

        static var current: Engine {
            let build = FFmpegBuild.capabilities
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return Engine(
                prismCoreVersion: PrismCoreVersion.current,
                ffmpegVersion: FFmpegBuild.versionInfo,
                libraries: FFmpegBuild.libraries.map {
                    Library(name: $0.name, compiled: "\($0.compiled)", loaded: "\($0.loaded)",
                            isABIMatched: $0.isABIMatched)
                },
                mismatchedLibraries: FFmpegBuild.mismatchedLibraries.map(\.name),
                capabilities: Capabilities(
                    hasEAC3Encoder: build.hasEAC3Encoder,
                    audioBridgeEncoder: build.audioBridgeEncoder,
                    av1Decoder: build.av1Decoder,
                    isAV1HardwareSupported: build.isAV1HardwareSupported,
                    hasDialogueBoost: build.hasDialogueBoost,
                    gpuDeinterlacer: build.gpuDeinterlacer
                ),
                platform: platformName,
                osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            )
        }

        private static var platformName: String {
            #if os(tvOS)
            "tvOS"
            #elseif os(visionOS)
            "visionOS"
            #elseif os(iOS)
            "iOS"
            #elseif os(macOS)
            "macOS"
            #else
            "unknown"
            #endif
        }
    }

    // MARK: - Source

    public struct Source: Sendable, Equatable, Codable {
        /// The remote URL without credentials, query or fragment — the
        /// places servers put tokens. `nil` for a local file, and for a URL
        /// that could not be taken apart (withheld rather than risked).
        public var url: String?
        /// A local file's name, without its directory. The directory is this
        /// device's layout (a user name, a mount point) and says nothing
        /// about the media; the name is what a reporter recognises.
        public var fileName: String?
        public var scheme: String?
        /// How many request headers the host supplied. Their names and
        /// values are never exported.
        public var httpHeaderCount: Int
        /// Whether the host supplied the bytes itself (`PrismCoreInput`).
        public var hostInput: Bool
        /// The transport's length for the source, when the probe measured it.
        public var byteSize: Int64?
        public var durationSeconds: Double?
        public var info: SourceDescription?
        /// The container layout, without the keyframe timestamps (an index
        /// load can export twenty thousand of them; the report keeps the
        /// count and the completeness).
        public var structure: SourceStructure?
    }

    // MARK: - Decision

    public struct Decision: Sendable, Equatable, Codable {
        /// `remux` or `software`; `nil` when the router declined outright
        /// (no video, no decoder), in which case `reason` says why.
        public var engine: String?
        public var reason: String
    }

    // MARK: - Options

    /// `PrismCoreSession.Options` without anything that names a place:
    /// `keyframeIndexCacheDirectory` is reduced to whether it is set, the
    /// headers to the count in `Source`, external subtitles to a count.
    public struct Options: Sendable, Equatable, Codable {
        public var display: Display
        public var segmentCacheBytes: Int?
        public var forceMuxedShape: Bool
        public var keyframeIndexCacheEnabled: Bool
        public var dialogueBoost: [String]
        public var preferredAudioLanguage: String?
        public var preferredSubtitleLanguage: String?
        public var audioDelaySeconds: Double
        public var coordinatedHTTP: Bool
        /// `loopbackOnly` or `localNetworkUnencryptedForAirPlay`.
        public var reachability: String
        public var externalSubtitleCount: Int

        public struct Display: Sendable, Equatable, Codable {
            public var isHDRReady: Bool
            public var isDolbyVisionCapable: Bool
            public var panelIsCurrentlyHDR: Bool?
            public var source: String
        }
    }

    // MARK: - Startup

    public struct Startup: Sendable, Equatable, Codable {
        /// The stages `start()` reached, in order — recorded whether or not
        /// the host registered for `startupCheckpoints()`. A startup that
        /// failed ends wherever it got to, which is the point.
        public var checkpoints: [Checkpoint]
        /// `keyframeIndexCache`, `builtFromSource` or `sequential`.
        public var planOrigin: String?
        /// Planned segment count; 0 for a sequential session.
        public var planSegments: Int?
        /// The routing probe's phases, for a session built from a
        /// `ProbedSource` (or a report taken from one).
        public var probeTiming: ProbeTiming?
        /// What `start()` threw, when it did.
        public var failure: Failure?

        public struct Checkpoint: Sendable, Equatable, Codable {
            /// `sourceOpened`, `streamInfoResolved`, `segmentPlanReady`,
            /// `firstVideoSegmentWritten` or `playlistServable`.
            public var phase: String
            public var elapsedSeconds: Double
        }

        public struct ProbeTiming: Sendable, Equatable, Codable {
            public var openSeconds: Double
            public var streamInfoSeconds: Double
            public var describeSeconds: Double
            public var hdr10PlusScanSeconds: Double
            public var totalSeconds: Double
        }
    }

    // MARK: - Runtime

    public struct Runtime: Sendable, Equatable, Codable {
        public var started: Bool
        public var stopped: Bool
        /// Since `start()` was called; `nil` before.
        public var uptimeSeconds: Double?
        public var sourceBytesRead: Int64
        /// The newest `PlaybackEvent`s, oldest first, kept whether or not a
        /// host registered for them.
        public var playbackEvents: [Event]
        /// Older events the bounded window let go.
        public var playbackEventsDropped: Int
        public var timestampRepairs: TimestampRepairs?
        public var audioRenditionProductions: [AudioRendition]
        /// `AudioRenditionProduction.summary`, the line a host logs. `nil`
        /// before the master is written and in the muxed shape.
        public var audioRenditionSummary: String?
        public var objectAudio: [ObjectAudio]
        public var dolbyVisionConversion: DolbyVisionConversion?
        public var retention: Retention
        /// The remux's terminal error, classified, once it died.
        public var remuxFailure: Failure?
        public var audioDelaySeconds: Double
        public var pendingAudioDelaySeconds: Double?
        public var subtitleDelaySeconds: Double

        public struct Event: Sendable, Equatable, Codable {
            /// The `PlaybackEvent` case name.
            public var kind: String
            /// Since `start()`, negative for an event from before it; `nil`
            /// while the session has not been started.
            public var atSeconds: Double?
            /// The loopback path served (never a source path).
            public var path: String?
            public var waitedSeconds: Double?
            public var stalledSeconds: Double?
            public var lastPTS: Double?
            public var retryAfterSeconds: Double?
        }

        public struct TimestampRepairs: Sendable, Equatable, Codable {
            public var missingDTSFilled: Int
            public var nonMonotonicDTSBumped: Int
            public var ptsRaisedToDTS: Int
            public var total: Int
        }

        public struct AudioRendition: Sendable, Equatable, Codable {
            public var streamIndex: Int
            public var dialogueBoost: String?
            public var encodes: Bool
            /// `eager`, `lazy` or `omitted`.
            public var production: String
        }

        public struct ObjectAudio: Sendable, Equatable, Codable {
            public var streamIndex: Int
            public var complexityIndex: Int?
            public var claimedByMetadata: Bool
            public var isObjectAudio: Bool
            public var wasMissedByMetadata: Bool
        }

        public struct DolbyVisionConversion: Sendable, Equatable, Codable {
            public var convertedRPUs: Int
            public var failedRPUs: Int
            public var droppedEnhancementLayerNALs: Int
            public var staleUnconvertedPackets: Int
            public var isClean: Bool
        }

        public struct Retention: Sendable, Equatable, Codable {
            /// `segmentCacheBytes`; `nil` keeps everything.
            public var budgetBytes: Int?
            /// Segments evicted to stay inside it, over the whole session.
            public var evictedSegments: Int
        }
    }

    /// A failure, classified the way a host branches on it
    /// (`PrismCoreError`).
    public struct Failure: Sendable, Equatable, Codable {
        /// The `PrismCoreError` case name.
        public var kind: String
        public var retryability: String
        /// The error's description, with every secret the report knows of
        /// cut out of it (see `Redaction`).
        public var description: String
    }
}

// MARK: - Source description

/// `SourceInfo` as the report writes it. An explicit copy rather than
/// `Codable` on `SourceInfo` itself, so the public type can keep changing
/// shape without changing the JSON a reader was written against.
public struct SourceDescription: Sendable, Equatable, Codable {
    public var formatName: String
    public var durationSeconds: Double?
    /// `streamCopy`, `requiresAudioBridge` or `unsupported`.
    public var nativeReadiness: String
    public var video: Video?
    public var audio: [Audio]
    public var subtitles: [Subtitle]
    public var chapterCount: Int
    public var hdr10Plus: HDR10Plus?

    public struct Video: Sendable, Equatable, Codable {
        public var streamIndex: Int
        public var codecName: String
        public var profileName: String?
        public var width: Int
        public var height: Int
        /// `num:den`, when the container declared one.
        public var sampleAspectRatio: String?
        public var bitDepth: Int?
        public var frameRate: Double?
        public var bitRate: Int64?
        public var fieldOrder: String
        public var dynamicRange: String
        public var colorPrimaries: String?
        public var colorTransfer: String?
        public var colorSpace: String?
        public var dolbyVision: DolbyVision?
        public var copyability: String
    }

    public struct DolbyVision: Sendable, Equatable, Codable {
        public var profile: Int
        public var level: Int
        public var profileName: String
        public var rpuPresent: Bool
        public var enhancementLayerPresent: Bool
        public var baseLayerPresent: Bool
        public var baseLayerSignalCompatibilityID: Int
    }

    public struct Audio: Sendable, Equatable, Codable {
        public var streamIndex: Int
        public var codecName: String
        public var profileName: String?
        public var channelCount: Int
        public var channelLayout: String?
        public var sampleRate: Int
        public var bitRate: Int64?
        public var language: String?
        public var title: String?
        /// The container's claim; `Runtime.objectAudio` is the bitstream's.
        public var isObjectAudio: Bool
        public var copyability: String
    }

    public struct Subtitle: Sendable, Equatable, Codable {
        public var streamIndex: Int
        public var codecName: String
        public var language: String?
        public var title: String?
        public var kind: String
        public var isDefault: Bool
        public var isForced: Bool
        public var isHearingImpaired: Bool
        public var isOCRReadable: Bool
    }

    public struct HDR10Plus: Sendable, Equatable, Codable {
        public var streamIndex: Int
        /// `seen`, `notSeenWithinBudget`, or `unknown:<reason>`.
        public var verdict: String
        public var applicationVersion: Int?
        public var videoPacketsScanned: Int
    }

    init(_ info: SourceInfo) {
        formatName = info.formatName
        durationSeconds = info.duration
        nativeReadiness = info.nativeReadiness.rawValue
        video = info.video.map { video in
            Video(
                streamIndex: video.streamIndex, codecName: video.codecName,
                profileName: video.profileName, width: video.width, height: video.height,
                sampleAspectRatio: video.sampleAspectRatio.map { "\($0.numerator):\($0.denominator)" },
                bitDepth: video.bitDepth, frameRate: video.frameRate, bitRate: video.bitRate,
                fieldOrder: video.fieldOrder.rawValue, dynamicRange: video.dynamicRange.rawValue,
                colorPrimaries: video.colorPrimariesName, colorTransfer: video.colorTransferName,
                colorSpace: video.colorSpaceName,
                dolbyVision: video.dolbyVision.map { dv in
                    DolbyVision(
                        profile: Int(dv.profile), level: Int(dv.level), profileName: dv.profileName,
                        rpuPresent: dv.rpuPresent, enhancementLayerPresent: dv.enhancementLayerPresent,
                        baseLayerPresent: dv.baseLayerPresent,
                        baseLayerSignalCompatibilityID: Int(dv.baseLayerSignalCompatibilityID)
                    )
                },
                copyability: video.copyability.rawValue
            )
        }
        audio = info.audioTracks.map { audio in
            Audio(
                streamIndex: audio.streamIndex, codecName: audio.codecName,
                profileName: audio.profileName, channelCount: audio.channelCount,
                channelLayout: audio.channelLayoutDescription, sampleRate: audio.sampleRate,
                bitRate: audio.bitRate, language: audio.language, title: audio.title,
                isObjectAudio: audio.isObjectAudio, copyability: audio.copyability.rawValue
            )
        }
        subtitles = info.subtitleTracks.map { subtitle in
            Subtitle(
                streamIndex: subtitle.streamIndex, codecName: subtitle.codecName,
                language: subtitle.language, title: subtitle.title, kind: subtitle.kind.rawValue,
                isDefault: subtitle.isDefault, isForced: subtitle.isForced,
                isHearingImpaired: subtitle.isHearingImpaired, isOCRReadable: subtitle.isOCRReadable
            )
        }
        chapterCount = info.chapters.count
        hdr10Plus = info.hdr10Plus.map { finding in
            let verdict: String
            switch finding.verdict {
            case .seen: verdict = "seen"
            case .notSeenWithinBudget: verdict = "notSeenWithinBudget"
            case .unknown(let reason): verdict = "unknown:\(reason.rawValue)"
            }
            return HDR10Plus(
                streamIndex: finding.streamIndex, verdict: verdict,
                applicationVersion: finding.applicationVersion,
                videoPacketsScanned: finding.videoPacketsScanned
            )
        }
    }
}

// MARK: - Redaction

/// What a report must never carry, and the one place that enforces it.
///
/// Two layers, because one is not enough. The structured fields are built
/// redacted (`Source.url` drops credentials, query and fragment; paths are
/// reduced to a name or a flag; headers to a count). But a few fields are
/// free text the engine did not write — an error's description can quote a
/// failing URL whole, query token and all — so every such string is also
/// scrubbed of each secret value the session holds before it is stored.
struct Redaction: Sendable {
    private let secrets: [String]

    init(url: URL, httpHeaders: [String: String], paths: [URL?] = [], extra: [String] = []) {
        var secrets = Array(httpHeaders.values) + extra
        secrets.append(url.absoluteString)
        if url.isFileURL {
            secrets.append(url.deletingLastPathComponent().path)
        } else if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            secrets += [components.user, components.password, components.query,
                        components.percentEncodedQuery, components.fragment].compactMap { $0 }
            secrets += (components.queryItems ?? []).compactMap(\.value)
        }
        secrets += paths.compactMap { $0?.path }
        // Very short values would only shred ordinary words; a three-letter
        // header value is not a credential worth that.
        self.secrets = Set(secrets.filter { $0.count >= 4 })
            .sorted { $0.count > $1.count }
    }

    func scrub(_ text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
    }

    /// `url` for a remote source, `fileName` for a local one — never both,
    /// and neither when the URL cannot be taken apart safely.
    static func location(of url: URL) -> (url: String?, fileName: String?) {
        if url.isFileURL {
            let name = url.lastPathComponent
            return (nil, name.isEmpty || name == "/" ? nil : name)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (nil, nil)
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return (components.string, nil)
    }

    func source(
        url: URL, httpHeaders: [String: String], hostInput: Bool,
        info: SourceInfo?, structure: SourceStructure?
    ) -> SessionDiagnosticReport.Source {
        let location = Self.location(of: url)
        return SessionDiagnosticReport.Source(
            url: location.url, fileName: location.fileName, scheme: url.scheme?.lowercased(),
            httpHeaderCount: httpHeaders.count, hostInput: hostInput,
            byteSize: structure?.byteSize, durationSeconds: info?.duration,
            info: info.map(SourceDescription.init), structure: structure.map(Self.withoutKeyframes)
        )
    }

    func decision(_ outcome: Result<PrismCoreEngine.Decision, any Error>) -> SessionDiagnosticReport.Decision {
        switch outcome {
        case .success(let decision):
            return .init(engine: decision.engine.rawValue, reason: scrub(decision.reason))
        case .failure(let error):
            return .init(engine: nil, reason: scrub("\(error)"))
        }
    }

    func failure(_ error: any Error) -> SessionDiagnosticReport.Failure {
        let classified = PrismCoreError.classify(error)
        let retryability: String
        switch classified.retryability {
        case .retryable: retryability = "retryable"
        case .permanent: retryability = "permanent"
        case .unknown: retryability = "unknown"
        }
        return .init(kind: classified.caseName, retryability: retryability,
                     description: scrub(classified.description))
    }

    private static func withoutKeyframes(_ structure: SourceStructure) -> SourceStructure {
        SourceStructure(
            headerBytes: structure.headerBytes, firstClusterOffset: structure.firstClusterOffset,
            indexLocation: structure.indexLocation,
            index: structure.index.map {
                IndexSummary(
                    streamIndex: $0.streamIndex, timeBaseNum: $0.timeBaseNum,
                    timeBaseDen: $0.timeBaseDen, entryCount: $0.entryCount,
                    completeness: $0.completeness, source: $0.source,
                    coveredThroughPTS: $0.coveredThroughPTS, keyframePTS: nil
                )
            },
            byteSize: structure.byteSize
        )
    }
}

extension PrismCoreError {
    /// The case name, for a report a machine compares — the description is
    /// for people and changes wording.
    var caseName: String {
        switch self {
        case .originRefused: "originRefused"
        case .originRateLimited: "originRateLimited"
        case .originUnreachable: "originUnreachable"
        case .noVideoStream: "noVideoStream"
        case .videoCodecNotRemuxable: "videoCodecNotRemuxable"
        case .videoCodecUnplayable: "videoCodecUnplayable"
        case .startupBudgetExpired: "startupBudgetExpired"
        case .masterRejectedByPlayer: "masterRejectedByPlayer"
        case .workDirectoryOutOfSpace: "workDirectoryOutOfSpace"
        case .ffmpeg: "ffmpeg"
        case .unknown: "unknown"
        }
    }
}

extension SessionDiagnosticReport.Startup.ProbeTiming {
    init(_ timing: ProbeTiming) {
        self.init(
            openSeconds: timing.open / .seconds(1),
            streamInfoSeconds: timing.streamInfo / .seconds(1),
            describeSeconds: timing.describe / .seconds(1),
            hdr10PlusScanSeconds: timing.hdr10PlusScan / .seconds(1),
            totalSeconds: timing.total / .seconds(1)
        )
    }
}

extension StartupPhase {
    var caseName: String {
        switch self {
        case .sourceOpened: "sourceOpened"
        case .streamInfoResolved: "streamInfoResolved"
        case .segmentPlanReady: "segmentPlanReady"
        case .firstVideoSegmentWritten: "firstVideoSegmentWritten"
        case .playlistServable: "playlistServable"
        }
    }
}

extension SessionDiagnosticReport.Runtime.Event {
    init(_ event: PlaybackEvent, at instant: ContinuousClock.Instant, since start: ContinuousClock.Instant?,
         redaction: Redaction) {
        func seconds(_ duration: Duration) -> Double { duration / .seconds(1) }
        self.init(kind: "", atSeconds: start.map { seconds(instant - $0) })
        switch event {
        case .slowServe(let path, let waited):
            (kind, self.path, waitedSeconds) = ("slowServe", redaction.scrub(path), seconds(waited))
        case .serveTimedOut(let path):
            (kind, self.path) = ("serveTimedOut", redaction.scrub(path))
        case .producerStalled(let since, let lastPTS):
            (kind, stalledSeconds, self.lastPTS) = ("producerStalled", seconds(since), lastPTS)
        case .originThrottled(let retryAfter):
            (kind, retryAfterSeconds) = ("originThrottled", retryAfter.map(seconds))
        case .originRecovered:
            kind = "originRecovered"
        }
    }
}

// MARK: - Startup record

/// The session's own copy of its startup checkpoints. The host's stream is
/// optional and consumed once; a report taken after a failed start needs the
/// stages regardless, and the producer thread emits them, hence the lock.
/// Five stages per session; the cap only guards against a future emitter
/// that forgets startup ends.
final class StartupRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [StartupCheckpoint] = []
    private static let cap = 16

    func append(_ mark: StartupCheckpoint) {
        lock.withLock { if marks.count < Self.cap { marks.append(mark) } }
    }

    var checkpoints: [StartupCheckpoint] { lock.withLock { marks } }
}

// MARK: - Routing without a session

extension PrismCoreEngine {

    /// A report for a source that never got a session — declined, routed to
    /// the software path, or simply not played — from its probe and the
    /// routing outcome:
    ///
    /// ```swift
    /// let probed = try await SourceProbe.openDetached(url: url, httpHeaders: headers)
    /// let outcome = Result { try PrismCoreEngine.decide(for: probed.info) }
    /// let report = PrismCoreEngine.diagnosticReport(for: probed, decision: outcome)
    /// ```
    ///
    /// `options` and `runtime` are absent: there was no session to have them.
    public static func diagnosticReport(
        for probed: ProbedSource,
        decision: Result<Decision, any Error>
    ) -> SessionDiagnosticReport {
        let redaction = Redaction(url: probed.url, httpHeaders: probed.httpHeaders)
        return SessionDiagnosticReport(
            source: redaction.source(
                url: probed.url, httpHeaders: probed.httpHeaders, hostInput: probed.inputFactory != nil,
                info: probed.info, structure: probed.structure
            ),
            decision: redaction.decision(decision),
            options: nil,
            startup: .init(checkpoints: [], probeTiming: .init(probed.timing)),
            runtime: nil
        )
    }
}
