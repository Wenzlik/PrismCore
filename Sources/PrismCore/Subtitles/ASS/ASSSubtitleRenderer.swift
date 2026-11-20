import Foundation
import CoreGraphics
import Libass

/// How a session (or the software pipeline) treats ASS/SSA tracks.
public enum ASSRenderingMode: Sendable, Equatable {
    /// Today's behaviour, and the default: ASS events become text cues
    /// (`TimedTextCue.text`, plus `styled` runs and placement) that the host
    /// draws in its own style. No libass work at all.
    case text
    /// Additionally keep every ASS/SSA track in a libass renderer, with the
    /// container's font attachments loaded, so the host can draw the file's
    /// own typesetting — `assRenderer(streamIndex:)`. Text cues keep flowing
    /// (the WebVTT renditions for PiP/AirPlay need them anyway).
    case libass
}

/// A font handed to libass from memory: a Matroska attachment, a `[Fonts]`
/// section the host extracted, a bundled typeface.
public struct SubtitleFont: Sendable, Equatable {
    /// The attachment's file name; libass only uses it in log messages —
    /// faces are matched by the family names inside the font data.
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Edge insets in canvas pixels.
public struct SubtitleInsets: Sendable, Equatable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = SubtitleInsets()
}

/// The surface a libass frame is rendered for — the host's overlay, in
/// **pixels** (points × scale), origin top-left.
public struct SubtitleCanvas: Sendable, Equatable {
    /// Overlay size in pixels. Clamped to `ASSSubtitleRenderer.maximumCanvasSide`.
    public var width: Int
    public var height: Int
    /// Where the picture is drawn inside the overlay (letterbox / pillarbox
    /// bands outside it). `nil` = the whole canvas.
    public var videoRect: CGRect?
    /// Title-safe / control-safe area. ASS coordinates map onto the part of
    /// the picture inside it, so a full-screen picture on a TV keeps its
    /// typesetting off the overscanned edge — the whole script is scaled in
    /// proportionally, signs included, rather than lines being shoved about.
    public var safeAreaInsets: SubtitleInsets
    /// Let unpositioned dialogue use the letterbox bands
    /// (`ass_set_use_margins`). Off by default: the file's layout wins.
    public var placesDialogueInBlackBars: Bool

    public init(
        width: Int, height: Int, videoRect: CGRect? = nil,
        safeAreaInsets: SubtitleInsets = .zero, placesDialogueInBlackBars: Bool = false
    ) {
        self.width = width
        self.height = height
        self.videoRect = videoRect
        self.safeAreaInsets = safeAreaInsets
        self.placesDialogueInBlackBars = placesDialogueInBlackBars
    }
}

/// One composited region of a rendered frame: premultiplied BGRA
/// (`CGImageAlphaInfo.premultipliedFirst`, 32-bit little-endian, sRGB), to be
/// drawn at `frame` (canvas pixels, origin top-left) — e.g. as a
/// `CALayer.contents` at that frame.
///
/// The same shape a decoded bitmap track (PGS/VobSub) will take, so a host
/// overlay has one image path for both.
public struct SubtitleImage: @unchecked Sendable {
    // Safety: CGImage is immutable once created.
    public let image: CGImage
    public let frame: CGRect
}

/// Everything visible at one instant.
public struct ASSFrame: @unchecked Sendable {
    // Safety: only immutable values (see SubtitleImage).
    /// The time asked for (cue timeline, seconds).
    public let time: Double
    public let canvas: SubtitleCanvas
    /// Back to front. Empty = nothing on screen (clear the overlay).
    public let images: [SubtitleImage]
}

public enum ASSFrameUpdate: @unchecked Sendable {
    // Safety: see ASSFrame.
    /// Identical to the previous frame for this canvas — keep showing it.
    /// libass's own change detection; nothing was composited.
    case unchanged
    case frame(ASSFrame)
}

/// How much of the file's styling libass may replace.
public enum ASSStyleOverride: Sendable, Equatable {
    /// The file's styles untouched — `ASS_OVERRIDE_DEFAULT`. "File styles ON".
    case none
    /// Scale every font by `scale` (the viewer's size setting) and, when
    /// given, replace the font family — styles only; inline `\fs`/`\fn`
    /// overrides in the events still apply, as in every libass player.
    case font(name: String? = nil, scale: Double = 1)
}

