import Testing
import Foundation
@testable import PrismCore

// MARK: - Fixtures

private func dolbyVision(profile: UInt8, compat: UInt8) -> DolbyVisionConfiguration {
    DolbyVisionConfiguration(
        versionMajor: 1, versionMinor: 0,
        profile: profile, level: 6,
        rpuPresent: true,
        enhancementLayerPresent: profile == 7,
        baseLayerPresent: profile != 5,
        baseLayerSignalCompatibilityID: compat
    )
}

private let p5 = dolbyVision(profile: 5, compat: 0)
private let p7 = dolbyVision(profile: 7, compat: 6)
private let p81 = dolbyVision(profile: 8, compat: 1)
private let p82 = dolbyVision(profile: 8, compat: 2)
private let p84 = dolbyVision(profile: 8, compat: 4)

private func display(
    hdr: Bool, dv: Bool, panelNow: Bool? = nil
) -> DisplayCapabilities {
    DisplayCapabilities(
        isHDRReady: hdr, isDolbyVisionCapable: dv, panelIsCurrentlyHDR: panelNow
    )
}

// MARK: - DisplayCriteriaChoice.forSource

@Suite("Display criteria choice")
struct DisplayCriteriaChoiceTests {

    @Test("DV profiles ask for Dolby Vision on a DV-capable display")
    func dolbyVisionOnCapableDisplay() {
        for dv in [p5, p81, p84] {
            let choice = DisplayCriteriaChoice.forSource(
                dynamicRange: .pq, declaredDolbyVision: dv,
                display: display(hdr: true, dv: true), frameRate: 23.976
            )
            #expect(choice.target == .dolbyVision)
            #expect(choice.refreshRate == Float(23.976))
        }
    }

    @Test("Unconverted Profile 7 keeps its HDR10 base range on a DV-capable display")
    func unconvertedProfile7GetsHDR10() {
        let choice = DisplayCriteriaChoice.forSource(
            dynamicRange: .pq, declaredDolbyVision: p7,
            display: display(hdr: true, dv: true), frameRate: 23.976
        )
        #expect(choice.target == .hdr10)
        #expect(choice.refreshRate == Float(23.976))
    }

    @Test("Profile 7 converted to 8.1 asks for Dolby Vision on a DV-capable display")
    func convertedProfile7GetsDolbyVision() {
        let choice = DisplayCriteriaChoice.forSource(
            dynamicRange: .pq, declaredDolbyVision: p7.convertedToProfile81,
            display: display(hdr: true, dv: true), frameRate: 23.976
        )
        #expect(choice.target == .dolbyVision)
        #expect(choice.refreshRate == Float(23.976))
    }

    @Test("Unrecognised DV configurations keep the base range on a DV-capable display")
    func unknownConfigurationGetsBaseRange() {
        for dv in [dolbyVision(profile: 9, compat: 1), dolbyVision(profile: 8, compat: 3)] {
            for (range, target) in [
                (DynamicRange.pq, DisplayCriteriaChoice.Target.hdr10),
                (.hlg, .hlg), (.sdr, .sdr)
            ] {
                let choice = DisplayCriteriaChoice.forSource(
                    dynamicRange: range, declaredDolbyVision: dv,
                    display: display(hdr: true, dv: true), frameRate: 24
                )
                #expect(choice.target == target)
                #expect(choice.refreshRate == 24)
            }
        }
    }

    @Test("Profile 8.2's Rec.709 base never asks for DV — same honesty rule as the playlist")
    func sdrCompatibleBaseStaysSDR() {
        let choice = DisplayCriteriaChoice.forSource(
            dynamicRange: .sdr, declaredDolbyVision: p82,
            display: display(hdr: true, dv: true), frameRate: 24
        )
        #expect(choice.target == .sdr)
    }

