import Foundation
import Libavformat
import Libavutil

/// One of the frame rates video is actually made at, as an exact rational.
///
/// Why rationals: 23.976 is 24000/1001, and 24 is 24. They differ by 0.1 %, which
/// a rounded float hides from nothing that counts frames — a 24 Hz panel playing
/// 23.976 drops a frame every 42 s, and a grid built on 23.976 for a 24 fps film
/// misses every frame.
struct StandardFrameRate: Sendable, Equatable {
    let numerator: Int64
    let denominator: Int64

    static let all: [StandardFrameRate] = [
        .init(24000, 1001), .init(24, 1), .init(25, 1), .init(30000, 1001),
        .init(30, 1), .init(50, 1), .init(60000, 1001), .init(60, 1),
    ]

    init(_ numerator: Int64, _ denominator: Int64) {
        self.numerator = numerator
        self.denominator = denominator
    }

    var value: Double { Double(numerator) / Double(denominator) }

    /// The track timescale in which one frame is a whole number of ticks:
    /// 24000/30000/60000 (1001 a frame) for the NTSC rates, and 90 kHz — what
    /// movenc gives an output video stream with no time base of its own, so
    /// these sources keep their timescale — for the integer ones.
    var timescale: Int32 { denominator == 1001 ? Int32(numerator) : 90_000 }

    var ticksPerFrame: Int64 { Int64(timescale) * denominator / numerator }

    /// Within this relative distance a measured rate is taken as the standard
    /// one for the frame grid: only container metadata is that exact (a
    /// Matroska DefaultDuration in nanoseconds is within 1e-8), while an
    /// average measured over a 2 s sample of millisecond timestamps can be
    /// 5e-4 out — half the 24 / 23.976 gap — and must not pick the grid.
    static let gridTolerance = 1e-4
    /// For the display: under half the 24 / 23.976 gap (1/1001 ≈ 1e-3), so a
    /// measured average still names one rate and never the wrong one.
    static let displayTolerance = 4.5e-4

    /// The standard rate within `tolerance` (relative) of `num/den`, if any.
    static func matching(num: Int32, den: Int32, tolerance: Double) -> StandardFrameRate? {
        guard num > 0, den > 0 else { return nil }
        let rate = Double(num) / Double(den)
        return all.first { abs(rate - $0.value) <= tolerance * $0.value }
    }

    /// The stream's standard rate, from `avg_frame_rate` (a Matroska track's
    /// DefaultDuration lands there) with `r_frame_rate` as the stand-in when the
    /// average is unset. `nil` for a non-standard or variable rate (an average
    /// that is no standard rate), and when the two name different standard
    /// rates (telecine flags, field rates): ambiguous is left alone. An
    /// `r_frame_rate` that is no standard rate at all is libavformat's
    /// time-base fallback (1000/1 for Matroska), not a second opinion.
    static func detect(
        average: AVRational, real: AVRational, tolerance: Double = gridTolerance
    ) -> StandardFrameRate? {
        let fromReal = matching(num: real.num, den: real.den, tolerance: gridTolerance)
        guard average.num > 0, average.den > 0 else { return fromReal }
        guard let fromAverage = matching(num: average.num, den: average.den, tolerance: tolerance)
        else { return nil }
        if let fromReal, fromReal != fromAverage { return nil }
        return fromAverage
    }
}