/// libass for one ASS/SSA track: events in, composited bitmaps out.
///
/// ## Timeline
/// `frame(at:)` takes a time on the **same clock as `TimedTextCue`** for the
/// path that produced the renderer — the remux session's played timeline
/// (`AVPlayerItem.currentTime()`), the software pipeline's source axis — and
/// does NOT apply `setSubtitleDelaySeconds`: the host passes
/// `playerTime - subtitleDelay`. That keeps one delay knob, the host's, for
/// every subtitle type and engine.
///
/// ## Seeks
/// Every event ever fed stays in the libass track (text, small), and
/// `ass_process_chunk` drops a re-fed Matroska event by its ReadOrder. So a
/// seek needs nothing at all: the demux re-reads a region, duplicates are
/// ignored, and `ass_render_frame` picks the events covering whatever time
/// is asked for — backwards included. This mirrors `SubtitleCueHistory
/// .complete`; a feed with no ReadOrder (`appendEvent` from a host) can call
/// `removeAllEvents()` on its own seek.
///
/// ## Threading
/// libass is not thread-safe, and renderers of one session share one
/// `ASS_Library` (so a 40 MB font set is loaded once, not per track). Every
/// libass call goes through that library's lock: the producer's feed and
/// the host's render serialize there. A render is milliseconds; call
/// `frame(at:canvas:)` from any one thread — the main thread or a display
/// link is fine — at most once per displayed frame.
// Safety: all mutable state and every libass handle is touched only under `library.lock`.
public final class ASSSubtitleRenderer: @unchecked Sendable {

    /// Canvas sides above this are refused (a 4K overlay is the ceiling a
    /// host has a use for; past it a composite is pure memory risk).
    public static let maximumCanvasSide = 4_096

    /// Whether libass is linked into this build — always true while MPVKit
    /// ships it; kept so a host can gate its "file styles" UI on a fact.
    public static var isAvailable: Bool { ass_library_version() > 0 }

    let library: LibassLibrary
    private let track: UnsafeMutablePointer<ASS_Track>
    private var renderer: OpaquePointer?
    private var configuredCanvas: SubtitleCanvas?
    private var appliedOverride: ASSStyleOverride?
    private var styleOverride: ASSStyleOverride = .none
    private var hasFrame = false
    /// Source size of the video stream (anamorphic storage), for libass's
    /// pixel aspect and blur scale. `nil` = assume square pixels.
    private let storageSize: (width: Int, height: Int)?
    /// Seconds added to every `frame(at:)` time: the remux session's
    /// presentation origin, since events are fed on the source axis.
    private var timelineOrigin: Double = 0
    private var compositor = ASSCompositor()

    /// An external `.ass`/`.ssa` file, whole (`ass_read_memory`). `[Fonts]`
    /// embedded in the script are extracted too.
    public convenience init(script: Data, fonts: [SubtitleFont] = [], videoSize: CGSize? = nil) throws {
        let library = try LibassLibrary(fonts: fonts)
        // A mutable, NUL-terminated copy: libass tokenizes the buffer in place.
        var bytes = [CChar](repeating: 0, count: script.count + 1)
        bytes.withUnsafeMutableBytes { _ = script.copyBytes(to: $0.bindMemory(to: UInt8.self), count: script.count) }
        let track = library.withLock {
            bytes.withUnsafeMutableBufferPointer { ass_read_memory(library.handle, $0.baseAddress, script.count, nil) }
        }
        guard let track else { throw ASSRendererError.unreadableScript }
        self.init(library: library, track: track, storageSize: Self.storage(videoSize))
    }

    /// An event stream: the script header (a Matroska ASS track's
    /// CodecPrivate) now, events later through `appendEvent`.
    public convenience init(header: Data, fonts: [SubtitleFont] = [], videoSize: CGSize? = nil) throws {
        try self.init(header: header, library: LibassLibrary(fonts: fonts), storageSize: Self.storage(videoSize))
    }

    convenience init(header: Data?, library: LibassLibrary, storageSize: (width: Int, height: Int)?) throws {
        guard let track = library.withLock({ ass_new_track(library.handle) }) else {
            throw ASSRendererError.allocationFailed
        }
        if let header, !header.isEmpty {
            library.withLock {
                header.withUnsafeBytes { raw in
                    ass_process_codec_private(
                        track, raw.bindMemory(to: CChar.self).baseAddress, Int32(clamping: raw.count)
                    )
                }
            }
        }
        self.init(library: library, track: track, storageSize: storageSize)
    }

    private init(library: LibassLibrary, track: UnsafeMutablePointer<ASS_Track>, storageSize: (width: Int, height: Int)?) {
        self.library = library
        self.track = track
        self.storageSize = storageSize
    }

    deinit {
        library.withLock {
            if let renderer { ass_renderer_done(renderer) }
            ass_free_track(track)
        }
    }

    private static func storage(_ size: CGSize?) -> (width: Int, height: Int)? {
        guard let size, size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite else { return nil }
        return (Int(size.width), Int(size.height))
    }

    // MARK: Feeding

