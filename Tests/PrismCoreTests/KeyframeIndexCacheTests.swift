import Testing
import Foundation
@testable import PrismCore

/// The cross-session keyframe map (issue #34): a source whose container
/// carries no usable seek index plays sequentially on its first run while the
/// producer harvests every keyframe it reads anyway, and the next play plans
/// on that map — demand mode as if the file had an index.
///
/// The fixture is MPEG-TS on purpose: a TS has no index to load (its few
/// probed entries fail the plan's coverage witness), so it is the natural
/// always-uniform source, with a real container duration — unlike a Matroska
/// piped without Cues, which loses its duration too and can't plan at all.
@Suite("Keyframe index cache", .serialized)
struct KeyframeIndexCacheTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreKeyframeCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Cache unit behaviour

    @Test("Store and look up round-trips; a different identity misses")
    func roundTrip() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = KeyframeIndexCache(directory: directory)

        let entry = KeyframeIndexCache.Entry(
            identity: "http://nas/movie.mkv|5400000000|7200000000",
            timeBaseNum: 1, timeBaseDen: 1000,
            keyframePTS: [0, 2000, 4000, 6000]
        )
        cache.store(entry)
        #expect(cache.lookup(identity: entry.identity) == entry)
        #expect(cache.lookup(identity: "http://nas/other.mkv|1|2") == nil)
    }

    @Test("The identity drops the URL query — a rotated token is the same media")
    func identityStripsQuery() {
        let tokenA = KeyframeIndexCache.identity(
            sourceURL: URL(string: "http://nas:32400/library/parts/9?X-Plex-Token=aaa")!,
            sizeBytes: 100, durationMicroseconds: 200
        )
        let tokenB = KeyframeIndexCache.identity(
            sourceURL: URL(string: "http://nas:32400/library/parts/9?X-Plex-Token=bbb")!,
            sizeBytes: 100, durationMicroseconds: 200
        )
        let otherPath = KeyframeIndexCache.identity(
            sourceURL: URL(string: "http://nas:32400/library/parts/10?X-Plex-Token=aaa")!,
            sizeBytes: 100, durationMicroseconds: 200
        )
        let otherSize = KeyframeIndexCache.identity(
            sourceURL: URL(string: "http://nas:32400/library/parts/9?X-Plex-Token=aaa")!,
            sizeBytes: 101, durationMicroseconds: 200
        )
        #expect(tokenA == tokenB)
        #expect(tokenA != otherPath)
        #expect(tokenA != otherSize)
    }

    @Test("The bound prunes least-recently-used entries, and a lookup refreshes")
    func lruPrune() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache = KeyframeIndexCache(directory: directory)
        cache.maxEntries = 2

        func entry(_ n: Int) -> KeyframeIndexCache.Entry {
            .init(identity: "source-\(n)", timeBaseNum: 1, timeBaseDen: 1000,
                  keyframePTS: [0, 2000])
        }
        cache.store(entry(0))
        // The prune orders by mtime; give the filesystem a distinct tick.
        Thread.sleep(forTimeInterval: 0.02)
        cache.store(entry(1))
        Thread.sleep(forTimeInterval: 0.02)
        // Touch 0 — it becomes the recent one, so storing 2 must evict 1.
        #expect(cache.lookup(identity: "source-0") != nil)
        Thread.sleep(forTimeInterval: 0.02)
        cache.store(entry(2))

        #expect(cache.lookup(identity: "source-0") != nil)
        #expect(cache.lookup(identity: "source-1") == nil)
        #expect(cache.lookup(identity: "source-2") != nil)
    }

    // MARK: - End to end over the no-index fixture

    @Test("First play harvests the keyframe map; the second plans on it")
    func harvestThenPlan() async throws {
        let cacheDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory)  }
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let source = try fixture("h264_ac3_30s.ts")

        // Play 1, the field shape: the index-load scan bounded out before it
        // could index anything. A zero budget forces that deterministically —
        // on a local file the linear scan the nudge seek degenerates to is
        // otherwise instant, and the demuxer would hand the planner a
        // self-built index (which is exactly what does NOT happen on the SMB
        // webrips this cache exists for). The plan degrades to uniform, the
        // producer runs sequentially, and the harvest sees every keyframe.
        let first = HLSRemuxer(
            sourceURL: source,
            outputDirectory: output,
            demand: DemandCoordinator(),
            keyframeCacheDirectory: cacheDirectory,
            indexLoadBudget: .zero
        )
        try first.run()
        let firstText = try String(
            contentsOf: output.appendingPathComponent("index.m3u8"), encoding: .utf8
        )
        #expect(firstText.contains("#EXT-X-PLAYLIST-TYPE:EVENT"),
                "the bounded-out first play unexpectedly planned — no harvest would follow")
        #expect(firstText.contains("#EXT-X-ENDLIST"))

        // The sidecar exists and carries the fixture's 2 s cadence.
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
            .filter { $0.hasSuffix(".json") }
        #expect(sidecars.count == 1)
        let entry = try JSONDecoder().decode(
            KeyframeIndexCache.Entry.self,
            from: Data(contentsOf: cacheDirectory.appendingPathComponent(try #require(sidecars.first)))
        )
        // 30 s at a 2 s keyframe interval → 15 keyframes.
        #expect(entry.keyframePTS.count >= 13 && entry.keyframePTS.count <= 17)

        // Play 2: the map is the index — planned VOD from the first second.
        let second = try PrismCoreSession(
            url: source, keyframeIndexCacheDirectory: cacheDirectory
        )
        let secondPlaylist = try await second.start()
        defer { Task { await second.stop() } }
        let (secondData, _) = try await URLSession.shared.data(from: secondPlaylist)
        let secondText = String(decoding: secondData, as: UTF8.self)
        #expect(secondText.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(secondText.contains("#EXT-X-ENDLIST"))

        // And the promise holds on the source with no index: a fetch deep in
        // the file re-anchors the producer there (a TS timestamp seek) and
        // serves a real fragment.
        let segments = secondText.split(separator: "\n")
            .filter { $0.hasSuffix(".m4s") }.map(String.init)
        #expect(segments.count >= 4)
        let base = secondPlaylist.deletingLastPathComponent()
        let (media, response) = try await URLSession.shared.data(
            from: base.appendingPathComponent(try #require(segments.last))
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(media.range(of: Data("moof".utf8)) != nil, "the demanded tail segment did not serve a real fragment")
    }

    @Test("A cancelled run persists nothing — a partial map is worse than none")
    func cancelledRunDoesNotPersist() async throws {
        let cacheDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let output = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: output) }

        // Cancelled before the first packet — the deterministic stand-in for
        // "the user backed out mid-file". A session-level stop() can lose the
        // race against a 30 s fixture that produces in milliseconds.
        let remuxer = HLSRemuxer(
            sourceURL: try fixture("h264_ac3_30s.ts"),
            outputDirectory: output,
            demand: DemandCoordinator(),
            keyframeCacheDirectory: cacheDirectory
        )
        remuxer.cancel()
        try remuxer.run()

        let sidecars = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path))?
            .filter { $0.hasSuffix(".json") } ?? []
        #expect(sidecars.isEmpty)
    }
}
