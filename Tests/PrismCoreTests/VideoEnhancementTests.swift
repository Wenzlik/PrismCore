import CoreGraphics
import Foundation
@preconcurrency import Metal
import Testing
@testable import PrismCore

#if os(iOS) || os(tvOS) || os(macOS)
import AVFoundation
#endif

/// The upscaler's rules, and its shaders run on the machine's GPU.
///
/// What a device run still has to show: that a 1080p film on a 4K panel
/// looks better rather than merely different, that frame-rate matching
/// still switches the panel, and that Picture in Picture and AirPlay take
/// the player layer cleanly. None of that is in a fixture.
@Suite("Video enhancement")
struct VideoEnhancementTests {

    // MARK: Lanczos-2 table

    @Test("Every phase's four taps sum to one, so a flat picture stays flat")
    func kernelPartitionOfUnity() {
        for taps in LanczosKernel.table {
            #expect(abs(taps.sum() - 1) < 1e-5)
        }
        #expect(LanczosKernel.table.count == LanczosKernel.phases)
    }

    @Test("On a source pixel the filter returns exactly that pixel")
    func kernelInterpolatesAtPixelCentres() {
        let first = LanczosKernel.table[0]
        let last = LanczosKernel.table[LanczosKernel.phases - 1]
        #expect(abs(first.y - 1) < 1e-6 && abs(first.x) < 1e-6 && abs(first.z) < 1e-6 && abs(first.w) < 1e-6)
        // Phase 1 is the next source pixel: all of the weight on tap `base + 1`.
        #expect(abs(last.z - 1) < 1e-6 && abs(last.x) < 1e-6 && abs(last.y) < 1e-6 && abs(last.w) < 1e-6)
    }

    @Test("The table is symmetric and has Lanczos' negative outer lobes")
    func kernelShape() {
        let count = LanczosKernel.phases
        for index in 0..<count {
            let taps = LanczosKernel.table[index]
            let mirror = LanczosKernel.table[count - 1 - index]
            #expect(abs(taps.x - mirror.w) < 1e-5)
            #expect(abs(taps.y - mirror.z) < 1e-5)
        }
        let middle = LanczosKernel.taps(phase: 0.5)
        #expect(middle.x < 0 && middle.w < 0, "the outer taps are what sharpens; without them this is a cubic")
        #expect(abs(middle.y - middle.z) < 1e-6)
        #expect(LanczosKernel.weight(2) == 0 && LanczosKernel.weight(-2.5) == 0)
        #expect(LanczosKernel.weight(0) == 1)
    }

    // MARK: Policy

    private let hd = CGSize(width: 1920, height: 1080)
    private let uhd = CGSize(width: 3840, height: 2160)

    private func verdict(
        _ mode: VideoEnhancementMode,
        source: CGSize? = CGSize(width: 1920, height: 1080),
        output: CGSize? = CGSize(width: 3840, height: 2160),
        _ edit: (inout VideoEnhancementConditions) -> Void = { _ in },
        external: Bool = false,
        detectedHDR: Bool = false,
        ceiling: VideoEnhancementQuality? = .lanczosSharpened,
        supported: Bool = true
    ) -> VideoEnhancementVerdict {
        var conditions = VideoEnhancementConditions(mode: mode, dynamicRange: .sdr)
        edit(&conditions)
        return VideoEnhancementPolicy.verdict(
            conditions: conditions,
            isExternalPlaybackActive: external,
            detectedHDR: detectedHDR,
            source: source,
            output: output,
            ceiling: ceiling,
            isSupported: supported
        )
    }

    @Test("1080p SDR on a 4K panel is upscaled under Automatic and On, never under Off")
    func upscalesSDR() {
        #expect(verdict(.automatic) == .active(.lanczosSharpened))
        #expect(verdict(.on) == .active(.lanczosSharpened))
        #expect(verdict(.off) == .native(.off))
    }

