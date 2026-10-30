import Testing
import Foundation
import Libavutil
@testable import PrismCore

// MARK: - Fixtures

private func dolbyVision(profile: UInt8, compat: UInt8, level: UInt8 = 6) -> DolbyVisionConfiguration {
    DolbyVisionConfiguration(
        versionMajor: 1, versionMinor: 0,
        profile: profile, level: level,
        rpuPresent: true,
        enhancementLayerPresent: profile == 7,
        baseLayerPresent: profile != 5,
        baseLayerSignalCompatibilityID: compat
    )
}

private let p5 = dolbyVision(profile: 5, compat: 0)
private let p7 = dolbyVision(profile: 7, compat: 6)
private let p81 = dolbyVision(profile: 8, compat: 1)
private let p84 = dolbyVision(profile: 8, compat: 4)

/// The VUI a genuine Profile 5 carries (nothing: IPT has no code point), and
/// the one a relabelled HDR10 base declares.
private let unspecifiedVUI: (transfer: String?, matrix: String?) = ("unknown", "unknown")
private let hdr10VUI: (transfer: String?, matrix: String?) = ("smpte2084", "bt2020nc")

private enum Panel: CaseIterable {
    case dolbyVision, hdr10Only, callerSaidNoDV, sdr

    var capabilities: DisplayCapabilities {
        switch self {
        case .dolbyVision:
            return DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true, source: .availableHDRModes)
        case .hdr10Only:
            return DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: false, source: .availableHDRModes)
        case .callerSaidNoDV:
            return DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: false, source: .caller)
        case .sdr:
            return DisplayCapabilities(isHDRReady: false, isDolbyVisionCapable: false, source: .availableHDRModes)
        }
    }
}

/// What one session serves, assembled from the same pure pieces the remuxer
/// calls in `run()` — preference, serving decision, master permission and
/// build, display criteria.
private struct Served {
    let declared: DolbyVisionConfiguration?
    let stripsRecord: Bool
    /// `nil` = media playlist.
    let codecs: String?
    let supplemental: String?
    let videoRange: DynamicRange?
    let criteria: DisplayCriteriaChoice.Target

    init(
        _ source: DolbyVisionConfiguration,
        range: DynamicRange,
        vui: (transfer: String?, matrix: String?) = unspecifiedVUI,
        preference: DolbyVisionPreference,
        display: Panel,
        converting: Bool = false
    ) {
        let capabilities = display.capabilities
        let presentsBaseLayer = preference.presentsBaseLayer(
            of: source, colorTransferName: vui.transfer, colorSpaceName: vui.matrix
        )
        let serving = HLSRemuxer.dolbyVisionServing(
            source: source,
            converting: converting,
            presentsBaseLayer: presentsBaseLayer,
            displayIsDolbyVisionCapable: capabilities.isDolbyVisionCapable
        )
        declared = serving.declared
        stripsRecord = serving.stripsRecord
        let servedRange = HLSRemuxer.servedDynamicRange(
            probed: range, source: source,
            presentsBaseLayer: presentsBaseLayer, colorTransferName: vui.transfer
        )
        criteria = DisplayCriteriaChoice.forSource(
            dynamicRange: servedRange, declaredDolbyVision: serving.declared,
            display: capabilities, frameRate: 23.976
        ).target
        let variant = MasterPlaylistBuilder.VariantDescription(
            bandwidth: 30_000_000,
            frameRate: 23.976,
            dynamicRange: servedRange,
            videoCodec: .explicit("hvc1.2.4.L153.B0"),
            dolbyVision: serving.declared,
            displayIsDolbyVisionCapable: capabilities.isDolbyVisionCapable
        )
        let permitted = HLSRemuxer.masterVariantPermitted(
            dynamicRange: servedRange, dolbyVision: serving.declared,
            displayIsHDRReady: capabilities.offersHDR,
            displayIsDolbyVisionCapable: capabilities.isDolbyVisionCapable
        )
        if permitted, (try? MasterPlaylistBuilder.build(variant)) != nil {
            codecs = MasterPlaylistBuilder.codecsAttribute(for: variant)
            supplemental = MasterPlaylistBuilder.supplementalCodecsString(for: variant)
            videoRange = servedRange
        } else {
            codecs = nil
            supplemental = nil
            videoRange = nil
        }
    }
}

