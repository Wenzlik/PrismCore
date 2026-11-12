#if os(iOS) || os(tvOS) || os(macOS)
import AVFoundation
import CoreVideo
import Foundation
@preconcurrency import Metal
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Lanczos-2 upscaling with adaptive sharpening for a host's `AVPlayer`.
///
/// **Shape.** The host keeps its `AVPlayerLayer` exactly as it is; the
/// renderer adds a `CAMetalLayer` *above the video* (a sublayer of that player
/// layer) and draws into it the frames it pulls from an
/// `AVPlayerItemVideoOutput` on the current item. Wherever the renderer is not
/// drawing — off, HDR, Picture in Picture, AirPlay, subtitles AVFoundation
/// draws into the layer, no upscale to do, too many dropped frames — its layer
/// is hidden and the player layer, which never stopped rendering, is the
/// picture. That is what keeps every system behaviour intact: Picture in
/// Picture and AirPlay take the player layer as they always did, and the
/// tvOS display handshake (frame-rate and range matching) still belongs to
/// whoever programmed it, because nothing about the item or the layer it is
/// attached to changes. The display link presents one drawable per vsync of
/// the mode the panel is in, so a matched 23.976 Hz panel shows each frame
/// once, as the layer would.
///
/// **SDR only.** It draws eight-bit BGRA. A source the host declares PQ or
/// HLG never reaches it, and one the host could not classify is checked on
/// its first frame — before the renderer's layer is shown — and handed back
/// for the rest of the item if it carries a PQ or HLG transfer function.
///
/// **The output is attached once.** Adding or removing an
/// `AVPlayerItemVideoOutput` on a playing item rebuilds the video pipeline
/// under the picture, and a wrong frame flashes (a host found this the hard
/// way, removing one at the first frame on tvOS). So the output goes onto
/// the item the first time the renderer has reason to draw it — before the
/// item plays when the host passes `sourceSizeHint` — and stays through
/// passing fallbacks (Picture in Picture, subtitles, a rotation). It comes
/// off only when this item will not be drawn again (too many dropped frames,
/// HDR, `.off`) and at `invalidate()`.
///
/// **Dropped frames** are counted from the item times of the frames shown
/// (`VideoEnhancementDropCounter`) and from frames skipped because the GPU
/// was still busy with the previous two; `VideoEnhancementGovernor` lowers
/// the quality and finally gives the item back to the native layer.
///
/// Main actor only. Call `invalidate()` when the player goes away.
@MainActor
public final class VideoEnhancementRenderer {
    /// What Playback Info shows.
    public struct Status: Sendable, Equatable {
        public var verdict: VideoEnhancementVerdict
        /// The source's displayed size in pixels, when known.
        public var sourceSize: CGSize?
        /// The on-screen picture in pixels, when known.
        public var outputSize: CGSize?
        /// Frames the renderer lost on this item.
        public var droppedFrames: Int
        /// A frame the renderer drew is what is on screen right now.
        public var isDrawing: Bool

        public init(
            verdict: VideoEnhancementVerdict,
            sourceSize: CGSize? = nil,
            outputSize: CGSize? = nil,
            droppedFrames: Int = 0,
            isDrawing: Bool = false
        ) {
            self.verdict = verdict
            self.sourceSize = sourceSize
            self.outputSize = outputSize
            self.droppedFrames = droppedFrames
            self.isDrawing = isDrawing
        }
    }

    /// Whether this device can run the renderer at all.
    public static var isSupported: Bool { MTLCreateSystemDefaultDevice() != nil }

    /// The host's facts. Setting them re-decides at once.
    public var conditions: VideoEnhancementConditions {
        didSet { if conditions != oldValue { conditionsChanged(from: oldValue) } }
    }

    /// Point-to-pixel scale for the drawable. `nil` takes the screen's
    /// `nativeScale` through the view that hosts the player layer (on macOS,
    /// the display-link view's window's backing scale), and the layer's own
    /// `contentsScale` only when neither is there.
    public var contentsScale: CGFloat? {
        didSet { if contentsScale != oldValue { refresh() } }
    }

    public private(set) var status: Status
    /// Told on every change of `status`.
    public var onStatusChange: (@MainActor (Status) -> Void)?

