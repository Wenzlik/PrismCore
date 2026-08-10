import Testing
import Foundation
import CoreGraphics
@testable import PrismCore

/// Scrub-bar thumbnails: one keyframe, CPU-decoded, scaled, cached by the
/// keyframe it shows. The fixtures are testsrc2 — a moving pattern with a
/// frame counter — so two thumbnails seconds apart must differ in pixels,
/// which is what the content assertions lean on.
@Suite("Seek previews", .serialized)
struct SeekPreviewTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func rgbaBytes(_ image: CGImage) -> Data? {
        guard let provider = image.dataProvider, let data = provider.data else { return nil }
        return data as Data
    }

    @Test("A thumbnail decodes, fits the bound, and keeps the aspect")
    func basicThumbnail() async throws {
        let service = SeekPreviewService(
            url: try fixture("h264_aac_30s.mkv"), maxDimension: 160
        )
        defer { Task { await service.close() } }

        let image = try await service.thumbnail(at: 10)
        // 320×180 source bounded to 160 → 160×90.
        #expect(image.width <= 160 && image.height <= 160)
        #expect(image.width > image.height)
        let aspect = Double(image.width) / Double(image.height)
        #expect(abs(aspect - 320.0 / 180.0) < 0.05)
    }

    @Test("Different positions show different pictures; the same GOP is one decode")
    func contentAndCache() async throws {
        let service = SeekPreviewService(url: try fixture("h264_aac_30s.mkv"))
        defer { Task { await service.close() } }

        // 2 s keyframe cadence: 10.2 proves the interval [10.0, 10.2], so a
        // second request INSIDE it is a cache hit. (Forward of a proven
        // interval the next keyframe may lurk anywhere; without a harvested
        // map those requests decode — see keyframeMapIntegration for the
        // map-backed GOP-wide hit.)
        let first = try await service.thumbnail(at: 10.2)
        let proven = try await service.thumbnail(at: 10.05)
        let far = try await service.thumbnail(at: 24.0)

        #expect(await service.decodeCount == 2, "a request inside a proven interval must be a cache hit")
        #expect(rgbaBytes(first) == rgbaBytes(proven))
        #expect(rgbaBytes(first) != rgbaBytes(far), "thumbnails 14 s apart show the same picture")
    }

    @Test("Positions clamp: before the start and past the end still answer")
    func clamping() async throws {
        let service = SeekPreviewService(url: try fixture("h264_aac_30s.mkv"))
        defer { Task { await service.close() } }

        let head = try await service.thumbnail(at: -5)
        let tail = try await service.thumbnail(at: 10_000)
        #expect(head.width > 0)
        #expect(tail.width > 0)
        #expect(rgbaBytes(head) != rgbaBytes(tail))
    }

    @Test("A no-index source (MPEG-TS) still thumbnails")
    func mpegTS() async throws {
        let service = SeekPreviewService(url: try fixture("h264_ac3_30s.ts"))
        defer { Task { await service.close() } }
        let image = try await service.thumbnail(at: 15)
        #expect(image.width > 0)
    }

    @Test("VP9 — a software-path codec — thumbnails through the same pipe")
    func vp9() async throws {
        let service = SeekPreviewService(url: try fixture("vp9.webm"))
        defer { Task { await service.close() } }
        let image = try await service.thumbnail(at: 2)
        #expect(image.width > 0)
    }

    @Test("A harvested keyframe map resolves positions before any decode")
    func keyframeMapIntegration() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCorePreviewKF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCorePreviewOut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        // Harvest the TS fixture's map the way a first play does.
        let remuxer = HLSRemuxer(
            sourceURL: try fixture("h264_ac3_30s.ts"),
            outputDirectory: output,
            demand: DemandCoordinator(),
            keyframeCacheDirectory: cacheDirectory,
            indexLoadBudget: .zero
        )
        try remuxer.run()

        let service = SeekPreviewService(
            url: try fixture("h264_ac3_30s.ts"),
            keyframeIndexCacheDirectory: cacheDirectory
        )
        defer { Task { await service.close() } }

        // With the map, two positions of one GOP hit the cache even though
        // the first request never recorded THIS second — the map resolves the
        // keyframe before the demuxer is ever touched.
        _ = try await service.thumbnail(at: 10.1)
        _ = try await service.thumbnail(at: 11.2)
        #expect(await service.decodeCount == 1)
    }

    @Test("The binary search lands on the keyframe at or before the position")
    func keyframeLookup() {
        let sorted: [Int64] = [100, 300, 500, 700]
        #expect(SeekPreviewService.keyframe(atOrBefore: 50, in: sorted) == 100)
        #expect(SeekPreviewService.keyframe(atOrBefore: 100, in: sorted) == 100)
        #expect(SeekPreviewService.keyframe(atOrBefore: 499, in: sorted) == 300)
        #expect(SeekPreviewService.keyframe(atOrBefore: 700, in: sorted) == 700)
        #expect(SeekPreviewService.keyframe(atOrBefore: 9_000, in: sorted) == 700)
        #expect(SeekPreviewService.keyframe(atOrBefore: 0, in: []) == nil)
    }

    @Test("Requests after close() throw, they do not crash into freed contexts")
    func closedThrows() async throws {
        let service = SeekPreviewService(url: try fixture("h264_aac_30s.mkv"))
        _ = try await service.thumbnail(at: 5)
        await service.close()
        await #expect(throws: SeekPreviewService.Failure.self) {
            _ = try await service.thumbnail(at: 10)
        }
    }
}