// MARK: - The preference itself

@Suite("Dolby Vision preference")
struct DolbyVisionPreferenceTests {

    @Test("automatic never presents a base layer")
    func automaticIsDolbyVision() {
        for dv in [p5, p7, p81, p84] {
            #expect(!DolbyVisionPreference.automatic.presentsBaseLayer(
                of: dv, colorTransferName: hdr10VUI.transfer, colorSpaceName: hdr10VUI.matrix
            ))
        }
    }

    @Test("baseLayerOnly applies to every profile with a base layer")
    func baseLayerProfiles() {
        for dv in [p7, p81, p84] {
            #expect(DolbyVisionPreference.baseLayerOnly.presentsBaseLayer(
                of: dv, colorTransferName: nil, colorSpaceName: nil
            ))
        }
    }

    /// There is nothing under a genuine P5 to fall back to: serving its IPT
    /// picture as plain HEVC is the solarised misread itself.
    @Test("baseLayerOnly is ignored for a genuine Profile 5")
    func genuineProfile5IgnoresPreference() {
        #expect(!DolbyVisionPreference.baseLayerOnly.presentsBaseLayer(
            of: p5, colorTransferName: unspecifiedVUI.transfer, colorSpaceName: unspecifiedVUI.matrix
        ))
        #expect(!DolbyVisionPreference.baseLayerOnly.presentsBaseLayer(
            of: p5, colorTransferName: nil, colorSpaceName: nil
        ))
        // A PQ transfer alone is not a YCbCr base: the matrix has to say so.
        #expect(!DolbyVisionPreference.baseLayerOnly.presentsBaseLayer(
            of: p5, colorTransferName: "smpte2084", colorSpaceName: "unknown"
        ))
    }

    @Test("baseLayerOnly applies to a Profile 5 record over a BT.2020 YCbCr PQ or HLG VUI")
    func relabelledProfile5HonoursPreference() {
        for (transfer, matrix) in [("smpte2084", "bt2020nc"), ("arib-std-b67", "bt2020nc"), ("smpte2084", "bt2020c")] {
            #expect(DolbyVisionPreference.baseLayerOnly.presentsBaseLayer(
                of: p5, colorTransferName: transfer, colorSpaceName: matrix
            ))
        }
    }

    @Test("no Dolby Vision, no base layer to present")
    func plainSourceIsUntouched() {
        #expect(!DolbyVisionPreference.baseLayerOnly.presentsBaseLayer(
            of: nil, colorTransferName: hdr10VUI.transfer, colorSpaceName: hdr10VUI.matrix
        ))
    }

    /// Unstarted sessions over a fixture: nothing here needs a remux, only
    /// the options a successor is built from.
    @Test("sessions default to automatic, and a clone and both fallbacks carry the preference")
    func optionIsCarried() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/hevc_eac3.mkv", withExtension: nil)
                ?? Bundle.module.url(forResource: "hevc_eac3.mkv", withExtension: nil, subdirectory: "Fixtures")
        )
        let plain = try PrismCoreSession(url: url)
        #expect(await plain.options.dolbyVisionPreference == .automatic)

        let session = try PrismCoreSession(
            url: url,
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true),
            dolbyVisionPreference: .baseLayerOnly
        )
        #expect(await session.options.dolbyVisionPreference == .baseLayerOnly)
        let clone = try await session.makeSession { $0.segmentCacheBytes = nil }
        #expect(await clone.options.dolbyVisionPreference == .baseLayerOnly)
        let muxed = try await clone.makeMuxedFallbackSession()
        #expect(await muxed.options.dolbyVisionPreference == .baseLayerOnly)
        let rejected = try await muxed.makeMasterRejectionFallbackSession()
        #expect(await rejected.options.dolbyVisionPreference == .baseLayerOnly)
        // The preference is no display read: the honest one survives untouched.
        #expect(await clone.options.display.isDolbyVisionCapable)

        for each in [plain, session, clone, muxed, rejected] { await each.stop() }
    }
}

