import Testing
import Foundation
@testable import PrismCore

/// Several sessions in one process at once — a server-side host (one process
/// remuxing for several clients) rather than a player's one-at-a-time. Each
/// session has its own producer thread, server and work directory; what they
/// share is process-wide (`HTTPOriginCoordinator`, FFmpeg's global state, the
/// cooperative pool), and that is what this exercises. Run it under Thread
/// Sanitizer to make it mean something:
///
///     swift test --sanitize=thread --filter ConcurrentSessionsStressTests
@Suite("Concurrent sessions", .serialized)
struct ConcurrentSessionsStressTests {

    /// Copied, bridged (TrueHD, DTS), multi-rendition and subtitled sources, so
    /// the sessions run different parts of the engine side by side.
    private static let sources = [
        "h264_aac_30s.mkv", "h264_multi_audio.mkv", "h264_truehd_14s.mkv",
        "h264_dts.mkv", "h264_aac_ac3_srt_60s.mkv", "hevc_eac3.mkv",
    ]

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// Every playlist the master names, and every segment those name — what a
    /// player that watched the whole title would have fetched. Returns the
    /// number of segments, or throws on the first non-200.
    private static func fetchEverything(from master: URL) async throws -> Int {
        struct BadStatus: Error { let url: URL; let status: Int }
        func get(_ url: URL) async throws -> Data {
            let (data, response) = try await URLSession.uncached.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw BadStatus(url: url, status: status) }
            return data
        }
        let base = master.deletingLastPathComponent()
        let masterText = String(decoding: try await get(master), as: UTF8.self)
        var segments = 0
        for uri in PrismCoreSession.playlistURIs(inMaster: masterText) {
            let playlist = base.appendingPathComponent(uri)
            let text = String(decoding: try await get(playlist), as: UTF8.self)
            let directory = playlist.deletingLastPathComponent()
            for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.isEmpty {
                #expect(try await !get(directory.appendingPathComponent(String(line))).isEmpty)
                segments += 1
            }
        }
        return segments
    }

    @Test("Six sessions start, serve every segment and stop side by side")
    func sixSessionsInParallel() async throws {
        let urls = try Self.sources.map(fixture)
        let sessions = try urls.map { try PrismCoreSession(url: $0) }

        let served = try await withThrowingTaskGroup(of: Int.self) { group in
            for session in sessions {
                group.addTask {
                    try await Self.fetchEverything(from: try await session.start())
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(served.count == sessions.count)
        #expect(served.allSatisfy { $0 > 0 }, "segments per session: \(served)")

        // Stopped concurrently too: teardown is where shared state is released.
        await withTaskGroup(of: Void.self) { group in
            for session in sessions { group.addTask { await session.stop() } }
        }
    }
}