    @Test("HDR — declared or found on a frame — stays on the native layer")
    func hdrIsNative() {
        #expect(verdict(.on, { $0.dynamicRange = .pq }) == .native(.hdr))
        #expect(verdict(.on, { $0.dynamicRange = .hlg }) == .native(.hdr))
        #expect(verdict(.automatic, { $0.dynamicRange = nil }, detectedHDR: true) == .native(.hdr))
        // An unclassified source is allowed until a frame says otherwise.
        #expect(verdict(.automatic, { $0.dynamicRange = nil }) == .active(.lanczosSharpened))
    }

    @Test("Picture in Picture, AirPlay and AVFoundation's own subtitles fall back to the native layer")
    func systemSurfacesAreNative() {
        #expect(verdict(.on, { $0.isPictureInPictureActive = true }) == .native(.pictureInPicture))
        #expect(verdict(.on, external: true) == .native(.externalPlayback))
        #expect(verdict(.on, { $0.showsNativeSubtitles = true }) == .native(.nativeSubtitles))
    }

    @Test("Automatic wants a real upscale; On takes any; neither downscales")
    func scaleThresholds() {
        // 1080p into a 1200-line window: 1.11×.
        let slight = CGSize(width: 2133, height: 1200)
        #expect(verdict(.automatic, output: slight) == .native(.noUpscaleNeeded))
        #expect(verdict(.on, output: slight) == .active(.lanczosSharpened))
        // 720p → 1080p is 1.5×.
        #expect(verdict(.automatic, source: CGSize(width: 1280, height: 720), output: hd) == .active(.lanczosSharpened))
        // 4K into 4K, and 4K into 1080p.
        #expect(verdict(.on, source: uhd, output: uhd) == .native(.noUpscaleNeeded))
        #expect(verdict(.on, source: uhd, output: hd) == .native(.noUpscaleNeeded))
    }

    @Test("Scale is taken on the tighter axis")
    func scaleUsesTighterAxis() {
        // A 2.39:1 film letterboxed in 16:9: width decides.
        let scope = CGSize(width: 1920, height: 804)
        let picture = CGSize(width: 3840, height: 1607)
        let scale = VideoEnhancementPolicy.scale(source: scope, output: picture)
        #expect(scale.map { abs($0 - 1.9987) < 0.001 } == true)
        #expect(VideoEnhancementPolicy.scale(source: nil, output: picture) == nil)
        #expect(VideoEnhancementPolicy.scale(source: .zero, output: picture) == nil)
    }

    @Test("Until there is a size there is no decision to draw")
    func waitsForVideo() {
        #expect(verdict(.on, source: nil) == .native(.waitingForVideo))
        #expect(verdict(.on, output: nil) == .native(.waitingForVideo))
    }

    @Test("Heat and Low Power Mode win over On as well as Automatic")
    func powerConstraintWins() {
        #expect(verdict(.automatic, { $0.isPowerConstrained = true }) == .native(.powerConstrained))
        #expect(verdict(.on, { $0.isPowerConstrained = true }) == .native(.powerConstrained))
    }

    @Test("The governor's ceiling is the quality, and giving up is a fallback")
    func governorCeiling() {
        #expect(verdict(.on, ceiling: .lanczos) == .active(.lanczos))
        #expect(verdict(.on, ceiling: nil) == .native(.droppedFrames))
        #expect(verdict(.on, supported: false) == .native(.unsupported))
    }

    @Test("Sharpening is gentle near 1× and capped from 2×")
    func sharpeningStrength() {
        #expect(VideoEnhancementPolicy.sharpening(forScale: 0.5) == VideoEnhancementPolicy.sharpening(forScale: 1))
        #expect(VideoEnhancementPolicy.sharpening(forScale: 1) < VideoEnhancementPolicy.sharpening(forScale: 1.5))
        #expect(VideoEnhancementPolicy.sharpening(forScale: 2) == VideoEnhancementPolicy.sharpening(forScale: 3))
        #expect(VideoEnhancementPolicy.sharpening(forScale: 3) <= 0.6 + 1e-6)
    }

    // MARK: Governor

