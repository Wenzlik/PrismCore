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
            // A subtitle segment for a range nobody produced yet. Cues only
            // exist once their range has been demuxed, and blocking the whole
            // item on subtitles would be backwards — serve an honest empty
            // segment. AVPlayer re-fetches nothing (segments are cached), so
            // a seek-ahead's subtitles start at the NEXT segment; recorded as
            // a known phase-6.1 gap in the README.
            return .data(Data("WEBVTT\n\n".utf8), contentType: "text/vtt")
        }
        return .notFound
    }

    /// `seg%05d.m4s` anywhere under the root (variant or `audioN/`) → index.
    static func segmentIndex(inPath path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(3).dropLast(4))
    }

    private func waitForFile(path: String) -> PendingResult {
        let fileURL = root.appendingPathComponent(path)
        let contentType = LoopbackHTTPServer.contentType(for: fileURL)
        let timeout = productionTimeout
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
            return .notFound
        }
    }
}