    private let player: AVPlayer
    private weak var playerLayer: AVPlayerLayer?
    private let attachments: Attachments
    private var metalLayer: CAMetalLayer { attachments.layer }
    private var output: AVPlayerItemVideoOutput { attachments.output }
    private let device: (any MTLDevice)?
    private let queue: (any MTLCommandQueue)?
    private var textureCache: CVMetalTextureCache?
    private var pipeline: VideoEnhancementPipeline?
    private var pipelineFailed = false
    private var pipelineTask: Task<Void, Never>?
    private let scratch = VideoEnhancementScratch()
    private let inFlight = InFlightFrames()

    private var displayLink: CADisplayLink?
    private var linkPace: LinkPace?
    private let linkTarget = DisplayLinkTarget()
    #if os(macOS)
    private weak var displayLinkView: NSView?
    #endif
    private var observations: [NSKeyValueObservation] = []

    private var verdict: VideoEnhancementVerdict = .native(.off)
    private var governor = VideoEnhancementGovernor()
    private var drops = VideoEnhancementDropCounter()
    private var detectedHDR = false
    private var sourceSize: CGSize?
    private var picture: VideoEnhancementPixelRect?
    private var hasDrawnSinceActivation = false
    private var appliedColorSpace = false
    private var frameDuration: Double?

    private var lastTick: CFTimeInterval?
    /// The interval the link announced at the previous callback.
    private var lastPeriod: CFTimeInterval?
    private var windowStart: CFTimeInterval?
    private var windowPresented = 0
    private var windowDropped = 0
    private var droppedOnItem = 0
    private var invalidated = false

    /// Fewer frames than this in a window (a pause, a seek) say nothing
    /// about what the device sustains.
    private static let minimumFramesPerWindow = 12
    /// Frames the GPU may be behind before the next one is skipped rather
    /// than queued. Two keeps latency to a frame and never blocks the main
    /// thread on `nextDrawable()`.
    private static let maximumFramesInFlight = 2

    #if os(macOS)
    /// - Parameter displayLinkView: the view the player layer is on screen
    ///   in — macOS hands out display links per view, following its screen.
    public init(
        player: AVPlayer,
        playerLayer: AVPlayerLayer,
        displayLinkView: NSView,
        conditions: VideoEnhancementConditions = .init()
    ) {
        self.player = player
        self.playerLayer = playerLayer
        self.conditions = conditions
        self.displayLinkView = displayLinkView
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.queue = device?.makeCommandQueue()
        self.attachments = Attachments()
        self.status = Status(verdict: .native(.off))
        start(on: playerLayer)
    }
    #else
    public init(
        player: AVPlayer,
        playerLayer: AVPlayerLayer,
        conditions: VideoEnhancementConditions = .init()
    ) {
        self.player = player
        self.playerLayer = playerLayer
        self.conditions = conditions
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.queue = device?.makeCommandQueue()
        self.attachments = Attachments()
        self.status = Status(verdict: .native(.off))
        start(on: playerLayer)
    }
    #endif

    deinit {
        // A host that forgot `invalidate()` must not leave a stale frame over
        // the video, nor an output converting frames nobody reads.
        let attachments = attachments
        DispatchQueue.main.async { attachments.tearDown() }
    }

