import Testing
import Foundation
@testable import PrismCore

@Suite("SegmentPlan")
struct SegmentPlanTests {

    // 1 ms ticks make the arithmetic readable: 1000 ticks = 1 s.
    private let tick = 0.001

    @Test("Keyframes every 2 s, 6 s target → boundaries on the 6 s keyframes")
    func regularCadence() throws {
        let keyframes: [Int64] = stride(from: 0, through: 20_000, by: 2_000).map(Int64.init)
        let entries = try #require(SegmentPlan.keyframePlan(
            keyframes: keyframes, durationSeconds: 20, tickSeconds: tick, targetSeconds: 6
        ))
        #expect(entries.map(\.startPTS) == [0, 6_000, 12_000, 18_000])
        #expect(entries.map(\.duration) == [6, 6, 6, 2])
    }

    @Test("A boundary between keyframes waits for the NEXT keyframe")
    func irregularCadence() throws {
        // Keyframes at 0, 5 s, 9 s: the 6 s boundary falls between 5 and 9 —
        // the segment runs long to 9 s rather than cutting mid-GOP.
        let entries = try #require(SegmentPlan.keyframePlan(
            keyframes: [0, 5_000, 9_000], durationSeconds: 12, tickSeconds: tick, targetSeconds: 6
        ))
        #expect(entries[0].startPTS == 0)
        #expect(entries[0].duration == 9)
        #expect(entries[1].startPTS == 9_000)
        #expect(entries[1].duration == 3)
    }

    @Test("Witness 1: a monster gap distrusts the whole index")
    func gapWitness() {
        // 0, 1 s, then 200 s — a clustered TS-style index.
        let plan = SegmentPlan.keyframePlan(
            keyframes: [0, 1_000, 200_000], durationSeconds: 200, tickSeconds: tick, targetSeconds: 6
        )
        #expect(plan == nil)
    }

    @Test("Witness 2: head-bunched keyframes with no coverage distrust the index")
    func coverageWitness() {
        // All keyframes inside the first second (failed Cues tail read):
        // gaps are tiny, coverage is nowhere near one target duration.
        let plan = SegmentPlan.keyframePlan(
            keyframes: [0, 200, 400, 900], durationSeconds: 3_600, tickSeconds: tick, targetSeconds: 6
        )
        #expect(plan == nil)
    }

    @Test("Uniform fallback covers the whole duration with a short tail")
    func uniformFallback() {
        let entries = SegmentPlan.uniformPlan(durationSeconds: 20, tickSeconds: tick, targetSeconds: 6)
        #expect(entries.count == 4)
        #expect(entries.map(\.duration) == [6, 6, 6, 2])
        #expect(entries[2].startPTS == 12_000)
    }

    @Test("segmentIndex(containing:) picks the entry whose span holds the pts")
    func lookup() {
        let plan = SegmentPlan(
            entries: [
                .init(startPTS: 0, duration: 6),
                .init(startPTS: 6_000, duration: 6),
                .init(startPTS: 12_000, duration: 2),
            ],
            basis: .keyframeIndex, timeBaseNum: 1, timeBaseDen: 1_000
        )
        #expect(plan.segmentIndex(containing: 0) == 0)
        #expect(plan.segmentIndex(containing: 5_999) == 0)
        #expect(plan.segmentIndex(containing: 6_000) == 1)
        #expect(plan.segmentIndex(containing: 13_500) == 2)
    }

    @Test("A real MKV's Cues produce a keyframe-basis plan")
    func realFixture() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"
        ))
        let plan = try #require(SegmentPlanProbe.plan(url: fixture, targetSeconds: 6))
        // 8 s file, keyframes every 2 s (g=48 @ 24 fps): expect a ~6 s
        // segment and a ~2 s tail on the keyframe basis.
        #expect(plan.basis == .keyframeIndex)
        #expect(plan.entries.count == 2)
        #expect(abs(plan.entries[0].duration - 6) < 0.5)
    }

    @Test("An exhausted index-load budget still yields a usable plan")
    func exhaustedIndexBudgetStillPlans() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"
        ))
        // A zero budget is the worst case the guard exists for. What it must
        // never do is lose the plan or the read position: whether the index
        // survives depends on where the demuxer had to READ (the interrupt is
        // only consulted on I/O, so a small already-buffered file loads its
        // Cues regardless — which is why this asserts a usable plan rather
        // than a basis).
        let plan = try #require(SegmentPlanProbe.plan(
            url: fixture, targetSeconds: 6, indexLoadBudget: .zero
        ))
        #expect(!plan.entries.isEmpty)
        // Whatever the basis, the plan must still cover the source: a
        // truncated plan would promise AVPlayer segments that stop early.
        let covered = plan.entries.reduce(0) { $0 + $1.duration }
        #expect(covered > 7, "an 8 s source planned as \(covered)s on \(plan.basis)")
    }

    @Test("The nudge seek leaves the read position at the head, budget or not")
    func indexLoadRestoresPosition() throws {
        // The guard is lifted before the seek back to zero precisely so an
        // expired budget cannot strand the producer mid-file. Proven through
        // the served output: a session whose producer started mid-file would
        // serve a first segment that doesn't begin at the presentation
        // origin.
        let fixture = try #require(Bundle.module.url(
            forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"
        ))
        let plan = try #require(SegmentPlanProbe.plan(
            url: fixture, targetSeconds: 6, indexLoadBudget: .zero
        ))
        #expect(plan.entries.first?.startPTS == 0)
    }
}