// MARK: - What each profile is served

@Suite("Dolby Vision serving per profile, display and preference")
struct DolbyVisionServingMatrixTests {

    // MARK: Profile 5

    @Test("Profile 5 on a DV display: dvh1.05 master, record kept, Dolby Vision criteria")
    func profile5OnDolbyVisionDisplay() {
        for preference in [DolbyVisionPreference.automatic, .baseLayerOnly] {
            let served = Served(p5, range: .pq, preference: preference, display: .dolbyVision)
            #expect(served.declared == p5)
            #expect(!served.stripsRecord)
            #expect(served.codecs == "dvh1.05.06")
            #expect(served.supplemental == nil)
            #expect(served.videoRange == .pq)
            #expect(served.criteria == .dolbyVision)
        }
    }

    /// The 3.9.2 shape here was the bare media playlist: no master, because
    /// `masterVariantPermitted` refused P5 to a non-DV display.
    @Test("Profile 5 on an HDR10-only display: the same master, record kept, HDR10 criteria")
    func profile5OnHDR10Display() {
        let served = Served(p5, range: .pq, preference: .automatic, display: .hdr10Only)
        #expect(served.declared == p5)
        #expect(!served.stripsRecord)
        #expect(served.codecs == "dvh1.05.06")
        #expect(served.supplemental == nil)
        #expect(served.videoRange == .pq)
        #expect(served.criteria == .hdr10)
    }

    /// The host that used to say "no Dolby Vision" to mean a user setting:
    /// a P5 still needs the master and its record, whatever it was told.
    @Test("Profile 5 when the caller said dv=false: the master all the same")
    func profile5WhenCallerSaidNoDV() {
        for preference in [DolbyVisionPreference.automatic, .baseLayerOnly] {
            let served = Served(p5, range: .pq, preference: preference, display: .callerSaidNoDV)
            #expect(served.declared == p5)
            #expect(!served.stripsRecord)
            #expect(served.codecs == "dvh1.05.06")
            #expect(served.supplemental == nil)
        }
    }

    @Test("Profile 5 on an SDR display: media playlist, record kept")
    func profile5OnSDRDisplay() {
        let served = Served(p5, range: .pq, preference: .automatic, display: .sdr)
        #expect(served.codecs == nil)
        #expect(served.declared == p5)
        #expect(!served.stripsRecord)
        #expect(served.criteria == .sdr)
    }

    @Test("a Profile 5 record over an HDR10 VUI with baseLayerOnly: plain hvc1, record stripped")
    func relabelledProfile5BaseLayerOnly() {
        let served = Served(
            p5, range: .pq, vui: hdr10VUI, preference: .baseLayerOnly, display: .dolbyVision
        )
        #expect(served.declared == nil)
        #expect(served.stripsRecord)
        #expect(served.codecs == "hvc1.2.4.L153.B0")
        #expect(served.supplemental == nil)
        #expect(served.videoRange == .pq)
        #expect(served.criteria == .hdr10)
        // …and automatic keeps serving it as Profile 5.
        let automatic = Served(p5, range: .pq, vui: hdr10VUI, preference: .automatic, display: .dolbyVision)
        #expect(automatic.codecs == "dvh1.05.06")
        #expect(!automatic.stripsRecord)
    }