    /// Stops drawing for good: the layer leaves the player layer, the output
    /// leaves the item, the display link stops. Idempotent.
    public func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        pipelineTask?.cancel()
        displayLink?.invalidate()
        displayLink = nil
        observations.forEach { $0.invalidate() }
        observations = []
        attachments.tearDown()
        scratch.release()
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        verdict = .native(.off)
        publish()
    }

    // MARK: Setup

    private func start(on playerLayer: AVPlayerLayer) {
        let layer = metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // Transparent outside the picture: the player layer's own bars show.
        layer.isOpaque = false
        layer.isHidden = true
        layer.actions = ["hidden": NSNull(), "bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        playerLayer.addSublayer(layer)

        linkTarget.renderer = self
        if let device {
            var cache: CVMetalTextureCache?
            _ = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            textureCache = cache
        }
        observations = Self.observe(player, renderer: self)
        buildPipeline()
        itemChanged()
    }

    private func buildPipeline() {
        guard let device else {
            pipelineFailed = true
            return
        }
        pipelineTask = Task { [weak self] in
            // Compiling the source is tens of milliseconds: not on the
            // main actor, and only once per process.
            let built = await Task.detached(priority: .userInitiated) {
                try? VideoEnhancementPipeline.shared(device: device)
            }.value
            guard let self, !self.invalidated else { return }
            if let built { self.pipeline = built } else { self.pipelineFailed = true }
            self.reevaluate()
        }
    }

    /// KVO callbacks arrive on whichever thread changed the property, so
    /// they are written here, outside the actor, and hop to it.
    private nonisolated static func observe(
        _ player: AVPlayer, renderer: VideoEnhancementRenderer
    ) -> [NSKeyValueObservation] {
        [
            player.observe(\.currentItem, options: [.new]) { [weak renderer] _, _ in
                let target = renderer
                Task { @MainActor in target?.itemChanged() }
            },
            player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak renderer] _, _ in
                let target = renderer
                Task { @MainActor in target?.refresh() }
            },
        ]
    }

    // MARK: Decisions

    private func conditionsChanged(from old: VideoEnhancementConditions) {
        if conditions.sourceSizeHint != old.sourceSizeHint, presentationSize() == nil {
            sourceSize = conditions.sourceSizeHint
        }
        // A declared range is the host's reading of this item; a new one
        // (a new item, usually) clears what a frame said about the last.
        if conditions.dynamicRange != old.dynamicRange { detectedHDR = false }
        reevaluate()
    }

    private func itemChanged() {
        guard !invalidated else { return }
        if attachments.item !== player.currentItem { attachments.detachOutput() }
        // The last frame drawn belongs to the previous item: off the screen
        // now, and the next activation starts from scratch.
        setLayerHidden(true)
        hasDrawnSinceActivation = false
        verdict = .native(.waitingForVideo)
        governor.reset()
        drops.reset()
        detectedHDR = false
        droppedOnItem = 0
        appliedColorSpace = false
        frameDuration = nil
        resetWindow(at: nil)
        sourceSize = presentationSize() ?? conditions.sourceSizeHint
        updateGeometry()
        reevaluate()
    }

    /// Geometry, sizes and the player's own state, read again.
    private func refresh() {
        guard !invalidated else { return }
        updateGeometry()
        if let presented = presentationSize() { sourceSize = presented }
        reevaluate()
    }

    private func presentationSize() -> CGSize? {
        guard let size = player.currentItem?.presentationSize, size.width > 0, size.height > 0 else {
            return nil
        }
        return size
    }

    private var isSupported: Bool {
        device != nil && queue != nil && textureCache != nil && !pipelineFailed
    }

    private func reevaluate() {
        guard !invalidated else { return }
        var next = VideoEnhancementPolicy.verdict(
            conditions: conditions,
            isExternalPlaybackActive: player.isExternalPlaybackActive,
            detectedHDR: detectedHDR,
            source: sourceSize,
            output: picture.map { CGSize(width: $0.width, height: $0.height) },
            ceiling: governor.ceiling,
            isSupported: isSupported
        )
        // The output goes on as soon as the item is to be drawn — while the
        // pipelines may still be compiling, but before the item plays.
        if next.isActive { attachOutputIfNeeded() }
        // Pipelines still compiling: the native layer until they are there.
        if next.isActive, pipeline == nil { next = .native(.waitingForVideo) }
        let wasActive = verdict.isActive
        verdict = next
        switch next {
        case .active:
            if !wasActive {
                governor.noteRestart()
                drops.reset()
                resetWindow(at: nil)
                hasDrawnSinceActivation = false
            }
        case .native(let reason):
            setLayerHidden(true)
            hasDrawnSinceActivation = false
            switch reason {
            case .off, .hdr, .droppedFrames, .unsupported:
                // Not coming back on this item: stop the conversion. The
                // one pipeline rebuild this costs is paid once, not per
                // fallback.
                attachments.detachOutput()
                scratch.release()
            default:
                break
            }
        }
        updateDisplayLink()
        publish()
    }

    private func publish() {
        let next = Status(
            verdict: verdict,
            sourceSize: sourceSize,
            outputSize: picture.map { CGSize(width: $0.width, height: $0.height) },
            droppedFrames: droppedOnItem,
            isDrawing: verdict.isActive && hasDrawnSinceActivation
        )
        guard next != status else { return }
        status = next
        onStatusChange?(next)
    }

    // MARK: Display link

    /// How often the link calls: every refresh while drawing, a slow look
    /// while there is nothing to draw but the picture's size or the
    /// source's can still change (rotation, a resize, the item becoming
    /// ready).
    private enum LinkPace: Equatable {
        case drawing
        case watching

        var range: CAFrameRateRange {
            switch self {
            case .drawing: return .default
            case .watching: return CAFrameRateRange(minimum: 4, maximum: 10, preferred: 10)
            }
        }
    }

    private func updateDisplayLink() {
        let wanted: LinkPace?
        switch verdict {
        case .active:
            wanted = .drawing
        case .native(.waitingForVideo), .native(.noUpscaleNeeded):
            wanted = .watching
        default:
            wanted = nil
        }
        guard let wanted, !invalidated else {
            displayLink?.invalidate()
            displayLink = nil
            linkPace = nil
            lastTick = nil
            lastPeriod = nil
            return
        }
        if displayLink == nil {
            #if os(macOS)
            guard let view = displayLinkView else { return }
            let link = view.displayLink(target: linkTarget, selector: #selector(DisplayLinkTarget.step(_:)))
            #else
            let link = CADisplayLink(target: linkTarget, selector: #selector(DisplayLinkTarget.step(_:)))
            #endif
            link.add(to: .main, forMode: .common)
            displayLink = link
            linkPace = nil
            lastTick = nil
            lastPeriod = nil
        }
        if linkPace != wanted {
            displayLink?.preferredFrameRateRange = wanted.range
            linkPace = wanted
            // The next interval is the new pace's, not a missed vsync.
            lastTick = nil
            lastPeriod = nil
        }
    }

    fileprivate func step(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        guard !invalidated else { return }
        // The interval the link itself announced, not `duration`: under a
        // preferred frame rate the callbacks come less often than the panel
        // refreshes, and that is not a missed vsync.
        if let lastTick, let lastPeriod { drops.noteTick(elapsed: timestamp - lastTick, period: lastPeriod) }
        lastTick = timestamp
        lastPeriod = targetTimestamp - timestamp

        let geometryChanged = updateGeometry()
        let presented = presentationSize() ?? conditions.sourceSizeHint
        if geometryChanged || presented != sourceSize {
            sourceSize = presented
            reevaluate()
        }
        guard case .active(let quality) = verdict else { return }
        drawFrame(hostTime: targetTimestamp, quality: quality)
        closeWindowIfDue(at: timestamp)
    }

    // MARK: Geometry

    /// Lays the renderer's layer over the player layer and finds the
    /// picture's rect in drawable pixels. Returns whether that rect changed.
    @discardableResult
    private func updateGeometry() -> Bool {
        guard let playerLayer else { return false }
        let bounds = playerLayer.bounds
        let scale = resolvedScale(for: playerLayer)
        if metalLayer.frame != bounds || metalLayer.contentsScale != scale {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.frame = bounds
            metalLayer.contentsScale = scale
            CATransaction.commit()
        }
        let drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if drawableSize.width >= 1, drawableSize.height >= 1, metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }

        var rect = playerLayer.videoRect
        if rect.width <= 0 || rect.height <= 0, let hint = conditions.sourceSizeHint {
            // AVPlayer has no video size before the item is ready, and the
            // output has to be on the item before then (see the type's
            // comment). The host's hint, framed the way the layer will
            // frame it, stands in until the real rect exists.
            rect = Self.estimatedVideoRect(for: hint, in: bounds, gravity: playerLayer.videoGravity)
        }
        var next: VideoEnhancementPixelRect?
        if rect.width > 0, rect.height > 0 {
            #if os(macOS)
            // An unflipped layer measures from the bottom; the drawable's
            // rows run from the top.
            let top = playerLayer.isGeometryFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
            #else
            let top = rect.minY - bounds.minY
            #endif
            next = VideoEnhancementPixelRect(
                x: Int(((rect.minX - bounds.minX) * scale).rounded()),
                y: Int((top * scale).rounded()),
                width: Int((rect.width * scale).rounded()),
                height: Int((rect.height * scale).rounded())
            )
        }
        guard next != picture else { return false }
        picture = next
        return true
    }

    nonisolated static func estimatedVideoRect(
        for source: CGSize, in bounds: CGRect, gravity: AVLayerVideoGravity
    ) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        switch gravity {
        case .resize:
            return bounds
        case .resizeAspectFill:
            let scale = max(bounds.width / source.width, bounds.height / source.height)
            let size = CGSize(width: source.width * scale, height: source.height * scale)
            return CGRect(
                x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                width: size.width, height: size.height
            )
        default:
            return AVMakeRect(aspectRatio: source, insideRect: bounds)
        }
    }

    private func resolvedScale(for playerLayer: AVPlayerLayer) -> CGFloat {
        if let contentsScale, contentsScale > 0 { return contentsScale }
        #if os(macOS)
        if let backing = displayLinkView?.window?.backingScaleFactor, backing > 0 { return backing }
        #else
        // Not the layer's `contentsScale`, nor the view's trait: on tvOS
        // both read 1.0 while a 4K panel renders at 2.0, and a drawable that
        // size would make every 1080p film look like no upscale to do — and
        // be stretched by the compositor instead. The screen knows.
        if let view = playerLayer.delegate as? UIView,
           let screen = view.window?.windowScene?.screen, screen.nativeScale > 0 {
            return screen.nativeScale
        }
        #endif
        return max(playerLayer.contentsScale, 1)
    }

    private func setLayerHidden(_ hidden: Bool) {
        guard metalLayer.isHidden != hidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.isHidden = hidden
        CATransaction.commit()
    }

    // MARK: Output

    private func attachOutputIfNeeded() {
        guard let item = player.currentItem, attachments.item !== item else { return }
        attachments.detachOutput()
        if !item.outputs.contains(where: { $0 === output }) { item.add(output) }
        attachments.item = item
    }

    // MARK: Drawing

    private func drawFrame(hostTime: CFTimeInterval, quality: VideoEnhancementQuality) {
        guard let pipeline, let queue, let textureCache, let picture,
              let item = player.currentItem, attachments.item === item
        else { return }
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var shownTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shownTime) else {
            return
        }
        if Self.carriesHDR(buffer) {
            detectedHDR = true
            reevaluate()
            return
        }

        let isPlaying = player.rate != 0
        let time = shownTime.isValid ? shownTime.seconds : itemTime.seconds
        let lost = drops.noteFrame(itemTime: time, frameDuration: frameDuration, isPlaying: isPlaying)
        if lost > 0 { countDropped(lost) }

        // The GPU is still on the frames before: skip this one rather than
        // queue it, which would only make every later frame later too.
        guard inFlight.count < Self.maximumFramesInFlight else {
            if isPlaying { countDropped(1) }
            return
        }
        guard let source = Self.texture(from: buffer, cache: textureCache),
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer()
        else { return }
        commandBuffer.label = "Enhancement frame"

        #if os(iOS) || os(macOS)
        if !appliedColorSpace {
            // The frames are in the video's colour space; tagging the layer
            // with it lets the system match it to the panel the way it does
            // for the player layer, so switching between the two does not
            // shift the colour. (tvOS composites untagged layers in the
            // output's own space, which for an SDR source is Rec. 709 — the
            // same thing.)
            if let bufferAttachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
               let space = CVImageBufferCreateColorSpaceFromAttachments(bufferAttachments)?.takeRetainedValue() {
                metalLayer.colorspace = space
            }
            appliedColorSpace = true
        }
        #endif

        let scale = VideoEnhancementPolicy.scale(
            source: CGSize(width: Int(source.size.x), height: Int(source.size.y)),
            output: CGSize(width: picture.width, height: picture.height)
        ) ?? 1
        let encoded = pipeline.encode(
            into: commandBuffer,
            source: source.frame,
            target: drawable.texture,
            picture: picture,
            quality: quality,
            sharpening: VideoEnhancementPolicy.sharpening(forScale: scale),
            scratch: scratch
        )
        guard encoded else { return }
        commandBuffer.present(drawable)
        inFlight.begin()
        Self.release(source.keepAlive, inFlight: inFlight, when: commandBuffer)
        commandBuffer.commit()

        if isPlaying { windowPresented += 1 }
        if !hasDrawnSinceActivation {
            hasDrawnSinceActivation = true
            setLayerHidden(false)
            publish()
        }
    }

    private func countDropped(_ frames: Int) {
        windowDropped += frames
        droppedOnItem += frames
    }

    private func resetWindow(at time: CFTimeInterval?) {
        windowStart = time
        windowPresented = 0
        windowDropped = 0
    }

    private func closeWindowIfDue(at now: CFTimeInterval) {
        guard let start = windowStart else {
            windowStart = now
            return
        }
        guard now - start >= VideoEnhancementGovernor.windowSeconds else { return }
        let presented = windowPresented
        let dropped = windowDropped
        resetWindow(at: now)
        frameDuration = currentFrameDuration()
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        guard presented + dropped >= Self.minimumFramesPerWindow else {
            publish()
            return
        }
        if governor.record(presented: presented, dropped: dropped) {
            reevaluate()
        } else {
            publish()
        }
    }

    private func currentFrameDuration() -> Double? {
        guard let track = player.currentItem?.tracks.first(where: { $0.assetTrack?.mediaType == .video }),
              track.currentVideoFrameRate > 0
        else { return nil }
        return 1 / Double(track.currentVideoFrameRate)
    }

    // MARK: Frame helpers (no actor state)

    private struct SourceTexture {
        var frame: VideoEnhancementPipeline.Source
        var keepAlive: FrameKeepAlive
        var size: SIMD2<Int32> { frame.size }
    }

    private nonisolated static func texture(
        from buffer: CVPixelBuffer, cache: CVMetalTextureCache
    ) -> SourceTexture? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let made = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard made == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        // The clean aperture: a coded 1088-line buffer pictures 1080.
        let clean = CVImageBufferGetCleanRect(buffer).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let region = clean.isNull || clean.isEmpty ? CGRect(x: 0, y: 0, width: width, height: height) : clean
        return SourceTexture(
            frame: .init(
                texture: texture,
                origin: SIMD2(Int32(region.minX), Int32(region.minY)),
                size: SIMD2(Int32(region.width), Int32(region.height))
            ),
            keepAlive: FrameKeepAlive(texture: cvTexture, buffer: buffer)
        )
    }

    /// PQ or HLG on the frame itself.
    nonisolated static func carriesHDR(_ buffer: CVPixelBuffer) -> Bool {
        guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil),
              let transfer = value as? String
        else { return false }
        return transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    /// Written outside the actor: Metal calls the handler on its own thread.
    private nonisolated static func release(
        _ keepAlive: FrameKeepAlive, inFlight: InFlightFrames, when commandBuffer: any MTLCommandBuffer
    ) {
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(keepAlive) {}
            inFlight.end()
        }
    }
}

