import Foundation
import AVFoundation
import CoreGraphics

/// Decodes only a private snapshot of completed local media. Missing cache
/// entries never trigger production or another connection to the origin.
actor CachedSegmentPreview {
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private var generation = 0

    func clear() {
        generation += 1
        images.removeAll()
        order.removeAll()
    }

    func image(index: Int, data: Data, maxDimension: Int) async throws -> CGImage? {
        let dimension = min(2048, max(32, maxDimension))
        let key = "\(index)/\(dimension)"
        if let image = images[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return image
        }
        let currentGeneration = generation
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCorePreview-\(UUID().uuidString).mp4")
        try data.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: dimension, height: dimension)
        // An isolated fragment can begin at an absolute tfdt well above zero.
        // Ask at the track's start, not at zero or at the source scrub target.
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let range = try await track.load(.timeRange)
        let image = try await generator.image(at: range.start).image
        try Task.checkCancellation()
        guard currentGeneration == generation else { return nil }
        images[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 32 || images.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) > 16 << 20 {
            images.removeValue(forKey: order.removeFirst())
        }
        return image
    }
}
