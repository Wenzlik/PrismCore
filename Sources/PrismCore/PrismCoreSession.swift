import Foundation

/// One playback session: remux `sourceURL` into HLS-fMP4 on disk and serve it
/// from the loopback. The host plays the returned playlist URL with its own
/// `AVPlayer` — PrismCore v0 is a service, not a player (see README).
///
/// ```swift
/// let session = try PrismCoreSession(url: mkvURL)
/// let playlist = try await session.start()
/// player.replaceCurrentItem(with: AVPlayerItem(url: playlist))
/// …
/// await session.stop()
/// ```
///
/// The URL that comes back is the **master** playlist whenever the source has
/// audio worth carrying as alternate renditions (`master.m3u8`), and the media
/// playlist (`index.m3u8`) when it hasn't — a silent source, or one whose master
/// couldn't be written honestly (see `HLSRemuxer`). Hosts should treat the URL as
/// opaque: the shape is a property of the source, not of the API.
public actor PrismCoreSession {

    public enum SessionError: Error {
        /// The remux produced no playable playlist within the startup budget.
        case startupTimedOut(underlying: Error?)
    }

    private let sourceURL: URL
    private let httpHeaders: [String: String]
    private let workDirectory: URL
    private let server: LoopbackHTTPServer
    private let remuxer: HLSRemuxer
    private var remuxTask: Task<Void, Error>?
    private var started = false

    /// The remux's terminal error, if it failed after startup. Hosts can poll
    /// this when AVPlayer reports a stalled item.
    public private(set) var remuxError: Error?

    /// - Parameters:
    ///   - displayIsHDRReady: whether the display this session plays to is in
    ///     (or will switch into) the source's own dynamic range. Only a host
    ///     knows this, and getting it wrong is expensive: an HDR variant offered
    ///     to an SDR-parked panel is rejected outright rather than tone-mapped,
    ///     so the default is `false` and an HDR source then keeps v0's
    ///     media-playlist shape — which means its audio stays muxed and
    ///     unswitchable until the host opts in. Phase 4 is where this becomes a
    ///     read instead of a parameter.
    ///   - displayIsDolbyVisionCapable: whether that display can present Dolby
    ///     Vision. Same reasoning; `false` simply omits the DV claims.
    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        displayIsHDRReady: Bool = false,
        displayIsDolbyVisionCapable: Bool = false
    ) throws {
        self.sourceURL = url
        self.httpHeaders = httpHeaders

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.workDirectory = directory
        self.server = LoopbackHTTPServer(root: directory)
        self.remuxer = HLSRemuxer(
            sourceURL: url,
            httpHeaders: httpHeaders,
            outputDirectory: directory,
            displayIsHDRReady: displayIsHDRReady,
            displayIsDolbyVisionCapable: displayIsDolbyVisionCapable
        )
    }

    /// Start the loopback server and the remux, and return the playlist URL
    /// once everything that playlist references exists on disk — the point where
    /// AVPlayer can be pointed at it without racing an empty directory.
    public func start(startupTimeout: Duration = .seconds(20)) async throws -> URL {
        precondition(!started, "PrismCoreSession is single-use — make a new one per load")
        started = true

        let base = try await server.start()

        let remuxer = self.remuxer
        let task = Task.detached(priority: .userInitiated) {
            try remuxer.run()
        }
        remuxTask = task
        watchForTerminalError(task)

        let deadline = ContinuousClock.now.advanced(by: startupTimeout)
        while ContinuousClock.now < deadline {
            if let ready = readyPlaylistName() {
                return base.appendingPathComponent(ready)
            }
            // A remux that already died will never produce the playlist —
            // surface its error instead of burning the whole timeout.
            if task.isCancelled { break }
            if let remuxError { throw SessionError.startupTimedOut(underlying: remuxError) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SessionError.startupTimedOut(underlying: remuxError)
    }

    /// Cancel the remux, stop serving, and remove the session's segments.
    public func stop() async {
        remuxer.cancel()
        remuxTask?.cancel()
        _ = try? await remuxTask?.value
        await server.stop()
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: - Readiness

    /// The playlist to hand out, once it is genuinely playable — or `nil` while
    /// the remux is still finding its feet.
    ///
    /// The remuxer writes the master first (its contents are known before the
    /// first packet), so the master's presence is what decides the shape. What
    /// takes a moment is the *renditions*: a master whose audio playlist doesn't
    /// exist yet is a 404 for AVPlayer, which it can fail the item over rather
    /// than retry. So every playlist the master references — the video variant
    /// and each rendition — has to be there, carry an `EXTINF`, and have its
    /// `EXT-X-MAP` init segment on disk.
    private func readyPlaylistName() -> String? {
        let master = workDirectory.appendingPathComponent(HLSRemuxer.masterPlaylistFileName)
        guard let masterText = try? String(contentsOf: master, encoding: .utf8) else {
            return isPlayable(playlist: HLSRemuxer.mediaPlaylistFileName)
                ? HLSRemuxer.mediaPlaylistFileName
                : nil
        }
        let referenced = Self.playlistURIs(inMaster: masterText)
        guard !referenced.isEmpty, referenced.allSatisfy(isPlayable(playlist:)) else { return nil }
        return HLSRemuxer.masterPlaylistFileName
    }

    /// Every media playlist a master refers to: the `URI` of each `EXT-X-MEDIA`
    /// rendition, plus the plain URI line that follows each `EXT-X-STREAM-INF`.
    static func playlistURIs(inMaster text: String) -> [String] {
        var uris: [String] = []
        var expectingVariantURI = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if expectingVariantURI, !line.hasPrefix("#") {
                uris.append(line)
                expectingVariantURI = false
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                expectingVariantURI = true
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:"), let uri = attribute("URI", in: line) {
                uris.append(uri)
            }
        }
        return uris
    }

    /// One quoted attribute value out of a tag line. Deliberately minimal — the
    /// only attribute read back is `URI`, and the builder wrote it.
    private static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Does this relative media playlist exist, list a segment, and have the
    /// init segment it maps to?
    private func isPlayable(playlist relativePath: String) -> Bool {
        let url = workDirectory.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.contains("#EXTINF")
        else { return false }
        guard let mapLine = text.split(separator: "\n").first(where: {
            $0.hasPrefix("#EXT-X-MAP:")
        }) else { return true }
        guard let mapURI = Self.attribute("URI", in: String(mapLine)) else { return true }
        let initSegment = url.deletingLastPathComponent().appendingPathComponent(mapURI)
        return FileManager.default.fileExists(atPath: initSegment.path)
    }

    private func watchForTerminalError(_ task: Task<Void, Error>) {
        Task { [weak self] in
            do {
                try await task.value
            } catch {
                await self?.record(error: error)
            }
        }
    }

    private func record(error: Error) {
        remuxError = error
    }
}
