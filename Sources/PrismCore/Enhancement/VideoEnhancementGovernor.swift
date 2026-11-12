/// Lowers the renderer's quality when it drops frames, and gives up on it
/// when even the cheapest level does.
///
/// A dropped frame is worse than a softer one: the whole point of the
/// renderer is a better picture, and judder is a worse picture than any
/// scaler. So the governor is quick to step down (one bad window) and slow
/// to step back up (`cleanWindowsToRecover` good ones, at most
/// `maximumRecoveries` times), and past its lowest level it hands the item
/// back to the native layer for good — there it can no longer measure what
/// the renderer costs, so it has nothing to come back on.
///
/// Fed one window at a time (`VideoEnhancementRenderer` closes one every
/// `windowSeconds` of playback). Pure, so its rules are tests.
public struct VideoEnhancementGovernor: Sendable, Equatable {
    /// Length of one measuring window, in seconds of playback.
    public static let windowSeconds: Double = 2
    /// A window is bad when more than this share of its frames dropped…
    public static let dropTolerance: Double = 0.02
    /// …and at least this many did: one late frame at a scene cut is noise.
    public static let minimumDrops = 2
    /// Clean windows before a step back up (30 s at the default window).
    public static let cleanWindowsToRecover = 15
    /// Step-ups per item. One: a device that needed a second step-down was
    /// not having a passing hiccup.
    public static let maximumRecoveries = 1

    /// The best quality the renderer may use now; `nil` once it has given up.
    public private(set) var ceiling: VideoEnhancementQuality?
    private let start: VideoEnhancementQuality
    private var cleanWindows = 0
    private var recoveries = 0
    /// Windows to ignore: the first one after a (re)start pays for pipeline
    /// warm-up and the first drawables, which is not what the device sustains.
    private var warmupWindows = 1

    public init(start: VideoEnhancementQuality = .lanczosSharpened) {
        self.start = start
        self.ceiling = start
    }

    /// A new item: full quality again, nothing remembered.
    public mutating func reset() {
        self = Self(start: start)
    }

    /// The renderer is starting to draw again after a pause in its work (a
    /// fallback that has ended): its next window is a warm-up again.
    public mutating func noteRestart() {
        warmupWindows = max(warmupWindows, 1)
    }

    /// One window's frames. Returns whether `ceiling` changed.
    @discardableResult
    public mutating func record(presented: Int, dropped: Int) -> Bool {
        let total = presented + dropped
        guard total > 0, ceiling != nil else { return false }
        if warmupWindows > 0 {
            warmupWindows -= 1
            return false
        }
        let struggling = dropped >= Self.minimumDrops
            && Double(dropped) / Double(total) > Self.dropTolerance
        if struggling {
            cleanWindows = 0
            ceiling = ceiling.flatMap { VideoEnhancementQuality(rawValue: $0.rawValue - 1) }
            // The cheaper level has its own warm-up.
            warmupWindows = 1
            return true
        }
        cleanWindows += 1
        if let current = ceiling, current < start,
           cleanWindows >= Self.cleanWindowsToRecover,
           recoveries < Self.maximumRecoveries,
           let better = VideoEnhancementQuality(rawValue: current.rawValue + 1) {
            ceiling = better
            recoveries += 1
            cleanWindows = 0
            warmupWindows = 1
            return true
        }
        return false
    }
}

/// Counts the frames a renderer failed to show, from the item times of the
/// frames it did show.
///
/// A gap between two shown frames is a drop only when the display link also
/// missed a vsync in between: with the display slower than the content
/// (60 fps on a 50 Hz panel) the gaps are the display's cadence, and nothing
/// the renderer could have shown was lost. A gap over a second, or a step
/// backwards, is a seek — never counted.
public struct VideoEnhancementDropCounter: Sendable, Equatable {
    private var lastItemTime: Double?
    private var missedVsync = false
    /// The shortest gap seen between two frames, as a frame duration when the
    /// track does not report its rate.
    private var shortestGap: Double?

    public init() {}

    /// A display-link callback `elapsed` seconds after the previous one, at a
    /// refresh period of `period`.
    public mutating func noteTick(elapsed: Double, period: Double) {
        if period > 0, elapsed > period * 1.5 { missedVsync = true }
    }

    /// A frame at `itemTime` was shown. `frameDuration` is the track's when
    /// known. Returns how many frames were lost before it.
    public mutating func noteFrame(itemTime: Double, frameDuration: Double?, isPlaying: Bool) -> Int {
        defer {
            lastItemTime = itemTime
            missedVsync = false
        }
        guard let last = lastItemTime else { return 0 }
        let gap = itemTime - last
        guard gap > 0, gap < 1 else { return 0 }
        if gap >= 1.0 / 240 { shortestGap = min(shortestGap ?? gap, gap) }
        guard isPlaying, missedVsync,
              let duration = frameDuration.flatMap({ $0 > 0 ? $0 : nil }) ?? shortestGap
        else { return 0 }
        return max(0, Int((gap / duration).rounded()) - 1)
    }

    /// The next frame starts a new run (a seek, a new item, a restart).
    public mutating func reset() {
        lastItemTime = nil
        missedVsync = false
    }
}