/// Maps a video stream's timestamps onto its frame grid.
///
/// Matroska stores milliseconds, so 23.976 fps arrives as 41/42/42 ms steps and
/// a 90 kHz track carries that jitter into the served media: no two frames the
/// same length, and a 3:2 cadence at 59.94 Hz that cannot be even. Here a
/// timestamp that is a frame of the stream's standard rate rounded to the source
/// tick — within half a tick of it, the window half open — becomes that
/// frame's exact time, in a timescale where every frame is a whole number of
/// ticks (`StandardFrameRate.timescale`); anything further off keeps its own
/// time, only rescaled. The window is under one tick wide on purpose: it holds
/// one source timestamp at most, so two distinct timestamps (a variable-rate
/// stretch 1 ms apart in a stream labelled 25 fps) never land on one tick. A
/// muxer that truncates instead of rounding leaves some of its frames off the
/// grid, each still within a tick of its own time.
///
/// A pure function of the timestamp, with the grid anchored on the stream's
/// `start_time`: every writer of a session — the head and each re-anchored
/// restart — maps a packet to the same tick, so timeline bases, edit lists and
/// a restart's alignment to the served init hold as before. Never further than
/// half a source tick from the source's own time, so audio (which keeps its own
/// timescale) cannot drift against it; segment cuts, the plan, the keyframe
/// cache and `#EXTINF` all stay on the source's ticks.
struct FrameGrid {
    let rate: StandardFrameRate
    let sourceTimeBase: AVRational
    let outputTimeBase: AVRational
    /// The grid's frame 0, in output ticks.
    let origin: Int64
    /// One source tick, in output ticks (at least one): the duration tolerance.
    let tolerance: Int64

    init(rate: StandardFrameRate, sourceTimeBase: AVRational, startTime: Int64?) {
        self.rate = rate
        self.sourceTimeBase = sourceTimeBase
        let output = AVRational(num: 1, den: rate.timescale)
        outputTimeBase = output
        origin = startTime.map { av_rescale_q($0, sourceTimeBase, output) } ?? 0
        tolerance = max(1, av_rescale_q(1, sourceTimeBase, output))
    }

    /// The grid for a stream, or `nil` when it has no confidently standard rate.
    init?(stream: UnsafeMutablePointer<AVStream>) {
        guard let rate = StandardFrameRate.detect(
            average: stream.pointee.avg_frame_rate, real: stream.pointee.r_frame_rate
        ), stream.pointee.time_base.num > 0, stream.pointee.time_base.den > 0
        else { return nil }
        let start = stream.pointee.start_time
        self.init(
            rate: rate, sourceTimeBase: stream.pointee.time_base,
            startTime: start == swift_AV_NOPTS_VALUE() ? nil : start
        )
    }

    /// A PTS or DTS, source ticks → output ticks.
    func timestamp(_ ticks: Int64) -> Int64 {
        guard ticks != swift_AV_NOPTS_VALUE() else { return ticks }
        let exact = av_rescale_q(ticks, sourceTimeBase, outputTimeBase)
        let step = rate.ticksPerFrame
        let frames = Self.floorDivide(exact - origin + step / 2, step)
        let snapped = origin + frames * step
        // −½ ≤ (snapped − exact) / one source tick < ½, in integers (a source tick is
        // timescale × num / den output ticks). Closed below because a muxer rounds a
        // frame that falls half-way between two ticks up (libavformat's rescale
        // does): its timestamp sits half a tick above the frame.
        let twice = 2 * (snapped - exact) * Int64(sourceTimeBase.den)
        let tick = Int64(rate.timescale) * Int64(sourceTimeBase.num)
        return twice >= -tick && twice < tick ? snapped : exact
    }

    /// A packet duration, source ticks → output ticks: whole frames when it is
    /// within a source tick of them (a duration is never compared with another,
    /// so this window may be wider), so a fragment's last sample (whose
    /// duration movenc takes from the packet) ends on the grid too.
    func duration(_ ticks: Int64) -> Int64 {
        guard ticks > 0 else { return ticks }
        let exact = av_rescale_q(ticks, sourceTimeBase, outputTimeBase)
        let step = rate.ticksPerFrame
        let snapped = (exact + step / 2) / step * step
        return snapped > 0 && abs(snapped - exact) <= tolerance ? snapped : exact
    }

    /// Rewrites a packet's timestamps from the source onto the grid (what
    /// `av_packet_rescale_ts` does for every other stream).
    func apply(to packet: UnsafeMutablePointer<AVPacket>) {
        packet.pointee.pts = timestamp(packet.pointee.pts)
        packet.pointee.dts = timestamp(packet.pointee.dts)
        packet.pointee.duration = duration(packet.pointee.duration)
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
}