// MARK: - Helpers

/// What must outlive the GPU's read of a frame: the Metal texture wrapping
/// the pixel buffer, and the buffer itself.
///
/// Safety (`@unchecked Sendable`): never read after init — it only exists to
/// be released on Metal's completion thread.
private final class FrameKeepAlive: @unchecked Sendable {
    let texture: CVMetalTexture
    let buffer: CVPixelBuffer

    init(texture: CVMetalTexture, buffer: CVPixelBuffer) {
        self.texture = texture
        self.buffer = buffer
    }
}

/// Frames committed to the GPU and not yet completed.
///
/// Safety (`@unchecked Sendable`): `value` is only touched under `lock`.
private final class InFlightFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func begin() { lock.withLock { value += 1 } }
    func end() { lock.withLock { value = max(0, value - 1) } }
}

/// The renderer's footprint on the host's objects — its layer and its
/// output — kept apart from the renderer so `deinit` can take it down.
///
/// Safety (`@unchecked Sendable`): touched only on the main thread — by the
/// renderer (main actor) and by its `deinit`'s hop to the main queue.
private final class Attachments: @unchecked Sendable {
    let layer = CAMetalLayer()
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    weak var item: AVPlayerItem?

    func detachOutput() {
        if let item, item.outputs.contains(where: { $0 === output }) { item.remove(output) }
        item = nil
    }

    func tearDown() {
        detachOutput()
        layer.removeFromSuperlayer()
    }
}

/// The display link's target. A separate object because the link retains
/// its target: holding the renderer weakly lets it go away, and a link whose
/// renderer has gone stops itself.
private final class DisplayLinkTarget: NSObject {
    weak var renderer: VideoEnhancementRenderer?

    @objc func step(_ link: CADisplayLink) {
        guard let renderer else {
            link.invalidate()
            return
        }
        let timestamp = link.timestamp
        let target = link.targetTimestamp
        // The link is added to the main run loop (`updateDisplayLink`), so
        // this is the main thread by construction.
        MainActor.assumeIsolated {
            renderer.step(timestamp: timestamp, targetTimestamp: target)
        }
    }
}
#endif