    @Test("A DV-incapable display is asked for the base layer's own range")
    func dvIncapableDisplayGetsBaseRange() {
        // 8.1: HDR10 base.
        #expect(DisplayCriteriaChoice.forSource(
            dynamicRange: .pq, declaredDolbyVision: p81,
            display: display(hdr: true, dv: false), frameRate: 24
        ).target == .hdr10)
        // 8.4: HLG base.
        #expect(DisplayCriteriaChoice.forSource(
            dynamicRange: .hlg, declaredDolbyVision: p84,
            display: display(hdr: true, dv: false), frameRate: 24
        ).target == .hlg)
        // 5: no base layer; the system's Dolby Vision decoder maps its dvh1
        // picture to PQ, served through the same dvh1.05 master.
        #expect(DisplayCriteriaChoice.forSource(
            dynamicRange: .pq, declaredDolbyVision: p5,
            display: display(hdr: true, dv: false), frameRate: 24
        ).target == .hdr10)
    }

    @Test("A display that isn't HDR-ready gets a rate-only (SDR) choice for any source")
    func nonHDRDisplayGetsRateOnly() {
        for (range, dv) in [(DynamicRange.pq, p5), (.pq, p81), (.hlg, p84)] {
            let choice = DisplayCriteriaChoice.forSource(
                dynamicRange: range, declaredDolbyVision: dv,
                display: display(hdr: false, dv: false), frameRate: 25
            )
            #expect(choice.target == .sdr)
            #expect(choice.refreshRate == 25)
        }
    }

    @Test("A panel currently presenting HDR rescues a conservative capability read")
    func currentPanelModeRescuesConservativeRead() {
        let choice = DisplayCriteriaChoice.forSource(
            dynamicRange: .pq, declaredDolbyVision: nil,
            display: display(hdr: false, dv: false, panelNow: true), frameRate: 24
        )
        #expect(choice.target == .hdr10)
    }

    @Test("SDR keeps its frame rate — the rate-only write is what engages Match Frame Rate")
    func sdrCarriesRate() {
        let choice = DisplayCriteriaChoice.forSource(
            dynamicRange: .sdr, declaredDolbyVision: nil,
            display: display(hdr: true, dv: true), frameRate: 23.976
        )
        #expect(choice.target == .sdr)
        #expect(choice.refreshRate == Float(23.976))
        #expect(!choice.wantsHDRPanel)
    }

    @Test("An unknown frame rate stays unknown rather than guessed")
    func unknownRateStaysNil() {
        let choice = DisplayCriteriaChoice.forSource(
            dynamicRange: .pq, declaredDolbyVision: nil,
            display: display(hdr: true, dv: false), frameRate: nil
        )
        #expect(choice.refreshRate == nil)
    }
}

// MARK: - DisplayCriteriaLogic

@Suite("Display criteria logic")
struct DisplayCriteriaLogicTests {

