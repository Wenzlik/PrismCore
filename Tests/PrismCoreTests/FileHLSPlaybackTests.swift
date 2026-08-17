import Testing
import Foundation
import AVFoundation
@testable import PrismCore

/// Issue #52's measurement: can AVPlayer play a **completed** session's HLS
/// output straight off disk — `file://` master, relative segment URIs, no
/// loopback server anywhere?
///
/// Why it was worth asking: the loopback listener is the one thing that forces
/// a sandboxed macOS host to carry `com.apple.security.network.server`.
/// `AVAssetResourceLoader` is documented out (its header forbids loading HLS
/// media data), so a file-URL playlist was the only entitlement-free shape
/// left — conceivable only for fully produced output, because a file URL
/// cannot hold a request open the way the server's slow-serve does.
///
/// **The measured answer is no** (macOS 26 beta, 2026-08-17): an
/// `AVPlayerItem` on a finished session's `file://` master — or on the video
/// media playlist directly — never leaves `.unknown`. No `.failed`, no
/// `error`, no `errorLog()` entries; evaluation simply never starts. So this
/// suite pins the *fact*, the way the engine pins other platform behaviour:
/// if it ever fails, AVPlayer has started evaluating file-URL HLS and #52's
/// file mode is worth designing after all.
@Suite("File-URL HLS after completion", .serialized)
struct FileHLSPlaybackTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// Poll the on-disk playlists until every one the master references has
    /// its `EXT-X-ENDLIST` — "the remux is done" as the files themselves tell
    /// it, since after `stop()` there is no server left to ask.
    private func waitForCompletedWorkDirectory(
        _ directory: URL, timeout: Duration = .seconds(30)
    ) async throws {
        let master = directory.appendingPathComponent("master.m3u8")
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: master, encoding: .utf8) {
                let mediaPlaylists = PrismCoreSession.playlistURIs(inMaster: text)
                    .map { directory.appendingPathComponent($0) }
                let allEnded = !mediaPlaylists.isEmpty && mediaPlaylists.allSatisfy {
                    (try? String(contentsOf: $0, encoding: .utf8))?
                        .contains("#EXT-X-ENDLIST") == true
                }
                if allEnded { return }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw PrismCoreSession.SessionError.startupTimedOut(underlying: nil)
    }

    @Test("AVPlayer does not evaluate a finished session's file:// playlists")
    func filePlaybackStaysUnknown() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        _ = try await session.start()
        let workDirectory = await session.workDirectory
        try await waitForCompletedWorkDirectory(workDirectory)

        // Copy before stop(): stop() deletes the work directory, and playing
        // from a copy is the honest shape of the measurement anyway — nothing
        // of the session, server included, may be alive underneath the player.
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreFileHLS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: workDirectory, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        await session.stop()

        // Both entry points — the master and the video media playlist — sit
        // in .unknown with no error. Asserting both keeps the pin honest: a
        // future OS could plausibly accept one shape and not the other.
        for playlist in ["master.m3u8", "index.m3u8"] {
            let item = AVPlayerItem(url: copy.appendingPathComponent(playlist))
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            let outcome = await settledStatus(item, timeout: 8)
            #expect(
                outcome == .unknown,
                """
                file:// \(playlist) left .unknown (\(outcome.rawValue), \
                error: \(String(describing: item.error))) — if it is now \
                .readyToPlay, AVPlayer has started evaluating file-URL HLS: \
                reopen #52, the no-listener mode just became possible.
                """
            )
            _ = player  // keep alive through the wait
        }
    }

    /// The item's status once it moves, or `.unknown` if it never does within
    /// `timeout` — same KVO shape as the loopback readiness test, but here
    /// "nothing happened" is the expected result rather than the failure.
    private func settledStatus(
        _ item: AVPlayerItem, timeout: TimeInterval
    ) async -> AVPlayerItem.Status {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                if item.status != .unknown {
                    once.run { continuation.resume(returning: item.status) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                _ = observation   // retained until here
                once.run { continuation.resume(returning: .unknown) }
            }
        }
    }
}
