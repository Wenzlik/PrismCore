import Testing
import Foundation
import Libavformat
import Libavcodec
import Libavutil
@testable import PrismCore

/// Standard-rate video served on its exact frame grid (`FrameGrid`), and the
/// exact rate handed to the display criteria (`StandardFrameRate`).
@Suite("Frame grid", .serialized)
struct FrameGridTests {

    private static let milliseconds = AVRational(num: 1, den: 1000)
    private static let ntsc24 = StandardFrameRate(24000, 1001)

    /// What a Matroska muxer writes for frame `n` at `rate`: the exact time
    /// rounded (mkvmerge) or truncated to the millisecond.
    private static func milliseconds(frame n: Int64, rate: StandardFrameRate, truncate: Bool = false) -> Int64 {
        let exact = Double(n) * Double(rate.denominator) * 1000 / Double(rate.numerator)
        return Int64(truncate ? exact.rounded(.down) : exact.rounded())
    }

    // MARK: - Rate detection

    @Test("Standard rates are told apart exactly, and ambiguity is left alone")
    func detection() {
        func rate(_ num: Int32, _ den: Int32) -> AVRational { AVRational(num: num, den: den) }
        let none = rate(0, 1)
        #expect(StandardFrameRate.detect(average: rate(24000, 1001), real: rate(24000, 1001)) == Self.ntsc24)
        #expect(StandardFrameRate.detect(average: rate(24, 1), real: rate(24, 1)) == StandardFrameRate(24, 1))
        // A Matroska DefaultDuration of 41708333 ns, as libavformat reduces it.
        #expect(StandardFrameRate.detect(average: rate(1_000_000_000 / 1000, 41_708_333 / 1000), real: none)
            == Self.ntsc24)
        #expect(StandardFrameRate.detect(average: rate(30000, 1001), real: none) == StandardFrameRate(30000, 1001))
        #expect(StandardFrameRate.detect(average: rate(60000, 1001), real: none) == StandardFrameRate(60000, 1001))
        // The average unset: r_frame_rate stands in.
        #expect(StandardFrameRate.detect(average: none, real: rate(25, 1)) == StandardFrameRate(25, 1))
        // r_frame_rate as libavformat's time-base fallback is no second opinion.
        #expect(StandardFrameRate.detect(average: rate(24, 1), real: rate(1000, 1)) == StandardFrameRate(24, 1))
        // VFR / non-standard: an average that is no standard rate.
        #expect(StandardFrameRate.detect(average: rate(2350, 100), real: rate(24000, 1001)) == nil)
        #expect(StandardFrameRate.detect(average: rate(15, 1), real: none) == nil)
        // Two standard rates disagreeing (telecine flags, field rates).
        #expect(StandardFrameRate.detect(average: rate(24000, 1001), real: rate(30000, 1001)) == nil)
        // A measured average (2 s of ms timestamps) never picks the grid…
        #expect(StandardFrameRate.detect(average: rate(2399, 100), real: none) == nil)
        // …but names the display rate, on the right side of the 24 / 23.976 gap.
        let display = StandardFrameRate.displayTolerance
        #expect(StandardFrameRate.detect(average: rate(2399, 100), real: none, tolerance: display)
            == StandardFrameRate(24, 1))
        #expect(StandardFrameRate.detect(average: rate(23977, 1000), real: none, tolerance: display) == Self.ntsc24)
        #expect(StandardFrameRate.detect(average: rate(23988, 1000), real: none, tolerance: display) == nil)
    }

    @Test("Every rate's frame is a whole number of ticks")
    func timescales() {
        for rate in StandardFrameRate.all {
            #expect(Int64(rate.timescale) * rate.denominator % rate.numerator == 0, "\(rate)")
        }
        func grid(_ rate: StandardFrameRate, _ den: Int32) -> FrameGrid? {
            FrameGrid(rate: rate, sourceTimeBase: AVRational(num: 1, den: den), startTime: 0)
        }
        #expect(grid(Self.ntsc24, 1000)?.outputTimeBase.den == 24000 && grid(Self.ntsc24, 1000)?.ticksPerFrame == 1001)
        #expect(grid(StandardFrameRate(60000, 1001), 1000)?.outputTimeBase.den == 60000)
        #expect(grid(StandardFrameRate(24, 1), 1000)?.outputTimeBase.den == 90_000)
        #expect(grid(StandardFrameRate(24, 1), 1000)?.ticksPerFrame == 3750)
        // A 90 kHz source keeps every one of its ticks whole: the timescale is
        // the least common multiple, not the rate's own.
        #expect(grid(Self.ntsc24, 90_000)?.outputTimeBase.den == 360_000 && grid(Self.ntsc24, 90_000)?.ticksPerFrame == 15015)
        #expect(grid(StandardFrameRate(30000, 1001), 90_000)?.outputTimeBase.den == 90_000)
        #expect(grid(StandardFrameRate(60000, 1001), 90_000)?.outputTimeBase.den == 180_000)
        #expect(grid(StandardFrameRate(24, 1), 90_000)?.outputTimeBase.den == 90_000)
        // A time base that would need a timescale past 32 bits gets no grid.
        #expect(grid(Self.ntsc24, 1_000_000_007) == nil)
    }

    // MARK: - Timestamp mapping

    @Test("41/42 ms steps land on the exact 1001-tick grid, with no drift over three hours")
    func ntscMillisecondsSnapWithoutDrift() {
        let grid = FrameGrid(rate: Self.ntsc24, sourceTimeBase: Self.milliseconds, startTime: 0)!
        // 3 h at 23.976: every frame, not a sample.
        for n in Int64(0)..<259_000 {
            let source = Self.milliseconds(frame: n, rate: Self.ntsc24)
            #expect(grid.timestamp(source) == n * 1001)
            if grid.timestamp(source) != n * 1001 { return }
        }
        // A muxer that truncates: the frames it rounded down by under half a
        // millisecond snap, the others keep their own time; none moves a tick.
        var last = Int64.min
        for n in Int64(0)..<10_000 {
            let source = Self.milliseconds(frame: n, rate: Self.ntsc24, truncate: true)
            let mapped = grid.timestamp(source)
            #expect(mapped > last && abs(mapped - source * 24) < 24, "frame \(n)")
            last = mapped
        }
        #expect(grid.duration(41) == 1001 && grid.duration(42) == 1001)
        #expect(grid.duration(83) == 2002)
    }

    @Test("24.000, 29.97 and 59.94 fps land on their grids")
    func otherRatesSnap() {
        for (rate, scale, step) in [
            (StandardFrameRate(24, 1), Int32(90_000), Int64(3750)),
            (StandardFrameRate(30000, 1001), 30000, 1001),
            (StandardFrameRate(60000, 1001), 60000, 1001),
            (StandardFrameRate(30, 1), 90_000, 3000),
        ] {
            let grid = FrameGrid(rate: rate, sourceTimeBase: Self.milliseconds, startTime: 0)!
            #expect(grid.outputTimeBase.den == scale)
            for n in Int64(0)..<20_000 {
                let source = Self.milliseconds(frame: n, rate: rate)
                #expect(grid.timestamp(source) == n * step, "\(rate) frame \(n)")
                if grid.timestamp(source) != n * step { break }
            }
        }
    }

    @Test("The grid is anchored on the stream's start, not on zero")
    func startOffset() {
        // A cut whose first frame sits 7 ms in: every frame is 7 ms off a
        // zero-based grid, which would snap none of them.
        let grid = FrameGrid(rate: Self.ntsc24, sourceTimeBase: Self.milliseconds, startTime: 7)!
        for n in Int64(0)..<10_000 {
            let source = 7 + Self.milliseconds(frame: n, rate: Self.ntsc24)
            #expect(grid.timestamp(source) == 168 + n * 1001)
            if grid.timestamp(source) != 168 + n * 1001 { break }
        }
    }

    @Test("Timestamps off the grid keep their own time, only rescaled")
    func offGridIsUntouched() {
        let grid = FrameGrid(rate: Self.ntsc24, sourceTimeBase: Self.milliseconds, startTime: 0)!
        // A variable-rate stretch: 20 ms steps, mostly far from any frame.
        var unchanged = 0
        for t in stride(from: Int64(0), to: 2000, by: 20) {
            let mapped = grid.timestamp(t)
            #expect(abs(mapped - t * 24) <= 24, "\(t) ms → \(mapped)")
            if mapped == t * 24 { unchanged += 1 }
        }
        #expect(unchanged > 50)
        #expect(grid.timestamp(swift_AV_NOPTS_VALUE()) == swift_AV_NOPTS_VALUE())
        #expect(grid.duration(0) == 0)
        #expect(grid.duration(20) == 480)
    }

    @Test("Distinct timestamps never share a tick, whatever the rate claims")
    func injective() {
        // A variable-rate stretch in a stream labelled 25 fps: 39 and 40 ms are
        // both within a tick of frame 1, and must stay 1 ms apart.
        let pal = FrameGrid(rate: StandardFrameRate(25, 1), sourceTimeBase: Self.milliseconds, startTime: 0)!
        #expect(pal.timestamp(39) == 3510 && pal.timestamp(40) == 3600 && pal.timestamp(41) == 3690)
        for (timeBase, span) in [(Self.milliseconds, Int64(20_000)), (AVRational(num: 1, den: 90_000), 200_000)] {
            for rate in StandardFrameRate.all {
                let grid = FrameGrid(rate: rate, sourceTimeBase: timeBase, startTime: 0)!
                var last = grid.timestamp(-1)
                for t in Int64(0)..<span {
                    let mapped = grid.timestamp(t)
                    #expect(mapped > last, "\(rate) at \(t) / \(timeBase.den)")
                    if mapped <= last { break }
                    last = mapped
                }
            }
        }
        // 90 kHz timestamps of 23.976 fps land on the grid; their neighbours do not.
        let ts = FrameGrid(rate: Self.ntsc24, sourceTimeBase: AVRational(num: 1, den: 90_000), startTime: 0)!
        #expect(ts.timestamp(3754) == 15015)
        #expect(ts.timestamp(3753) == 15012 && ts.timestamp(3755) == 15020)
    }

    @Test("B-frames: DTS stays monotonic and never passes its PTS")
    func bFrames() {
        let grid = FrameGrid(rate: Self.ntsc24, sourceTimeBase: Self.milliseconds, startTime: 0)!
        // Decode order I P B B B …, three B-frames: presentation index per
        // decode slot; DTS is the presentation time of the slot's rank, minus
        // the two-frame reorder delay this pyramid needs (what libavformat
        // derives for Matroska).
        let order: [Int64] = [0, 4, 2, 1, 3, 8, 6, 5, 7, 12, 10, 9, 11]
        var lastDTS = Int64.min
        for (slot, frame) in order.enumerated() {
            let pts = grid.timestamp(Self.milliseconds(frame: frame + 1000, rate: Self.ntsc24))
            let dts = grid.timestamp(Self.milliseconds(frame: Int64(slot) + 1000 - 2, rate: Self.ntsc24))
            #expect(pts == (frame + 1000) * 1001)
            #expect(dts > lastDTS && dts <= pts, "slot \(slot): dts \(dts) pts \(pts)")
            lastDTS = dts
        }
        // Negative times (a B-frame stream's first DTS) map on the same grid.
        #expect(grid.timestamp(-42) == -1001)
        #expect(grid.timestamp(-83) == -2002)
    }

    // MARK: - Served media

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("A 23.976 fps Matroska is served at timescale 24000, every frame 1001 ticks, segments verified")
    func servedOnTheGrid() async throws {
        let url = try fixture("grid_23976_bframes.mkv")
        let probe = try SourceProbe.probe(url: url)
        let rate = try #require(probe.video?.frameRate)
        #expect(rate == 24000.0 / 1001)
        let choice = DisplayCriteriaChoice.forSource(
            dynamicRange: .sdr, declaredDolbyVision: nil,
            display: DisplayCapabilities(isHDRReady: false, isDolbyVisionCapable: false), frameRate: rate
        )
        #expect(choice.refreshRate == Float(24000.0 / 1001))

        let session = try PrismCoreSession(url: url)
        let master = try await session.start()
        defer { Task { await session.stop() } }
        let base = master.deletingLastPathComponent()
        func fetch(_ path: String) async throws -> Data {
            let (data, response) = try await URLSession.uncached.data(from: base.appendingPathComponent(path))
            try #require((response as? HTTPURLResponse)?.statusCode == 200, "\(path)")
            return data
        }
        let variant = String(decoding: try await fetch("index.m3u8"), as: UTF8.self)
        let files = variant.split(separator: "\n").filter { $0.hasSuffix(".m4s") }.map(String.init)
        try #require(files.count >= 3, "\(variant)")
        var whole = try await fetch("init.mp4")
        for file in files { whole += try await fetch(file) }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreFrameGrid-\(UUID().uuidString).mp4")
        try whole.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, file.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let videoIndex = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        try #require(videoIndex >= 0)
        let stream = try #require(context.pointee.streams[Int(videoIndex)])
        #expect(stream.pointee.time_base.num == 1 && stream.pointee.time_base.den == 24000)

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var presentation: [Int64] = []
        var lastDTS = Int64.min
        while av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == videoIndex else { continue }
            #expect(pkt.pointee.dts > lastDTS && pkt.pointee.dts <= pkt.pointee.pts)
            lastDTS = pkt.pointee.dts
            presentation.append(pkt.pointee.pts)
        }
        presentation.sort()
        #expect(presentation.count == 287 || presentation.count == 288)
        let steps = Set(zip(presentation, presentation.dropFirst()).map { $1 - $0 })
        #expect(steps == [1001], "frame lengths \(steps)")

        // Every served segment opens on a keyframe and decodes whole.
        let report = try await SegmentVerifier.verify(playlist: master, stallTimeout: .seconds(30))
        #expect(report.findings.isEmpty, "\(report)")
    }
}