    @Test("An identical re-write is redundant; any field change is not; a reset clears the baseline")
    func redundantWriteDetection() {
        let dv24 = DisplayCriteriaLogic.WrittenCriteria(target: .dolbyVision, refreshRate: 24)
        #expect(DisplayCriteriaLogic.writeIsRedundant(previous: dv24, next: dv24))
        #expect(!DisplayCriteriaLogic.writeIsRedundant(
            previous: dv24,
            next: .init(target: .dolbyVision, refreshRate: 25)
        ))
        #expect(!DisplayCriteriaLogic.writeIsRedundant(
            previous: dv24,
            next: .init(target: .hdr10, refreshRate: 24)
        ))
        #expect(!DisplayCriteriaLogic.writeIsRedundant(previous: nil, next: dv24))
    }

    @Test("A raised headroom answers yes; a quiet one is answered by the panel's history")
    func panelPresentsHDRResolution() {
        // Live positive always wins.
        #expect(DisplayCriteriaLogic.panelPresentsHDR(
            headroomIsRaised: true, wroteHDRCriteria: false, panelHasProvenHDR: false
        ))
        // Quiet headroom after an HDR write on a panel that has proven itself:
        // it was already in the target mode, no transition raised the value.
        #expect(DisplayCriteriaLogic.panelPresentsHDR(
            headroomIsRaised: false, wroteHDRCriteria: true, panelHasProvenHDR: true
        ))
        // Quiet headroom on an unproven panel stays the conservative no —
        // this is the display that would reject a PQ master.
        #expect(!DisplayCriteriaLogic.panelPresentsHDR(
            headroomIsRaised: false, wroteHDRCriteria: true, panelHasProvenHDR: false
        ))
        // Proof without an engine HDR write proves nothing about THIS session.
        #expect(!DisplayCriteriaLogic.panelPresentsHDR(
            headroomIsRaised: false, wroteHDRCriteria: false, panelHasProvenHDR: true
        ))
    }

    @Test("A dynamic-range write gets room for a real HDMI handshake; rate-only keeps the short bounds")
    func settleBoundsScaleWithTheWrite() {
        // The race this pins: a DV/HDR10 switch that ends after the old flat
        // 1 s + 2 s window loaded the master against the panel's previous
        // mode, and the -11868 fallback silently played the title as HDR10 —
        // Dolby Vision one run, black-bars HDR10 the next.
        let hdr = DisplayCriteriaLogic.settleBounds(wantsHDRPanel: true)
        #expect(hdr.startGrace == .seconds(2))
        #expect(hdr.settleCap == .seconds(6))

        // A refresh-rate switch has no range claim to lose a race for, and
        // stretching every SDR load would be dead startup time.
        let rateOnly = DisplayCriteriaLogic.settleBounds(wantsHDRPanel: false)
        #expect(rateOnly.startGrace == .seconds(1))
        #expect(rateOnly.settleCap == .seconds(2))

        // The old flat bounds must never quietly come back for HDR writes.
        #expect(hdr.startGrace > rateOnly.startGrace)
        #expect(hdr.settleCap > rateOnly.settleCap)
    }

    @Test("A settle report's summary carries the outcome and the real times, log-ready")
    func settleReportSummaries() {
        // Settled with a visible start: both numbers appear.
        #expect(
            DisplayCriteriaLogic.SettleReport(
                outcome: .modeSwitchEnd, switchStartedAfterMilliseconds: 380, totalMilliseconds: 2140
            ).summary == "settled via modeSwitchEnd in 2140ms (switch started at 380ms)"
        )
        // Settled without an observed start: no phantom start time.
        #expect(
            DisplayCriteriaLogic.SettleReport(
                outcome: .headroomRaised, totalMilliseconds: 90
            ).summary == "settled via headroomRaised in 90ms"
        )
        // The cap expiring names itself — this is the line that says the
        // panel's switch is unobservable, not that the code is slow.
        #expect(
            DisplayCriteriaLogic.SettleReport(
                outcome: .capExpired, switchStartedAfterMilliseconds: 950, totalMilliseconds: 8000
            ).summary == "settle cap expired after 8000ms (switch started at 950ms)"
        )
        // The no-wait exits explain why nothing was waited for.
        #expect(
            DisplayCriteriaLogic.SettleReport(
                outcome: .matchingDisabled, totalMilliseconds: 0
            ).summary == "no wait: Match Content disabled"
        )
        #expect(
            DisplayCriteriaLogic.SettleReport(
                outcome: .noSwitchStarted, totalMilliseconds: 2000
            ).summary == "no switch started within 2000ms grace"
        )
        // The ambiguous clear names both times: when the flag cleared and
        // how long the HDR signal was watched for — the line that says the
        // panel probably stayed SDR and a master rejection may follow.
        #expect(
            DisplayCriteriaLogic.SettleReport(
                outcome: .clearedWithoutHDRSignal,
                switchStartedAfterMilliseconds: 11,
                clearedAfterMilliseconds: 2913,
                totalMilliseconds: 6000
            ).summary
                == "switch cleared at 2913ms but HDR never signalled; watched to 6000ms (switch started at 11ms)"
        )
    }
}

