import Testing
@testable import PrismCore

/// `BANDWIDTH` from the densest planned segment: AVPlayer meets a VBR source's
/// dense segments above an average declaration and stalls or fails (-12318).
@Suite("Peak segment BANDWIDTH")
struct PeakSegmentBandwidthTests {

    /// 4, 12 and 4 Mbit/s segments of 2 s each.
    private let vbr: [(position: Int64, seconds: Double)] = [
        (position: 0, seconds: 0),
        (position: 1_000_000, seconds: 2),
        (position: 4_000_000, seconds: 4),
        (position: 5_000_000, seconds: 6),
    ]

    @Test("the densest segment, with 20 % headroom, sets BANDWIDTH")
    func densestSegmentWithHeadroom() {
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: vbr, average: 6_000_000, audioCeiling: 0)
            == 14_400_000)
    }

    @Test("a bridged rendition's encoder ceiling is added on top")
    func audioCeilingAdded() {
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: vbr, average: 6_000_000, audioCeiling: 768_000)
            == 15_168_000)
    }

    @Test("never below twice the average")
    func floorAtTwiceAverage() {
        let flat: [(position: Int64, seconds: Double)] = [
            (position: 0, seconds: 0), (position: 1_000_000, seconds: 2), (position: 2_000_000, seconds: 4),
        ]
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: flat, average: 4_000_000, audioCeiling: 0)
            == 8_000_000)
    }

    @Test("never above four times the average")
    func capAtFourTimesAverage() {
        // 40 Mbit/s peak → 48 declared, held to 4 × 5.
        let spike: [(position: Int64, seconds: Double)] = [
            (position: 0, seconds: 0), (position: 10_000_000, seconds: 2), (position: 11_000_000, seconds: 4),
        ]
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: spike, average: 5_000_000, audioCeiling: 0)
            == 20_000_000)
    }

    @Test("never above 160 Mbit/s")
    func capAt160Megabits() {
        // 200 Mbit/s peak on a 60 Mbit/s average: 4 × 60 would allow 240.
        let spike: [(position: Int64, seconds: Double)] = [
            (position: 0, seconds: 0), (position: 50_000_000, seconds: 2), (position: 60_000_000, seconds: 4),
        ]
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: spike, average: 60_000_000, audioCeiling: 0)
            == 160_000_000)
    }

    @Test("no usable index falls back to the average")
    func noIndexFallsBack() {
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: [], average: 6_000_000, audioCeiling: 0) == nil)
        // One whole segment is not a peak.
        #expect(HLSRemuxer.peakSegmentBandwidth(
            boundaries: Array(vbr.prefix(2)), average: 6_000_000, audioCeiling: 0
        ) == nil)
        // Positions running backwards: an index not to trust.
        let backwards: [(position: Int64, seconds: Double)] = [
            (position: 0, seconds: 0), (position: 3_000_000, seconds: 2), (position: 1_000_000, seconds: 4),
        ]
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: backwards, average: 6_000_000, audioCeiling: 0) == nil)
        // No average to clamp against.
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: vbr, average: 0, audioCeiling: 0) == nil)
    }
}