    /// One Matroska-style event (`ReadOrder,Layer,Style,Name,MarginL,
    /// MarginR,MarginV,Effect,Text`) at `start` for `duration` seconds, on
    /// the source axis. A ReadOrder already seen is ignored — that is the
    /// seek story (see the type doc).
    public func appendEvent(_ chunk: Data, start: Double, duration: Double) {
        guard start.isFinite, duration.isFinite, duration > 0, !chunk.isEmpty,
              abs(start) < 1e9, duration < 1e9 else { return }
        let startMS = Int64((start * 1000).rounded())
        let durationMS = Int64((duration * 1000).rounded())
        library.withLock {
            chunk.withUnsafeBytes { raw in
                ass_process_chunk(track, raw.bindMemory(to: CChar.self).baseAddress,
                                  Int32(clamping: raw.count), startMS, durationMS)
            }
        }
    }

    /// Drop every event (styles stay) — for a host-fed stream whose events
    /// carry no usable ReadOrder and which re-feeds after a seek.
    public func removeAllEvents() {
        library.withLock {
            ass_flush_events(track)
            hasFrame = false
        }
    }

    /// Events held right now.
    public var eventCount: Int { library.withLock { Int(track.pointee.n_events) } }

    /// See `ASSStyleOverride`; applies from the next `frame(at:canvas:)`.
    public func setStyleOverride(_ override: ASSStyleOverride) {
        library.withLock { styleOverride = override }
    }

    func setTimelineOrigin(_ seconds: Double) {
        library.withLock {
            timelineOrigin = seconds.isFinite ? seconds : 0
            hasFrame = false
        }
    }

    // MARK: Rendering

    /// The subtitle picture at `time` (cue timeline, delay already applied
    /// by the host — see the type doc) for `canvas`.
    ///
    /// `.unchanged` when nothing moved since the previous call with the same
    /// canvas and override: libass's own change detection, so an idle
    /// stretch costs one `ass_render_frame` call and no compositing. A frame
    /// with no images means "clear". A canvas outside
    /// `1…maximumCanvasSide` or a non-finite time yields an empty frame.
    public func frame(at time: Double, canvas: SubtitleCanvas) -> ASSFrameUpdate {
        guard time.isFinite, abs(time) < 1e9,
              (1...Self.maximumCanvasSide).contains(canvas.width),
              (1...Self.maximumCanvasSide).contains(canvas.height)
        else { return .frame(ASSFrame(time: time, canvas: canvas, images: [])) }
        return library.withLock {
            guard let renderer = rendererLocked() else {
                return .frame(ASSFrame(time: time, canvas: canvas, images: []))
            }
            var forced = !hasFrame
            if configuredCanvas != canvas {
                configure(renderer, for: canvas)
                configuredCanvas = canvas
                forced = true
            }
            if appliedOverride != styleOverride {
                apply(styleOverride, to: renderer)
                appliedOverride = styleOverride
                forced = true
            }
            var changed: Int32 = 0
            let now = Int64(((time + timelineOrigin) * 1000).rounded())
            let images = ass_render_frame(renderer, track, now, &changed)
            guard changed != 0 || forced else { return .unchanged }
            hasFrame = true
            return .frame(ASSFrame(time: time, canvas: canvas,
                                   images: compositor.composite(images, canvasWidth: canvas.width, canvasHeight: canvas.height)))
        }
    }