    @Test("Dropped frames step down to Lanczos alone, then to the native layer for good")
    func governorStepsDown() {
        var governor = VideoEnhancementGovernor()
        // The first window is warm-up and never counts.
        #expect(!governor.record(presented: 40, dropped: 20))
        #expect(governor.ceiling == .lanczosSharpened)
        #expect(governor.record(presented: 40, dropped: 8))
        #expect(governor.ceiling == .lanczos)
        // The cheaper level gets its own warm-up.
        #expect(!governor.record(presented: 40, dropped: 8))
        #expect(governor.record(presented: 40, dropped: 8))
        #expect(governor.ceiling == nil)
        // Sticky: clean windows do not bring it back.
        for _ in 0..<40 { governor.record(presented: 48, dropped: 0) }
        #expect(governor.ceiling == nil)
        governor.reset()
        #expect(governor.ceiling == .lanczosSharpened)
    }

    @Test("One late frame is noise, not a reason to step down")
    func governorToleratesNoise() {
        var governor = VideoEnhancementGovernor()
        governor.record(presented: 48, dropped: 0)
        #expect(!governor.record(presented: 47, dropped: 1))
        // 2 of 120 at 60 fps is 1.7 %: under the tolerance.
        #expect(!governor.record(presented: 118, dropped: 2))
        #expect(governor.ceiling == .lanczosSharpened)
    }

    @Test("Thirty clean seconds bring sharpening back, once")
    func governorRecoversOnce() {
        var governor = VideoEnhancementGovernor()
        governor.record(presented: 48, dropped: 0)
        governor.record(presented: 40, dropped: 8)
        #expect(governor.ceiling == .lanczos)
        governor.record(presented: 48, dropped: 0) // warm-up of the new level
        for _ in 0..<(VideoEnhancementGovernor.cleanWindowsToRecover - 1) {
            #expect(!governor.record(presented: 48, dropped: 0))
        }
        #expect(governor.record(presented: 48, dropped: 0))
        #expect(governor.ceiling == .lanczosSharpened)
        // A second struggle, a second recovery period: no second step up.
        governor.record(presented: 48, dropped: 0) // warm-up after the step up
        governor.record(presented: 40, dropped: 8)
        #expect(governor.ceiling == .lanczos)
        for _ in 0..<(VideoEnhancementGovernor.cleanWindowsToRecover * 3) {
            governor.record(presented: 48, dropped: 0)
        }
        #expect(governor.ceiling == .lanczos)
    }

    // MARK: Drop counter

    @Test("A frame skipped after a missed vsync is a drop")
    func dropCounterCountsSkippedFrames() {
        var counter = VideoEnhancementDropCounter()
        let frame = 1.0 / 24
        #expect(counter.noteFrame(itemTime: 10, frameDuration: frame, isPlaying: true) == 0)
        counter.noteTick(elapsed: 1.0 / 60, period: 1.0 / 60)
        #expect(counter.noteFrame(itemTime: 10 + frame, frameDuration: frame, isPlaying: true) == 0)
        counter.noteTick(elapsed: 5.0 / 60, period: 1.0 / 60)
        #expect(counter.noteFrame(itemTime: 10 + 3 * frame, frameDuration: frame, isPlaying: true) == 1)
    }

    @Test("Content faster than the display, seeks and pauses are not drops")
    func dropCounterIgnoresCadenceAndSeeks() {
        var counter = VideoEnhancementDropCounter()
        let frame = 1.0 / 60
        // 60 fps on a 50 Hz panel: every vsync on time, a frame skipped now and then.
        _ = counter.noteFrame(itemTime: 0, frameDuration: frame, isPlaying: true)
        counter.noteTick(elapsed: 0.02, period: 0.02)
        #expect(counter.noteFrame(itemTime: 2 * frame, frameDuration: frame, isPlaying: true) == 0)
        // A seek forward.
        counter.noteTick(elapsed: 0.2, period: 0.02)
        #expect(counter.noteFrame(itemTime: 120, frameDuration: frame, isPlaying: true) == 0)
        // Backwards.
        counter.noteTick(elapsed: 0.2, period: 0.02)
        #expect(counter.noteFrame(itemTime: 30, frameDuration: frame, isPlaying: true) == 0)
        // Paused: a stepped frame is not a drop.
        counter.noteTick(elapsed: 0.2, period: 0.02)
        #expect(counter.noteFrame(itemTime: 30 + 5 * frame, frameDuration: frame, isPlaying: false) == 0)
    }