// MARK: - Settle wait

/// A panel whose switch timeline is scripted in milliseconds from creation:
/// in-progress windows plus start / end notification instants. A clear
/// forgets every notification posted up to that moment, like the
/// controller's flags.
@MainActor
private final class ScriptedPanel {
    private let t0 = ContinuousClock.now
    var inProgress: [Range<Int>] = []
    var starts: [Int] = []
    var ends: [Int] = []
    var headroom: [Range<Int>] = []
    private var clearedAt = -1

    private var now: Int { Int((ContinuousClock.now - t0) / .milliseconds(1)) }
    private func posted(_ events: [Int]) -> Bool {
        let now = self.now
        return events.contains { $0 > clearedAt && $0 <= now }
    }

    var signals: DisplayCriteriaLogic.SwitchSignals {
        .init(
            inProgress: { let now = self.now; return self.inProgress.contains { $0.contains(now) } },
            headroomRaised: { let now = self.now; return self.headroom.contains { $0.contains(now) } },
            startSignalled: { self.posted(self.starts) },
            endSignalled: { self.posted(self.ends) },
            clearSignals: { self.clearedAt = self.now }
        )
    }
}

@MainActor
private func settle(
    _ panel: ScriptedPanel, inFlightAtWrite: Bool, wantsHDR: Bool = false,
    grace: Duration = .milliseconds(300), cap: Duration = .milliseconds(800)
) async -> DisplayCriteriaLogic.SettleReport {
    await DisplayCriteriaLogic.settle(
        wantsHDRPanel: wantsHDR, switchInFlightAtWrite: inFlightAtWrite,
        startGrace: grace, settleCap: cap, signals: panel.signals
    )
}

@Suite("Display criteria settle wait")
@MainActor
struct DisplayCriteriaSettleTests {

    /// The reset's switch back to the default mode is running at write time
    /// (0–200 ms, its end posted at 200 and once more late at 230); the
    /// write's own switch runs 400–600 ms.
    private func overlappedPanel() -> ScriptedPanel {
        let panel = ScriptedPanel()
        panel.inProgress = [0..<200, 400..<600]
        panel.starts = [400]
        panel.ends = [200, 230, 600]
        return panel
    }

    @Test("A write that lands mid-switch settles on its own switch, not the earlier one's end")
    func overlapSettlesOnOwnSwitch() async {
        let report = await settle(overlappedPanel(), inFlightAtWrite: true)
        #expect(report.outcome == .modeSwitchEnd)
        #expect((report.switchStartedAfterMilliseconds ?? 0) >= 350)
        #expect(report.totalMilliseconds >= 550)
        guard case .drained(let ms)? = report.priorSwitch else {
            Issue.record("expected a drained prior switch, got \(String(describing: report.priorSwitch))")
            return
        }
        #expect(ms >= 150 && ms < 400)
        #expect(report.summary.hasSuffix("(earlier switch drained at \(ms)ms)"))
    }

    @Test("Without the write-time flag the earlier switch's end settles the wait — the bug")
    func overlapWithoutFlagSettlesEarly() async {
        let report = await settle(overlappedPanel(), inFlightAtWrite: false)
        #expect(report.outcome == .modeSwitchEnd)
        #expect(report.totalMilliseconds < 400)
        #expect(report.priorSwitch == nil)
    }

    @Test("A chained switch (old end and new start together, flag never down) settles on its own end")
    func overlapChainedWithoutIdle() async {
        let panel = ScriptedPanel()
        panel.inProgress = [0..<700]
        panel.starts = [200]
        panel.ends = [200, 700]
        let report = await settle(panel, inFlightAtWrite: true)
        #expect(report.outcome == .modeSwitchEnd)
        #expect((report.switchStartedAfterMilliseconds ?? 0) >= 150)
        #expect(report.totalMilliseconds >= 650)
        guard case .drained? = report.priorSwitch else {
            Issue.record("expected a drained prior switch, got \(String(describing: report.priorSwitch))")
            return
        }
    }