    /// Built on first render, not with the track: the font provider costs a
    /// CoreText set-up, and a track nobody draws should cost only its text.
    private func rendererLocked() -> OpaquePointer? {
        if let renderer { return renderer }
        guard let created = ass_renderer_init(library.handle) else { return nil }
        // AUTODETECT resolves to CoreText on every Apple slice MPVKit ships
        // (no fontconfig there); a missing glyph — CJK in a Latin style —
        // falls back through CoreText's cascade list. The default family
        // must exist on tvOS too, which rules Arial out.
        ass_set_fonts(created, nil, LibassLibrary.defaultFamily, Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
        // Glyph count and a bitmap cache in MB: modest, an Apple TV is the
        // constrained device and the cache refills in a frame or two.
        ass_set_cache_limits(created, 1_000, 32)
        ass_set_hinting(created, ASS_HINTING_NONE)
        renderer = created
        return created
    }

    private func configure(_ renderer: OpaquePointer, for canvas: SubtitleCanvas) {
        let bounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let video = (canvas.videoRect ?? bounds).standardized
        let video0 = video.width >= 1 && video.height >= 1 ? video : bounds
        let insets = canvas.safeAreaInsets
        let safe = CGRect(x: insets.left, y: insets.top,
                          width: Double(canvas.width) - insets.left - insets.right,
                          height: Double(canvas.height) - insets.top - insets.bottom)
        var content = video0.intersection(safe)
        if content.isNull || content.width < 1 || content.height < 1 { content = video0 }
        ass_set_frame_size(renderer, Int32(canvas.width), Int32(canvas.height))
        ass_set_margins(renderer,
                        Int32(content.minY.rounded()), Int32((Double(canvas.height) - content.maxY).rounded()),
                        Int32(content.minX.rounded()), Int32((Double(canvas.width) - content.maxX).rounded()))
        ass_set_use_margins(renderer, canvas.placesDialogueInBlackBars ? 1 : 0)
        if let storageSize {
            ass_set_storage_size(renderer, Int32(storageSize.width), Int32(storageSize.height))
            // From the picture as displayed, not the safe-area content rect:
            // the inset may not keep the aspect exactly, and libass's own
            // default would read that sliver as anamorphic squeeze.
            let par = (video0.width / video0.height) / (Double(storageSize.width) / Double(storageSize.height))
            ass_set_pixel_aspect(renderer, par.isFinite && par > 0 ? par : 0)
        } else {
            ass_set_storage_size(renderer, Int32(content.width), Int32(content.height))
            ass_set_pixel_aspect(renderer, 1)
        }
    }

    private func apply(_ override: ASSStyleOverride, to renderer: OpaquePointer) {
        switch override {
        case .none:
            ass_set_selective_style_override_enabled(renderer, Int32(ASS_OVERRIDE_DEFAULT.rawValue))
            ass_set_font_scale(renderer, 1)
        case .font(let name, let scale):
            let scale = scale.isFinite ? min(4, max(0.25, scale)) : 1
            if let name, !name.isEmpty {
                // The override style is copied by libass at this call, so a
                // temporary C string is enough.
                var style = ASS_Style()
                name.withCString { pointer in
                    style.FontName = UnsafeMutablePointer(mutating: pointer)
                    ass_set_selective_style_override(renderer, &style)
                }
                ass_set_selective_style_override_enabled(
                    renderer, Int32(ASS_OVERRIDE_BIT_FONT_NAME.rawValue | ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue)
                )
            } else {
                ass_set_selective_style_override_enabled(
                    renderer, Int32(ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue)
                )
            }
            ass_set_font_scale(renderer, scale)
        }
    }
}

enum ASSRendererError: Error, Equatable {
    case allocationFailed
    case unreadableScript
}

/// One `ASS_Library` and the lock every libass call under it takes.
// Safety: `handle` is used only inside `withLock`.
final class LibassLibrary: @unchecked Sendable {
    static let defaultFamily = "Helvetica Neue"
    /// Past this one file is a broken or hostile attachment, not a typeface
    /// (a full CJK collection is ~30 MB).
    static let maximumFontBytes = 64 << 20
    /// What all fonts of one library may hold together. libass keeps its own
    /// copy of every font, and the cap was per file only: eight 40 MB
    /// attachments loaded 320 MB beside the decoder — jetsam on an Apple TV.
    /// Fonts past the budget are skipped (system faces stand in), in
    /// container order, so the first-declared — usually the dialogue face —
    /// win. A heavy anime release is 20–60 MB.
    static let maximumFontSetBytes = 96 << 20

    let handle: OpaquePointer
    private let lock = NSLock()
    private let fontBudget: Int
    /// Bytes handed to libass so far. Under `lock`.
    private var fontBytes = 0

    init(fonts: [SubtitleFont] = [], fontBudget: Int = LibassLibrary.maximumFontSetBytes) throws {
        guard let handle = ass_library_init() else { throw ASSRendererError.allocationFailed }
        self.handle = handle
        self.fontBudget = fontBudget
        // libass logs every font lookup to stderr by default; a TV app has
        // no stderr reader, and a busy script logs per frame.
        ass_set_message_cb(handle, { _, _, _, _ in }, nil)
        // `[Fonts]` sections inside a script (uuencoded) become memory fonts.
        ass_set_extract_fonts(handle, 1)
        for font in fonts { addFont(name: font.name, bytes: font.data) }
    }

    deinit { ass_library_done(handle) }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    /// libass copies the bytes, so the caller's buffer may go away after.
    /// `false` when the font was refused: empty, over the per-file cap, or
    /// over what is left of the library's budget.
    @discardableResult
    func addFont(name: String, bytes: Data) -> Bool {
        guard !bytes.isEmpty, bytes.count <= Self.maximumFontBytes else { return false }
        return withLock {
            guard bytes.count <= fontBudget - fontBytes else { return false }
            fontBytes += bytes.count
            bytes.withUnsafeBytes { raw in
                ass_add_font(handle, name, raw.bindMemory(to: CChar.self).baseAddress, Int32(raw.count))
            }
            return true
        }
    }

    /// Font bytes libass holds for this library.
    var loadedFontBytes: Int { withLock { fontBytes } }
}