    /// The probe reads every P5 as PQ; a base layer presented alone is
    /// declared with the range its own VUI states, or an HLG base would go
    /// out as `VIDEO-RANGE=PQ`.
    @Test("a Profile 5 record over an HLG VUI with baseLayerOnly is declared HLG")
    func relabelledProfile5HLGBase() {
        let served = Served(
            p5, range: .pq, vui: ("arib-std-b67", "bt2020nc"),
            preference: .baseLayerOnly, display: .dolbyVision
        )
        #expect(served.declared == nil)
        #expect(served.videoRange == .hlg)
        #expect(served.criteria == .hlg)
        // Nothing moves without the preference, or for profiles whose range
        // the record already names.
        #expect(HLSRemuxer.servedDynamicRange(
            probed: .pq, source: p5, presentsBaseLayer: false, colorTransferName: "arib-std-b67"
        ) == .pq)
        #expect(HLSRemuxer.servedDynamicRange(
            probed: .hlg, source: p84, presentsBaseLayer: true, colorTransferName: "smpte2084"
        ) == .hlg)
    }

    // MARK: Profile 8.1 / 8.4

    @Test("8.1 and 8.4 automatic on a DV display: hvc1 + supplemental, record kept")
    func profile8AutomaticOnDolbyVisionDisplay() {
        for (dv, range, brand) in [(p81, DynamicRange.pq, "db1p"), (p84, .hlg, "db4h")] {
            let served = Served(dv, range: range, preference: .automatic, display: .dolbyVision)
            #expect(served.declared == dv)
            #expect(!served.stripsRecord)
            #expect(served.codecs == "hvc1.2.4.L153.B0")
            #expect(served.supplemental == "dvh1.08.06/\(brand)")
            #expect(served.criteria == .dolbyVision)
        }
    }

    @Test("8.1 and 8.4 baseLayerOnly on a DV display: the base layer, as a non-DV display gets it")
    func profile8BaseLayerOnly() {
        for (dv, range, criteria) in [
            (p81, DynamicRange.pq, DisplayCriteriaChoice.Target.hdr10), (p84, .hlg, .hlg),
        ] {
            let served = Served(dv, range: range, preference: .baseLayerOnly, display: .dolbyVision)
            let nonDV = Served(dv, range: range, preference: .automatic, display: .hdr10Only)
            #expect(served.declared == nil)
            #expect(served.stripsRecord)
            #expect(served.codecs == "hvc1.2.4.L153.B0")
            #expect(served.supplemental == nil)
            #expect(served.criteria == criteria)
            #expect(served.codecs == nonDV.codecs)
            #expect(served.supplemental == nonDV.supplemental)
            #expect(served.criteria == nonDV.criteria)
            #expect(served.stripsRecord == nonDV.stripsRecord)
        }
    }

    @Test("8.1 and 8.4 on an HDR10-only display: base range, no claim, record stripped")
    func profile8OnHDR10Display() {
        for preference in [DolbyVisionPreference.automatic, .baseLayerOnly] {
            let served = Served(p81, range: .pq, preference: preference, display: .hdr10Only)
            #expect(served.stripsRecord)
            #expect(served.supplemental == nil)
            #expect(served.criteria == .hdr10)
        }
    }

    // MARK: Profile 7

    @Test("Profile 7 converted, automatic on a DV display: declared 8.1 with db1p")
    func profile7AutomaticConverted() {
        let served = Served(p7, range: .pq, preference: .automatic, display: .dolbyVision, converting: true)
        #expect(served.declared == p7.convertedToProfile81)
        #expect(!served.stripsRecord)
        #expect(served.supplemental == "dvh1.08.06/db1p")
        #expect(served.criteria == .dolbyVision)
    }

    @Test("Profile 7 baseLayerOnly: HDR10 criteria, record stripped, nothing declared")
    func profile7BaseLayerOnly() {
        for converting in [true, false] {
            let served = Served(
                p7, range: .pq, preference: .baseLayerOnly, display: .dolbyVision, converting: converting
            )
            #expect(served.declared == nil)
            #expect(served.stripsRecord)
            #expect(served.supplemental == nil)
            #expect(served.criteria == .hdr10)
        }
    }

    @Test("Profile 7 on an HDR10-only display: HDR10, record stripped, either preference")
    func profile7OnHDR10Display() {
        for preference in [DolbyVisionPreference.automatic, .baseLayerOnly] {
            let served = Served(p7, range: .pq, preference: preference, display: .hdr10Only, converting: true)
            #expect(served.stripsRecord)
            #expect(served.supplemental == nil)
            #expect(served.criteria == .hdr10)
        }
    }
}

