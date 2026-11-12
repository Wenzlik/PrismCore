import CoreGraphics

/// What the host asked for: the user's Auto / On / Off.
///
/// The engine owns what the three mean (`VideoEnhancementPolicy`), so every
/// host that offers the choice gets the same thresholds; the host owns which
/// one is the default and when it is forced off (a device too slow to spend
/// the GPU on it, say).
public enum VideoEnhancementMode: String, Sendable, CaseIterable {
    /// Upscale only where it is worth it: a real upscale, on a device that is
    /// not hot or saving power.
    case automatic
    /// Upscale whenever the picture is drawn larger than the source at all.
    case on
    /// Never: the host's `AVPlayerLayer` draws every frame.
    case off
}

/// How hard the renderer works on each frame.
///
/// Ordered: the governor steps *down* this list when frames are dropped and
/// past its bottom to the native layer.
public enum VideoEnhancementQuality: Int, Sendable, Comparable, CaseIterable {
    /// Separable Lanczos-2 with anti-ringing, nothing more.
    case lanczos = 0
    /// Lanczos-2, then the contrast-adaptive sharpening pass.
    case lanczosSharpened = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why the host's own layer is drawing the picture instead of the renderer.
public enum VideoEnhancementFallback: String, Sendable, Equatable, CaseIterable {
    /// The mode is `.off`.
    case off
    /// PQ or HLG — declared by the host or found on a frame. The renderer
    /// works in 8-bit SDR; an HDR picture through it would lose exactly what
    /// makes it HDR.
    case hdr
    /// Picture in Picture shows the player layer, not ours.
    case pictureInPicture
    /// AirPlay video: the frames are on another screen.
    case externalPlayback
    /// AVFoundation is drawing subtitles into the player layer, which the
    /// renderer's layer would cover.
    case nativeSubtitles
    /// The picture is not drawn larger than the source (or, under
    /// `.automatic`, not enough larger to be worth the GPU).
    case noUpscaleNeeded
    /// Thermal pressure or Low Power Mode, as the host reports it.
    case powerConstrained
    /// The renderer dropped frames at its lowest quality: the native layer
    /// for the rest of this item.
    case droppedFrames
    /// No video size or no on-screen rect yet.
    case waitingForVideo
    /// No Metal device, or the shaders did not build.
    case unsupported
}

/// The policy's answer.
public enum VideoEnhancementVerdict: Sendable, Equatable {
    case active(VideoEnhancementQuality)
    case native(VideoEnhancementFallback)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

/// What the host knows that the renderer cannot see for itself.
public struct VideoEnhancementConditions: Sendable, Equatable {
    public var mode: VideoEnhancementMode
    /// The playing source's range, from the probe. `nil` = not known: the
    /// renderer then checks the first frame's transfer function before it
    /// shows anything.
    public var dynamicRange: DynamicRange?
    public var isPictureInPictureActive: Bool
    /// AVFoundation is rendering a legible track into the player layer. A
    /// host that draws its own captions above the video does not set this:
    /// those stay visible over the renderer's layer.
    public var showsNativeSubtitles: Bool
    /// Serious heat or Low Power Mode, in the host's reading.
    public var isPowerConstrained: Bool
    /// The source's displayed size in pixels (aspect applied), when the host
    /// knows it before AVPlayer does. Lets the renderer decide before the
    /// item plays — see `VideoEnhancementRenderer` on why that matters.
    public var sourceSizeHint: CGSize?

    public init(
        mode: VideoEnhancementMode = .off,
        dynamicRange: DynamicRange? = nil,
        isPictureInPictureActive: Bool = false,
        showsNativeSubtitles: Bool = false,
        isPowerConstrained: Bool = false,
        sourceSizeHint: CGSize? = nil
    ) {
        self.mode = mode
        self.dynamicRange = dynamicRange
        self.isPictureInPictureActive = isPictureInPictureActive
        self.showsNativeSubtitles = showsNativeSubtitles
        self.isPowerConstrained = isPowerConstrained
        self.sourceSizeHint = sourceSizeHint
    }
}

/// Decides, from facts alone, whether the renderer draws and how hard it
/// works. Pure, so every rule below is a test rather than a device run.
public enum VideoEnhancementPolicy {
    /// `.automatic` wants at least this much upscale. 720p → 1080p is 1.5,
    /// 1080p → 2160p is 2; a 1.1× stretch is not worth a GPU pass, and is
    /// where Lanczos and the layer's own filter are hardest to tell apart.
    public static let automaticMinimumScale: Double = 1.25
    /// `.on` still needs *some* upscale: a 4-tap Lanczos-2 downscales with
    /// aliasing, and the system's own downscale is the better picture there.
    public static let minimumScale: Double = 1.01

    /// The upscale factor of the picture: output pixels per source pixel on
    /// the tighter axis. `nil` until both sizes are real.
    public static func scale(source: CGSize?, output: CGSize?) -> Double? {
        guard let source, let output,
              source.width > 0, source.height > 0, output.width > 0, output.height > 0
        else { return nil }
        return Double(min(output.width / source.width, output.height / source.height))
    }

    /// - Parameters:
    ///   - conditions: the host's facts and the user's mode.
    ///   - isExternalPlaybackActive: AirPlay video, read off the player.
    ///   - detectedHDR: a frame carried a PQ or HLG transfer function.
    ///   - source: the displayed source size in pixels, or `nil`.
    ///   - output: the on-screen video rect in pixels, or `nil`.
    ///   - ceiling: the governor's ceiling; `nil` once it has given up.
    ///   - isSupported: a Metal device and built pipelines.
    public static func verdict(
        conditions: VideoEnhancementConditions,
        isExternalPlaybackActive: Bool = false,
        detectedHDR: Bool = false,
        source: CGSize?,
        output: CGSize?,
        ceiling: VideoEnhancementQuality?,
        isSupported: Bool = true
    ) -> VideoEnhancementVerdict {
        // The order is the order a reader of Playback Info would want the
        // reason in: the most fundamental one wins.
        if conditions.mode == .off { return .native(.off) }
        if !isSupported { return .native(.unsupported) }
        if detectedHDR || conditions.dynamicRange == .pq || conditions.dynamicRange == .hlg {
            return .native(.hdr)
        }
        if conditions.isPictureInPictureActive { return .native(.pictureInPicture) }
        if isExternalPlaybackActive { return .native(.externalPlayback) }
        if conditions.showsNativeSubtitles { return .native(.nativeSubtitles) }
        guard let ceiling else { return .native(.droppedFrames) }
        guard let scale = scale(source: source, output: output) else {
            return .native(.waitingForVideo)
        }
        let minimum = conditions.mode == .automatic ? automaticMinimumScale : minimumScale
        if scale < minimum { return .native(.noUpscaleNeeded) }
        // Never weaker than the host's own thermal protection, whichever the
        // mode: `.on` is a statement about the picture, not about the heat.
        if conditions.isPowerConstrained { return .native(.powerConstrained) }
        return .active(ceiling)
    }

    /// How strongly the sharpening pass works at a given upscale: gentle near
    /// 1×, where there is little softness to recover and the pass mostly
    /// shows grain, up to its cap from 2× (1080p on a 4K panel).
    public static func sharpening(forScale scale: Double) -> Float {
        let clamped = min(max(scale, 1), 2)
        return Float(0.2 + 0.4 * (clamped - 1))
    }
}
