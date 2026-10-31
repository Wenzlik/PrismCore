import Testing
import Foundation
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

    @Test("never above four times the measured average")
    func capAtFourTimesAverage() {
        // A 40 Mbit/s segment, then four at 2.5: 10 Mbit/s over the 10 s, so
        // 48 declared is held to 4 × 10.
        let spike: [(position: Int64, seconds: Double)] = [
            (position: 0, seconds: 0), (position: 10_000_000, seconds: 2), (position: 10_625_000, seconds: 4),
            (position: 11_250_000, seconds: 6), (position: 11_875_000, seconds: 8), (position: 12_500_000, seconds: 10),
        ]
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: spike, average: 5_000_000, audioCeiling: 0)
            == 40_000_000)
    }

    @Test("the clamp measures its average from the boundaries, not the 25 Mbit/s stub")
    func clampIgnoresStubAverage() {
        // HTTP with no `bit_rate`: `sourceBandwidth` says 25 Mbit/s. A 120 Mbit/s
        // segment (80 average) declares 144; 4 × the stub would cut it to 100.
        let dense: [(position: Int64, seconds: Double)] = [
            (position: 0, seconds: 0), (position: 30_000_000, seconds: 2), (position: 40_000_000, seconds: 4),
        ]
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: dense, average: 25_000_000, audioCeiling: 0)
            == 144_000_000)
    }

    @Test("never below the average declared without the index")
    func neverBelowDeclaredAverage() {
        #expect(HLSRemuxer.peakSegmentBandwidth(boundaries: vbr, average: 30_000_000, audioCeiling: 0)
            == 30_000_000)
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
    }

    @Test("boundaries are the planned starts with a position; the rest merge into the segment before")
    func boundariesFromPlanAndPositions() {
        let plan = SegmentPlan(
            entries: [.init(startPTS: 0, duration: 2), .init(startPTS: 2000, duration: 2), .init(startPTS: 4000, duration: 2)],
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1000
        )
        let boundaries = HLSRemuxer.segmentBoundaries(plan: plan, positions: [0: 100, 4000: 900])
        #expect(boundaries.map { $0.position } == [100, 900])
        #expect(boundaries.map { $0.seconds } == [0, 4])
        #expect(HLSRemuxer.segmentBoundaries(plan: nil, positions: [0: 100]).isEmpty)
    }

    @Test("the keyframe cache keeps the positions, so a hit can still measure the peak")
    func cacheEntryKeepsPositions() throws {
        let entry = KeyframeIndexCache.Entry(
            identity: "id", timeBaseNum: 1, timeBaseDen: 1000, keyframePTS: [0, 2000, 4000],
            keyframePositions: [0: 100, 4000: 900]
        )
        #expect(entry.keyframePositions == [100, -1, 900])
        let decoded = try JSONDecoder().decode(KeyframeIndexCache.Entry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.positionsByPTS == [0: 100, 4000: 900])
        // A harvested entry carries none.
        #expect(KeyframeIndexCache.Entry(identity: "id", timeBaseNum: 1, timeBaseDen: 1000, keyframePTS: [0])
            .positionsByPTS.isEmpty)
    }
}
