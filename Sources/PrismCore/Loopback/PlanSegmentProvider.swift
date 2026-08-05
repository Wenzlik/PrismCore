import Foundation

/// The demand-driven session's provider: serve from disk when the file
/// exists, and otherwise turn the request into production intent — ask the
/// coordinator to (re-)anchor the producer at the requested segment and hand
/// the server a `.pending` that resolves when the file lands.
///
/// The server's slow-serve machinery (early 200 + chunked past 2 s) is what
/// makes waiting safe against AVPlayer's ~3.5 s header watchdog; this type
/// only decides WHAT to wait for.
struct PlanSegmentProvider: SegmentProvider {

    let root: URL
    let coordinator: DemandCoordinator
    /// How long a pending serve may wait for the producer before aborting the
    /// connection (truncated transfer → AVPlayer retries). A re-anchor is a
    /// demuxer seek + fresh muxers — seconds, not minutes.
    var productionTimeout: Duration = .seconds(15)
    /// How long a subtitle segment may wait. Shorter than a media segment's
    /// window: the cues arrive when the segment carrying them is cut, so if that
    /// hasn't happened by now the producer went somewhere else entirely and
    /// waiting longer buys nothing.
    var subtitleProductionTimeout: Duration = .seconds(8)

    private let directory: DirectorySegmentProvider

    init(root: URL, coordinator: DemandCoordinator) {
        self.root = root
        self.coordinator = coordinator
        self.directory = DirectorySegmentProvider(root: root)
    }

    func data(forPath path: String) async -> ProviderResult {
        let direct = await directory.data(forPath: path)
        if case .notFound = direct {
            return await handleMiss(path: path)
        }
        return direct
    }

    private func handleMiss(path: String) async -> ProviderResult {
        guard coordinator.publishedPlan != nil else { return .notFound }

        // Unproduced planned artifacts by shape:
        if let index = Self.segmentIndex(inPath: path) {
            coordinator.requestProduction(of: index)
            return .pending(waitForFile(path: path))
        }
        if path.hasSuffix("init.mp4") {
            // The init exists after the producer's first cut wherever it is
            // anchored — no re-anchor needed, just patience.
            return .pending(waitForFile(path: path))
        }
        if path.hasSuffix(".vtt") {
            // A subtitle segment for a range nobody has demuxed yet. Serving the
            // empty segment immediately is safe but wrong in the common case: the
            // fetch that arrives with it is AVPlayer asking for the *media*
            // segment of the same index, which re-anchors the producer, and the
            // cues land the moment that segment is cut — a second or two away.
            // AVPlayer caches segments and never re-fetches, so answering empty
            // straight away is what made subtitles resume only from the segment
            // AFTER a seek.
            //
            // So wait, then degrade. Unlike a media segment, a subtitle segment
            // that never arrives must not abort the connection: empty cues are a
            // far better outcome than a failed rendition.
            return .pending(
                waitForFile(
                    path: path,
                    timeout: subtitleProductionTimeout,
                    onTimeout: .data(Self.emptyWebVTT, contentType: "text/vtt")
                )
            )
        }
        return .notFound
    }

    /// `seg%05d.m4s` anywhere under the root (variant or `audioN/`) → index.
    static func segmentIndex(inPath path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(3).dropLast(4))
    }

    /// A header-only WebVTT segment: valid, parseable, no cues.
    static let emptyWebVTT = Data("WEBVTT\n\n".utf8)

    /// - Parameter onTimeout: what to answer when the file never lands.
    ///   `.notFound` aborts the connection, which is right for media (a truncated
    ///   transfer makes AVPlayer retry) and wrong for subtitles.
    private func waitForFile(
        path: String,
        timeout: Duration? = nil,
        onTimeout: ProviderResult = .notFound
    ) -> PendingResult {
        let fileURL = root.appendingPathComponent(path)
        let contentType = LoopbackHTTPServer.contentType(for: fileURL)
        let timeout = timeout ?? productionTimeout
        return PendingResult {
            // Clock starts when the SERVE runs, not when the miss was seen —
            // a queued pending must get its full window.
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if let data = try? Data(contentsOf: fileURL) {
                    return .data(data, contentType: contentType)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return onTimeout
        }
    }
}
