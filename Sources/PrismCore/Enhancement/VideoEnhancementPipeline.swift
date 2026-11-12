import Foundation
@preconcurrency import Metal

/// A rectangle in a render target's pixels. The picture's rect may reach
/// past the target (Fill, a forced aspect zoom); only its visible part is
/// drawn, and every pass still maps the whole picture.
struct VideoEnhancementPixelRect: Sendable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var isEmpty: Bool { width <= 0 || height <= 0 }

    func intersection(width targetWidth: Int, height targetHeight: Int) -> Self {
        let left = max(x, 0)
        let top = max(y, 0)
        let right = min(x + width, targetWidth)
        let bottom = min(y + height, targetHeight)
        return Self(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }
}

/// The renderer's built pipelines and the per-frame encode, without any
/// display link, layer or player — so a test can push a synthetic texture
/// through exactly what plays.
///
/// Safety (`@unchecked Sendable`): every stored property is a `let`, set in
/// `init`, and Metal documents devices and pipeline states as thread-safe.
final class VideoEnhancementPipeline: @unchecked Sendable {
    enum BuildError: Error, Equatable {
        case missingFunction(String)
    }

    /// Must match `ScaleUniforms` in `VideoEnhancementShaders.source`.
    struct ScaleUniforms {
        var sourceOrigin: SIMD2<Int32>
        var sourceSize: SIMD2<Int32>
        var targetOrigin: SIMD2<Float>
        var targetSize: SIMD2<Float>
        var antiRinging: Float
        var phases: UInt32
    }

    /// Must match `SharpenUniforms` in `VideoEnhancementShaders.source`.
    struct SharpenUniforms {
        var targetOrigin: SIMD2<Float>
        var size: SIMD2<Int32>
        var strength: Float
    }

    /// Eight bits are enough between the passes because both Lanczos passes
    /// clamp fully (`antiRinging`): no intermediate value leaves 0…1, and the
    /// source is eight-bit SDR. Half floats would double ~50 MB of scratch
    /// at 4K, on an Apple TV that has 3 GB for everything.
    static let intermediateFormat: MTLPixelFormat = .rgba8Unorm
    static let antiRinging: Float = 1

    let device: any MTLDevice
    let outputFormat: MTLPixelFormat
    private let horizontal: any MTLRenderPipelineState
    private let verticalToScratch: any MTLRenderPipelineState
    private let verticalToOutput: any MTLRenderPipelineState
    private let sharpen: any MTLRenderPipelineState

