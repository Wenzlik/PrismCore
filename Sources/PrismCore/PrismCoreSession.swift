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
public actor PrismCoreSession {

    public enum SessionError: Error {
        /// The remux produced no playable playlist within the startup budget.
        case startupTimedOut(underlying: Error?)
        /// A registration call that only makes sense before `start()` arrived
        /// after it. Silently ignoring it would leave a subtitle track the host
        /// believes exists but that no rendition backs.
        case alreadyStarted
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

    public init(url: URL, httpHeaders: [String: String] = [:]) throws {
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
            outputDirectory: directory
        )
    }

    // MARK: - Subtitles (phase 6)

    /// Register an external subtitle file (`.srt` / `.vtt`) as its own WebVTT
    /// rendition, before `start()`.
    ///
    /// The whole file is converted once at remux setup and then segmented on the
    /// video's own boundaries, exactly like an embedded text track — so an
    /// external track behaves identically from AVPlayer's side. The rendition
    /// set is fixed when the remux starts (it has to be: the master playlist a
    /// host builds from `subtitleRenditions` is read once at item creation),
    /// hence the `alreadyStarted` refusal.
    ///
    /// - Parameters:
    ///   - url: A local file URL. Remote sidecars are the host's to fetch —
    ///     PrismCore has no download machinery and would only duplicate the
    ///     header handling the host already does.
    ///   - language: ISO-639 tag for `LANGUAGE`, e.g. `"cs"` / `"ces"`.
    ///   - name: Display name for `NAME`; defaults to the language tag.
    ///   - isForced: Marks the rendition `FORCED=YES`.
    public func addExternalSubtitle(
        url: URL,
        language: String? = nil,
        name: String? = nil,
        isForced: Bool = false
    ) throws {
        guard !started else { throw SessionError.alreadyStarted }
        remuxer.subtitles.addExternalFile(
            .init(url: url, language: language, name: name, isForced: isForced)
        )
    }

    /// The WebVTT subtitle renditions this session serves, in declaration order
    /// (embedded text tracks first, then registered external files).
    ///
    /// Populated once the remux has opened the source, i.e. any time after
    /// `start()` returns. Feed them to `MasterPlaylistBuilder` — a `SUBTITLES`
    /// group only exists in a master playlist, so a session served media-direct
    /// produces the renditions on disk but nothing selects them.
    public var subtitleRenditions: [MasterPlaylistBuilder.SubtitleRendition] {
        remuxer.subtitles.renditions
    }

    /// Start the loopback server and the remux, and return the playlist URL
    /// once the playlist and the init segment exist on disk — the point where
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

        // Wait for the first playable state: playlist + init segment + at
        // least one media segment. The hls muxer writes the playlist entry
        // only after the segment is complete, so their existence is a real
        // readiness signal, not a race.
        let playlist = workDirectory.appendingPathComponent("index.m3u8")
        let initSegment = workDirectory.appendingPathComponent("init.mp4")
        let deadline = ContinuousClock.now.advanced(by: startupTimeout)
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: playlist.path),
               FileManager.default.fileExists(atPath: initSegment.path),
               let contents = try? String(contentsOf: playlist, encoding: .utf8),
               contents.contains("#EXTINF") {
                return base.appendingPathComponent("index.m3u8")
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
