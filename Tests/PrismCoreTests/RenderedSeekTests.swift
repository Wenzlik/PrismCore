import Testing
import Foundation
import AVFoundation
import CoreVideo
@testable import PrismCore

@Suite("Rendered seek", .serialized)
@MainActor
struct RenderedSeekTests {
    /// Requires the AVFoundation rendering service, so device/desktop runs
    /// opt in. The fixture and throttled origin are the same on every run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_RENDERED_SEEK"] == "1"))
    func pictureMatchesPlayerClockAfterSeeks() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "seek_clock", withExtension: "mkv", subdirectory: "Fixtures"))
        let server = try RangeFixtureServer(media: Data(contentsOf: fixture), bytesPerSecond: 300_000, firstByteDelay: 0.08)
        let url = try await server.start()
        defer { server.stop() }
        let session = try PrismCoreSession(url: url, coordinatedHTTP: true)
        let player = AVPlayer()
        player.isMuted = true
        do {
            let playlist = try await session.start()
            let item = AVPlayerItem(url: playlist)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            player.replaceCurrentItem(with: item)
            player.play()
            let deadline = ContinuousClock.now + .seconds(15)
            while item.status == .unknown && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(item.status == .readyToPlay)
            for target in [72.0, 4.0, 84.0, 35.0] {
                let landed = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                #expect(landed)
                let limit = ContinuousClock.now + .seconds(12)
                var observed = false
                while ContinuousClock.now < limit {
                    let requested = output.itemTime(forHostTime: CACurrentMediaTime())
                    var displayTime = CMTime.invalid
                    if let pixels = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayTime),
                       displayTime.isNumeric, displayTime.seconds >= target - 0.1,
                       let frame = Self.frameIndex(pixels) {
                        // The picture can only express time in 1/24 s steps.
                        #expect(abs(Double(frame) / 24 - displayTime.seconds) <= 2.0 / 24)
                        #expect(displayTime.seconds < target + 2)
                        observed = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(observed, "No presented frame after seek to \(target)")
            }
            player.replaceCurrentItem(with: nil)
            await session.stop()
        } catch {
            player.replaceCurrentItem(with: nil)
            await session.stop()
            throw error
        }
    }

    private static func frameIndex(_ buffer: CVPixelBuffer) -> Int? {
        guard CVPixelBufferGetWidth(buffer) == 480, CVPixelBufferGetHeight(buffer) >= 112 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buffer) * 112
        var value = 0
        for bit in 0..<12 {
            if base[row + (bit * 40 + 20) * 4] > 128 { value |= 1 << bit }
        }
        return value
    }
}
