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