    @Test("Without a reported frame rate the shortest gap stands in")
    func dropCounterLearnsFrameDuration() {
        var counter = VideoEnhancementDropCounter()
        let frame = 1.0 / 25
        _ = counter.noteFrame(itemTime: 0, frameDuration: nil, isPlaying: true)
        counter.noteTick(elapsed: 0.02, period: 0.02)
        _ = counter.noteFrame(itemTime: frame, frameDuration: nil, isPlaying: true)
        counter.noteTick(elapsed: 0.1, period: 0.02)
        #expect(counter.noteFrame(itemTime: 4 * frame, frameDuration: nil, isPlaying: true) == 2)
    }

    // MARK: Geometry

    #if os(iOS) || os(tvOS) || os(macOS)
    @Test("Before AVPlayer knows the size, the hint is framed the way the layer will frame it")
    func estimatedRect() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scope = CGSize(width: 1920, height: 800)
        let fit = VideoEnhancementRenderer.estimatedVideoRect(for: scope, in: bounds, gravity: .resizeAspect)
        #expect(fit.width == 1920 && abs(fit.height - 800) < 0.5 && abs(fit.minY - 140) < 0.5)
        let fill = VideoEnhancementRenderer.estimatedVideoRect(for: scope, in: bounds, gravity: .resizeAspectFill)
        #expect(abs(fill.height - 1080) < 0.5 && fill.width > 1920 && fill.minX < 0)
        #expect(VideoEnhancementRenderer.estimatedVideoRect(for: scope, in: bounds, gravity: .resize) == bounds)
        #expect(VideoEnhancementRenderer.estimatedVideoRect(for: .zero, in: bounds, gravity: .resizeAspect) == .zero)
    }
    #endif

    @Test("A picture past the target draws only its visible part")
    func pixelRectIntersection() {
        let fill = VideoEnhancementPixelRect(x: -240, y: 0, width: 4320, height: 2160)
        #expect(fill.intersection(width: 3840, height: 2160) == .init(x: 0, y: 0, width: 3840, height: 2160))
        let offscreen = VideoEnhancementPixelRect(x: 4000, y: 0, width: 100, height: 100)
        #expect(offscreen.intersection(width: 3840, height: 2160).isEmpty)
    }

    // MARK: Shaders on the GPU

    @Test("The shaders compile and every pipeline builds", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func pipelinesBuild() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        _ = try VideoEnhancementPipeline(device: device)
        // The shared one is the same build, cached.
        let shared = try VideoEnhancementPipeline.shared(device: device)
        #expect(try VideoEnhancementPipeline.shared(device: device) === shared)
    }

    @Test("Uniform layouts match the shader's structs")
    func uniformLayouts() {
        // int2 + int2 + float2 + float2 + float + uint, 8-byte aligned.
        #expect(MemoryLayout<VideoEnhancementPipeline.ScaleUniforms>.size == 40)
        #expect(MemoryLayout<VideoEnhancementPipeline.ScaleUniforms>.offset(of: \.antiRinging) == 32)
        // float2 + int2 + float, padded to 24 by Metal; Swift's stride says the same.
        #expect(MemoryLayout<VideoEnhancementPipeline.SharpenUniforms>.stride == 24)
        #expect(MemoryLayout<VideoEnhancementPipeline.SharpenUniforms>.offset(of: \.strength) == 16)
    }

    @Test("A flat grey upscales to the same flat grey, with and without sharpening",
          .enabled(if: MTLCreateSystemDefaultDevice() != nil),
          arguments: VideoEnhancementQuality.allCases)
    func flatStaysFlat(quality: VideoEnhancementQuality) throws {
        let gpu = try GPUHarness()
        let source = try gpu.texture(width: 8, height: 6) { _, _ in 128 }
        let output = try gpu.render(
            source: source, sourceSize: (8, 6), target: (20, 15),
            picture: .init(x: 0, y: 0, width: 20, height: 15), quality: quality
        )
        for value in output.grey { #expect(abs(Int(value) - 128) <= 1) }
    }

    @Test("A hard edge gets no halo: every pixel stays between the two sides",
          .enabled(if: MTLCreateSystemDefaultDevice() != nil),
          arguments: VideoEnhancementQuality.allCases)
    func edgeHasNoHalo(quality: VideoEnhancementQuality) throws {
        let gpu = try GPUHarness()
        // 25 % grey on the left, 75 % on the right: overshoot either way
        // would show as a value outside 64…191.
        let source = try gpu.texture(width: 8, height: 4) { x, _ in x < 4 ? 64 : 191 }
        let output = try gpu.render(
            source: source, sourceSize: (8, 4), target: (24, 12),
            picture: .init(x: 0, y: 0, width: 24, height: 12), quality: quality
        )
        for value in output.grey { #expect(value >= 63 && value <= 192) }
        // And it is still an edge: the far columns keep their sides.
        #expect(abs(Int(output.value(x: 0, y: 6)) - 64) <= 1)
        #expect(abs(Int(output.value(x: 23, y: 6)) - 191) <= 1)
    }

    @Test("Outside the picture the target is transparent, so the host's bars show",
          .enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func barsAreTransparent() throws {
        let gpu = try GPUHarness()
        let source = try gpu.texture(width: 4, height: 2) { _, _ in 200 }
        // A letterboxed picture in rows 4…11 of a 16-row target.
        let output = try gpu.render(
            source: source, sourceSize: (4, 2), target: (16, 16),
            picture: .init(x: 0, y: 4, width: 16, height: 8), quality: .lanczosSharpened
        )
        #expect(output.alpha(x: 8, y: 1) == 0)
        #expect(output.alpha(x: 8, y: 14) == 0)
        #expect(output.alpha(x: 8, y: 8) == 255)
        #expect(abs(Int(output.value(x: 8, y: 8)) - 200) <= 1)
    }

    @Test("Only the clean aperture is read: rows past it never reach the picture",
          .enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func cleanApertureIsRespected() throws {
        let gpu = try GPUHarness()
        // A 1088-style buffer: the last two rows are padding, painted white.
        let source = try gpu.texture(width: 8, height: 10) { _, y in y >= 8 ? 255 : 100 }
        let output = try gpu.render(
            source: source, sourceSize: (8, 8), target: (16, 16),
            picture: .init(x: 0, y: 0, width: 16, height: 16), quality: .lanczosSharpened
        )
        for value in output.grey { #expect(abs(Int(value) - 100) <= 1) }
    }
}

/// An offscreen run of `VideoEnhancementPipeline`: grey BGRA in, bytes out.
private struct GPUHarness {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: VideoEnhancementPipeline

    struct Output {
        let width: Int
        let bytes: [UInt8]
        /// The green channel of every pixel (the tests draw grey).
        var grey: [UInt8] { stride(from: 1, to: bytes.count, by: 4).map { bytes[$0] } }
        func value(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 1] }
        func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
    }

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        pipeline = try VideoEnhancementPipeline.shared(device: device)
    }

    func texture(width: Int, height: Int, grey: (Int, Int) -> UInt8) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let value = grey(x, y)
                bytes += [value, value, value, 255]
            }
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: width * 4
        )
        return texture
    }

    func render(
        source: any MTLTexture,
        sourceSize: (Int, Int),
        target: (Int, Int),
        picture: VideoEnhancementPixelRect,
        quality: VideoEnhancementQuality
    ) throws -> Output {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: target.0, height: target.1, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let bytesPerRow = target.0 * 4
        let readback = try #require(device.makeBuffer(length: bytesPerRow * target.1, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoded = pipeline.encode(
            into: commandBuffer,
            source: .init(texture: source, origin: .zero, size: SIMD2(Int32(sourceSize.0), Int32(sourceSize.1))),
            target: output,
            picture: picture,
            quality: quality,
            sharpening: 0.6,
            scratch: VideoEnhancementScratch()
        )
        #expect(encoded)
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: output, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: target.0, height: target.1, depth: 1),
            to: readback, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * target.1
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        let pointer = readback.contents().bindMemory(to: UInt8.self, capacity: bytesPerRow * target.1)
        return Output(width: target.0, bytes: Array(UnsafeBufferPointer(start: pointer, count: bytesPerRow * target.1)))
    }
}