    init(device: any MTLDevice, outputFormat: MTLPixelFormat = .bgra8Unorm) throws {
        let library = try device.makeLibrary(source: VideoEnhancementShaders.source, options: nil)
        func function(_ name: String) throws -> any MTLFunction {
            guard let function = library.makeFunction(name: name) else {
                throw BuildError.missingFunction(name)
            }
            return function
        }
        let vertex = try function(VideoEnhancementShaders.vertexFunction)
        func state(_ fragment: String, _ format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = try function(fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.device = device
        self.outputFormat = outputFormat
        self.horizontal = try state(VideoEnhancementShaders.horizontalFunction, Self.intermediateFormat)
        self.verticalToScratch = try state(VideoEnhancementShaders.verticalFunction, Self.intermediateFormat)
        self.verticalToOutput = try state(VideoEnhancementShaders.verticalFunction, outputFormat)
        self.sharpen = try state(VideoEnhancementShaders.sharpenFunction, outputFormat)
    }

    // MARK: Process-wide cache

    /// Compiling the source costs tens of milliseconds and the answer never
    /// changes for a device, so it happens once per process — and a failure
    /// is remembered too, rather than paid for on every title.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [UInt64: Result<VideoEnhancementPipeline, any Error>] = [:]

    static func shared(device: any MTLDevice) throws -> VideoEnhancementPipeline {
        // Safety: `cache` is only touched under `cacheLock`.
        let key = device.registryID
        if let cached = cacheLock.withLock({ cache[key] }) { return try cached.get() }
        let built = Result { try VideoEnhancementPipeline(device: device) }
        cacheLock.withLock { cache[key] = built }
        return try built.get()
    }

    // MARK: Encoding

    /// The frame to draw: a texture and the region of it that is picture
    /// (the clean aperture — a 1088-line H.264 buffer shows 1080).
    struct Source {
        var texture: any MTLTexture
        var origin: SIMD2<Int32>
        var size: SIMD2<Int32>
    }

    /// Encodes one frame into `target`, cleared to transparent outside the
    /// picture so the host's layer shows through its bars. Returns `false`
    /// (and encodes nothing) when there is nothing to draw.
    @discardableResult
    func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: Source,
        target: any MTLTexture,
        picture: VideoEnhancementPixelRect,
        quality: VideoEnhancementQuality,
        sharpening: Float,
        scratch: VideoEnhancementScratch
    ) -> Bool {
        let visible = picture.intersection(width: target.width, height: target.height)
        guard !picture.isEmpty, !visible.isEmpty, source.size.x > 0, source.size.y > 0,
              let across = scratch.texture(.horizontal, width: picture.width,
                                           height: Int(source.size.y), device: device)
        else { return false }

        var weights = LanczosKernel.table
        let weightBytes = MemoryLayout<SIMD4<Float>>.stride * weights.count

        // 1. Horizontal: clean aperture → picture width × source height.
        var horizontalUniforms = ScaleUniforms(
            sourceOrigin: source.origin,
            sourceSize: source.size,
            targetOrigin: .zero,
            targetSize: SIMD2(Float(picture.width), Float(source.size.y)),
            antiRinging: Self.antiRinging,
            phases: UInt32(weights.count)
        )
        guard let first = commandBuffer.makeRenderCommandEncoder(
            descriptor: Self.pass(across, load: .dontCare)
        ) else { return false }
        first.label = "Enhancement · Lanczos horizontal"
        first.setRenderPipelineState(horizontal)
        first.setFragmentTexture(source.texture, index: 0)
        first.setFragmentBytes(&weights, length: weightBytes, index: 0)
        first.setFragmentBytes(&horizontalUniforms, length: MemoryLayout<ScaleUniforms>.stride, index: 1)
        first.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        first.endEncoding()

        // 2. Vertical: → picture size, straight to the target when there is
        //    no sharpening pass after it.
        let sharpens = quality == .lanczosSharpened && sharpening > 0
        let pictureOrigin = SIMD2(Float(picture.x), Float(picture.y))
        let verticalTarget: any MTLTexture
        if sharpens {
            guard let full = scratch.texture(.vertical, width: picture.width,
                                             height: picture.height, device: device)
            else { return false }
            verticalTarget = full
        } else {
            verticalTarget = target
        }
        var verticalUniforms = ScaleUniforms(
            sourceOrigin: .zero,
            sourceSize: SIMD2(Int32(picture.width), source.size.y),
            targetOrigin: sharpens ? .zero : pictureOrigin,
            targetSize: SIMD2(Float(picture.width), Float(picture.height)),
            antiRinging: Self.antiRinging,
            phases: UInt32(weights.count)
        )
        guard let second = commandBuffer.makeRenderCommandEncoder(
            descriptor: Self.pass(verticalTarget, load: sharpens ? .dontCare : .clear)
        ) else { return false }
        second.label = "Enhancement · Lanczos vertical"
        second.setRenderPipelineState(sharpens ? verticalToScratch : verticalToOutput)
        if !sharpens { second.setViewport(Self.viewport(visible)) }
        second.setFragmentTexture(across, index: 0)
        second.setFragmentBytes(&weights, length: weightBytes, index: 0)
        second.setFragmentBytes(&verticalUniforms, length: MemoryLayout<ScaleUniforms>.stride, index: 1)
        second.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        second.endEncoding()

        guard sharpens else { return true }

        // 3. Sharpen: → the target's visible part of the picture.
        var sharpenUniforms = SharpenUniforms(
            targetOrigin: pictureOrigin,
            size: SIMD2(Int32(picture.width), Int32(picture.height)),
            strength: sharpening
        )
        guard let third = commandBuffer.makeRenderCommandEncoder(
            descriptor: Self.pass(target, load: .clear)
        ) else { return false }
        third.label = "Enhancement · sharpen"
        third.setRenderPipelineState(sharpen)
        third.setViewport(Self.viewport(visible))
        third.setFragmentTexture(verticalTarget, index: 0)
        third.setFragmentBytes(&sharpenUniforms, length: MemoryLayout<SharpenUniforms>.stride, index: 0)
        third.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        third.endEncoding()
        return true
    }

    private static func pass(_ texture: any MTLTexture, load: MTLLoadAction) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private static func viewport(_ rect: VideoEnhancementPixelRect) -> MTLViewport {
        MTLViewport(
            originX: Double(rect.x), originY: Double(rect.y),
            width: Double(rect.width), height: Double(rect.height),
            znear: 0, zfar: 1
        )
    }
}

/// The intermediate textures, kept between frames and rebuilt only when the
/// picture's size changes. Used from one thread at a time (the renderer's
/// main actor, or a test).
final class VideoEnhancementScratch {
    enum Slot { case horizontal, vertical }

    private var horizontal: (any MTLTexture)?
    private var vertical: (any MTLTexture)?

    init() {}

    func texture(_ slot: Slot, width: Int, height: Int, device: any MTLDevice) -> (any MTLTexture)? {
        guard width > 0, height > 0 else { return nil }
        let existing = slot == .horizontal ? horizontal : vertical
        if let existing, existing.width == width, existing.height == height { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: VideoEnhancementPipeline.intermediateFormat,
            width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let made = device.makeTexture(descriptor: descriptor)
        made?.label = slot == .horizontal ? "Enhancement · horizontal" : "Enhancement · vertical"
        switch slot {
        case .horizontal: horizontal = made
        case .vertical: vertical = made
        }
        return made
    }

    /// Gives the memory back while the renderer is not drawing.
    func release() {
        horizontal = nil
        vertical = nil
    }
}