// MARK: - The Profile 5 sample entry

@Suite("Profile 5 colour signalling")
struct Profile5ColourTests {

    /// A P5 encode with an unspecified VUI would otherwise reach AVPlayer as a
    /// `dvh1` entry with no `colr` at all.
    @Test("the fixed BT.2020 / PQ / BT.2020nc tuple, limited range when the source says none")
    func unspecifiedRangeIsLimited() {
        let colour = HLSRemuxer.profile5Colour(sourceRange: AVCOL_RANGE_UNSPECIFIED)
        #expect(colour.primaries == AVCOL_PRI_BT2020)
        #expect(colour.transfer == AVCOL_TRC_SMPTE2084)
        #expect(colour.matrix == AVCOL_SPC_BT2020_NCL)
        #expect(colour.range == AVCOL_RANGE_MPEG)
        #expect(HLSRemuxer.colrDescription(
            primaries: colour.primaries, transfer: colour.transfer,
            matrix: colour.matrix, range: colour.range
        ) == "nclx 9/16/9 limited")
    }

    @Test("a full-range Profile 5 keeps its range")
    func fullRangeIsKept() {
        let colour = HLSRemuxer.profile5Colour(sourceRange: AVCOL_RANGE_JPEG)
        #expect(colour.range == AVCOL_RANGE_JPEG)
        #expect(HLSRemuxer.colrDescription(
            primaries: colour.primaries, transfer: colour.transfer,
            matrix: colour.matrix, range: colour.range
        ) == "nclx 9/16/9 full")
    }

    @Test("nothing specified is reported as no colr box")
    func unspecifiedIsNone() {
        #expect(HLSRemuxer.colrDescription(
            primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_UNSPECIFIED,
            matrix: AVCOL_SPC_UNSPECIFIED, range: AVCOL_RANGE_UNSPECIFIED
        ) == "none")
    }
}

// MARK: - The refusal path

@Suite("Profile 5 master-rejection fallback")
struct Profile5FallbackTests {

    /// Dropping the claim cannot help a P5 master — the `dvh1` primary is the
    /// claim — so the DV-less tier would rebuild the same master forever.
    @Test("a refused Profile 5 master goes straight to the media playlist")
    func profile5GoesToMediaPlaylist() {
        #expect(MasterRejection.fallbackTier(
            masterDeclaresDolbyVision: true, masterIsDolbyVisionOnly: true
        ) == .mediaPlaylist)
    }

    @Test("a refused 8.x master with a DV claim drops the claim first")
    func profile8DropsTheClaim() {
        #expect(MasterRejection.fallbackTier(
            masterDeclaresDolbyVision: true, masterIsDolbyVisionOnly: false
        ) == .withoutDolbyVision)
    }

    @Test("a master without a DV claim goes to the media playlist, as before")
    func noClaimGoesToMediaPlaylist() {
        #expect(MasterRejection.fallbackTier(
            masterDeclaresDolbyVision: false, masterIsDolbyVisionOnly: false
        ) == .mediaPlaylist)
    }

    @Test("the rejection code is read out, nested or not", arguments: [-11868, -11848])
    func rejectionCodeIsReported(code: Int) {
        let outer = NSError(
            domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "AVFoundationErrorDomain", code: code)]
        )
        #expect(MasterRejection.code(of: outer) == code)
        #expect(MasterRejection.code(of: NSError(domain: "AVFoundationErrorDomain", code: code)) == code)
    }

    @Test("other failures are no rejection, so no fallback")
    func otherErrorsAreNoRejection() {
        #expect(MasterRejection.code(of: NSError(domain: "AVFoundationErrorDomain", code: -11800)) == nil)
        #expect(MasterRejection.code(of: NSError(domain: NSURLErrorDomain, code: -1009)) == nil)
        #expect(MasterRejection.code(of: nil) == nil)
        #expect(!MasterRejection.matches(NSError(domain: "AVFoundationErrorDomain", code: -11829)))
    }
}