    @Test("A write tvOS folded into the running switch costs at most one grace extra")
    func overlapWithNoNewSwitch() async {
        let panel = ScriptedPanel()
        panel.inProgress = [0..<200]
        panel.ends = [200]
        let report = await settle(panel, inFlightAtWrite: true)
        #expect(report.outcome == .noSwitchStarted)
        #expect(report.totalMilliseconds >= 450 && report.totalMilliseconds < 900)
        guard case .drained? = report.priorSwitch else {
            Issue.record("expected a drained prior switch, got \(String(describing: report.priorSwitch))")
            return
        }
    }

    @Test("After an overlap, headroom left raised by the earlier HDR switch does not settle an HDR write")
    func overlapIgnoresStaleHeadroom() async {
        // Reset returned the panel to an HDR10 home mode (headroom up from
        // 150 ms and lingering); the write asks for DV and switches 400–600.
        let panel = overlappedPanel()
        panel.headroom = [150..<1_000_000]
        let report = await settle(panel, inFlightAtWrite: true, wantsHDR: true)
        #expect(report.outcome == .modeSwitchEnd)
        #expect((report.switchStartedAfterMilliseconds ?? 0) >= 350)
        #expect(report.totalMilliseconds >= 550)
    }

    @Test("After an overlap, headroom that rises only during the write's own switch still settles it")
    func overlapCountsFreshHeadroom() async {
        let panel = ScriptedPanel()
        panel.inProgress = [0..<200, 400..<1_000_000]
        panel.starts = [400]
        panel.ends = [200]
        panel.headroom = [500..<1_000_000]
        let report = await settle(panel, inFlightAtWrite: true, wantsHDR: true)
        #expect(report.outcome == .headroomRaised)
        #expect(report.totalMilliseconds >= 450 && report.totalMilliseconds < 900)
    }

    @Test("Without an overlap, raised headroom is still an immediate no-wait")
    func headroomWithoutOverlap() async {
        let panel = ScriptedPanel()
        panel.headroom = [0..<1_000_000]
        let report = await settle(panel, inFlightAtWrite: false, wantsHDR: true)
        #expect(report.outcome == .alreadyPresentingHDR)
    }

    @Test("A redundant re-apply between the write and the wait keeps the overlap")
    func overlapSurvivesRedundantApply() {
        var overlap = DisplayCriteriaLogic.WriteOverlap()
        overlap.record(switchInFlightAtWrite: true)
        // A redundant apply touches nothing — that is the whole fix.
        #expect(overlap.beginWait().inFlight)
    }

    @Test("Concurrent waits for one write both drain; a finished wait clears only its own write")
    func overlapSharedByConcurrentWaits() {
        var overlap = DisplayCriteriaLogic.WriteOverlap()
        overlap.record(switchInFlightAtWrite: true)
        let first = overlap.beginWait()
        let second = overlap.beginWait()
        #expect(first.inFlight && second.inFlight)
        overlap.endWait(generation: first.generation)
        #expect(!overlap.beginWait().inFlight)

        // A newer overlapping write during a wait survives that wait's end.
        overlap.record(switchInFlightAtWrite: false)
        let stale = overlap.beginWait()
        overlap.record(switchInFlightAtWrite: true)
        overlap.endWait(generation: stale.generation)
        #expect(overlap.beginWait().inFlight)
    }

