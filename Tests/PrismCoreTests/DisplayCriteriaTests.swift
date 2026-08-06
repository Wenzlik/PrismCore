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
        // 5: no base layer; its bitstream is PQ and AVPlayer tone-maps from
        // the dvh1 sample entry on the media-direct route.
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
}

// MARK: - Master-vs-media routing

@Suite("Master variant permission")
struct MasterVariantPermissionTests {

    @Test("Profile 5 on a non-DV display routes media-direct — a bare dvh1.05 master has no fallback variant")
    func p5NeedsDVDisplay() {
        #expect(!HLSRemuxer.masterVariantPermitted(
            dynamicRange: .pq, dolbyVision: p5,
            displayIsHDRReady: true, displayIsDolbyVisionCapable: false
        ))
        #expect(HLSRemuxer.masterVariantPermitted(
            dynamicRange: .pq, dolbyVision: p5,
            displayIsHDRReady: true, displayIsDolbyVisionCapable: true
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