    @Test("Normal switch without an overlap is unchanged")
    func normalSwitch() async {
        let panel = ScriptedPanel()
        panel.inProgress = [100..<300]
        panel.starts = [100]
        panel.ends = [300]
        let report = await settle(panel, inFlightAtWrite: false)
        #expect(report.outcome == .modeSwitchEnd)
        #expect((report.switchStartedAfterMilliseconds ?? -1) >= 50)
        #expect(report.totalMilliseconds >= 250 && report.totalMilliseconds < 600)
        #expect(report.priorSwitch == nil)
        #expect(!report.wasCancelled)
    }

    @Test("No switch at all still exits after the grace")
    func noSwitch() async {
        let report = await settle(ScriptedPanel(), inFlightAtWrite: false)
        #expect(report.outcome == .noSwitchStarted)
        #expect(report.totalMilliseconds >= 250 && report.totalMilliseconds < 700)
        #expect(report.priorSwitch == nil)
    }

    @Test("Cancellation ends the wait at once, even mid-drain of a stuck switch")
    func cancellationEndsWait() async {
        let panel = ScriptedPanel()
        panel.inProgress = [0..<1_000_000]
        let began = ContinuousClock.now
        let task = Task { @MainActor in
            await settle(panel, inFlightAtWrite: true, grace: .seconds(5), cap: .seconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let report = await task.value
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(report.wasCancelled)
        #expect(report.summary.hasPrefix("cancelled: "))
    }
}

// MARK: - Master-vs-media routing

@Suite("Master variant permission")
struct MasterVariantPermissionTests {

    /// The master is what a P5 picture needs on an HDR10 panel too; a panel
    /// that refuses it is the one-shot fallback's job, not a proactive guess.
    @Test("Profile 5 gets a master on an HDR display with or without Dolby Vision")
    func p5MasterOnAnyHDRDisplay() {
        #expect(HLSRemuxer.masterVariantPermitted(
            dynamicRange: .pq, dolbyVision: p5,
            displayIsHDRReady: true, displayIsDolbyVisionCapable: false
        ))
        #expect(HLSRemuxer.masterVariantPermitted(
            dynamicRange: .pq, dolbyVision: p5,
            displayIsHDRReady: true, displayIsDolbyVisionCapable: true
        ))
    }

    @Test("Profile 5 on an SDR display stays media-direct, like any PQ source")
    func p5OnSDRDisplayIsMediaDirect() {
        #expect(!HLSRemuxer.masterVariantPermitted(
            dynamicRange: .pq, dolbyVision: p5,
            displayIsHDRReady: false, displayIsDolbyVisionCapable: false
        ))
    }

    @Test("8.x profiles keep their master on a non-DV display — hvc1 primary IS the fallback")
    func profile8SurvivesNonDVDisplay() {
        for dv in [p81, p84] {
            #expect(HLSRemuxer.masterVariantPermitted(
                dynamicRange: .pq, dolbyVision: dv,
                displayIsHDRReady: true, displayIsDolbyVisionCapable: false
            ))
        }
    }

    @Test("An HDR source on a display nobody vouched for gets no master")
    func hdrNeedsReadyDisplay() {
        #expect(!HLSRemuxer.masterVariantPermitted(
            dynamicRange: .pq, dolbyVision: nil,
            displayIsHDRReady: false, displayIsDolbyVisionCapable: false
        ))
        #expect(HLSRemuxer.masterVariantPermitted(
            dynamicRange: .sdr, dolbyVision: nil,
            displayIsHDRReady: false, displayIsDolbyVisionCapable: false
        ))
    }
}

// MARK: - DisplayCapabilities

@Suite("Display capabilities current-mode read")
struct DisplayCapabilitiesPanelModeTests {

    @Test("offersHDR: capability is the optimistic read, a live HDR panel the certain one")
    func offersHDRComposition() {
        #expect(display(hdr: true, dv: false).offersHDR)
        #expect(display(hdr: false, dv: false, panelNow: true).offersHDR)
        #expect(!display(hdr: false, dv: false, panelNow: false).offersHDR)
        #expect(!display(hdr: false, dv: false, panelNow: nil).offersHDR)
    }
}
