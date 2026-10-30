import Testing
import Foundation
import Libavcodec
import Libavformat
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

    /// The colour fields are codec parameters, which a container `colr` box
    /// fills as well as the SPS: a genuine P5 muxed with `colr` 9/16/9 looks
    /// exactly like a relabelled one. Only an RPU proves a base layer, and an
    /// RPU that does has already turned the record into a 7 or an 8.
    @Test("baseLayerOnly keeps a Profile 5 record whatever its colour fields say")
    func profile5RecordIgnoresContainerColour() throws {
        for (transfer, matrix) in [("smpte2084", "bt2020nc"), ("arib-std-b67", "bt2020nc"), ("smpte2084", "bt2020c")] {
            #expect(!DolbyVisionPreference.baseLayerOnly.presentsBaseLayer(
                of: p5, colorTransferName: transfer, colorSpaceName: matrix
            ))
        }
        let corrected = try #require(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: 8, colorTransferName: "smpte2084"))
        #expect(DolbyVisionPreference.baseLayerOnly.presentsBaseLayer(
            of: corrected, colorTransferName: hdr10VUI.transfer, colorSpaceName: hdr10VUI.matrix
        ))
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

    /// Whether the audit answered can hinge on startup speed alone: a record
    /// it left as 5 — RPU read as 5, budget spent, no libdovi — is served as
    /// P5 under either preference.
    @Test("a Profile 5 record over an HDR10 VUI the audit left standing stays Profile 5 under baseLayerOnly")
    func unsettledProfile5KeepsItsRecord() {
        for preference in [DolbyVisionPreference.automatic, .baseLayerOnly] {
            let served = Served(p5, range: .pq, vui: hdr10VUI, preference: preference, display: .dolbyVision)
            #expect(served.declared == p5)
            #expect(!served.stripsRecord)
            #expect(served.codecs == "dvh1.05.06")
            #expect(served.supplemental == nil)
            #expect(served.videoRange == .pq)
            #expect(served.criteria == .dolbyVision)
        }
    }

    @Test("a Profile 5 record the RPU corrected to 8 honours baseLayerOnly, PQ or HLG")
    func correctedProfile5BaseLayerOnly() throws {
        let pq = try #require(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: 8, colorTransferName: "smpte2084"))
        let served = Served(pq, range: .pq, vui: hdr10VUI, preference: .baseLayerOnly, display: .dolbyVision)
        #expect(served.declared == nil)
        #expect(served.stripsRecord)
        #expect(served.codecs == "hvc1.2.4.L153.B0")
        #expect(served.supplemental == nil)
        #expect(served.videoRange == .pq)
        #expect(served.criteria == .hdr10)

        let hlg = try #require(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: 8, colorTransferName: "arib-std-b67"))
        let hlgServed = Served(
            hlg, range: DolbyVisionRecordAudit.dynamicRange(of: hlg), vui: ("arib-std-b67", "bt2020nc"),
            preference: .baseLayerOnly, display: .dolbyVision
        )
        #expect(hlgServed.declared == nil)
        #expect(hlgServed.videoRange == .hlg)
        #expect(hlgServed.criteria == .hlg)
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

// MARK: - A Profile 5 record its own VUI contradicts

@Suite("Contradicted Profile 5 record audit")
struct DolbyVisionRecordAuditTests {

    /// The init in the field report: `dvcC` profile 5 over `colr` 9/16/9.
    @Test("only a Profile 5 record over a BT.2020 YCbCr HDR VUI is audited")
    func contradictedRecordIsAudited() {
        #expect(DolbyVisionRecordAudit.recordIsContradicted(
            p5, codecName: "hevc", colorTransferName: hdr10VUI.transfer, colorSpaceName: hdr10VUI.matrix
        ))
        // A genuine P5 reads no packet.
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            p5, codecName: "hevc", colorTransferName: unspecifiedVUI.transfer, colorSpaceName: unspecifiedVUI.matrix
        ))
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            p81, codecName: "hevc", colorTransferName: hdr10VUI.transfer, colorSpaceName: hdr10VUI.matrix
        ))
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            nil, codecName: "hevc", colorTransferName: hdr10VUI.transfer, colorSpaceName: hdr10VUI.matrix
        ))
        // AV1 carries its RPU in an OBU the NAL walk cannot reach.
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            p5, codecName: "av1", colorTransferName: hdr10VUI.transfer, colorSpaceName: hdr10VUI.matrix
        ))
    }

    @Test("an RPU authored as 8 makes the record 8.1, or 8.4 over an HLG VUI")
    func profile8RPUCorrects() throws {
        let pq = try #require(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: 8, colorTransferName: "smpte2084"))
        #expect(pq.profile == 8)
        #expect(pq.baseLayerSignalCompatibilityID == 1)
        #expect(pq.level == p5.level)
        #expect(!pq.enhancementLayerPresent)
        #expect(DolbyVisionRecordAudit.dynamicRange(of: pq) == .pq)

        let hlg = try #require(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: 8, colorTransferName: "arib-std-b67"))
        #expect(hlg.baseLayerSignalCompatibilityID == 4)
        #expect(DolbyVisionRecordAudit.dynamicRange(of: hlg) == .hlg)
    }

    @Test("an RPU authored as 7 makes the record 7, so the 8.1 conversion runs")
    func profile7RPUCorrects() throws {
        let corrected = try #require(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: 7, colorTransferName: "smpte2084"))
        #expect(corrected.isDualLayer)
        #expect(corrected.rpuPresent)
        #expect(corrected.baseLayerSignalCompatibilityID == 6)
        #expect(DolbyVisionRecordAudit.dynamicRange(of: corrected) == .pq)
    }

    @Test("an RPU that agrees, can't be read or names another profile leaves the record")
    func otherRPUsLeaveTheRecord() {
        for rpu in [nil, 5, 4, 10] as [UInt8?] {
            #expect(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: rpu, colorTransferName: "smpte2084") == nil)
        }
        #expect(DolbyVisionRecordAudit.correctedRecord(p81, rpuProfile: 7, colorTransferName: "smpte2084") == nil)
    }

    /// The decisive DV-on case: what a relabelled 8.1 is served once its RPU
    /// has spoken — the 8.1 shape, not the `dvh1.05` that showed it wrong.
    @Test("a corrected 8.1 is served as 8.1 on a DV display and as HDR10 without one")
    func correctedRecordIsServedAsItsProfile() throws {
        let corrected = try #require(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: 8, colorTransferName: "smpte2084"))
        let dv = Served(corrected, range: .pq, vui: hdr10VUI, preference: .automatic, display: .dolbyVision)
        #expect(dv.declared == corrected)
        #expect(!dv.stripsRecord)
        #expect(dv.codecs == "hvc1.2.4.L153.B0")
        #expect(dv.supplemental == "dvh1.08.06/db1p")
        #expect(dv.videoRange == .pq)
        #expect(dv.criteria == .dolbyVision)

        let hdr10 = Served(corrected, range: .pq, vui: hdr10VUI, preference: .automatic, display: .hdr10Only)
        #expect(hdr10.stripsRecord)
        #expect(hdr10.supplemental == nil)
        #expect(hdr10.criteria == .hdr10)

        let corrected7 = try #require(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: 7, colorTransferName: "smpte2084"))
        let converted = Served(corrected7, range: .pq, vui: hdr10VUI, preference: .automatic,
                               display: .dolbyVision, converting: true)
        #expect(converted.declared == corrected7.convertedToProfile81)
        #expect(converted.supplemental == "dvh1.08.06/db1p")
    }

    /// A genuine P5 under a container `colr` 9/16/9 — the init in the field
    /// report, with an RPU that reads 5 — is served as P5 under either
    /// preference: stripping it would show its IPT as YCbCr.
    @Test("a confirmed Profile 5 under a YCbCr colr keeps its record and DV criteria")
    func confirmedProfile5KeepsItsRecord() {
        #expect(DolbyVisionRecordAudit.correctedRecord(p5, rpuProfile: 5, colorTransferName: "smpte2084") == nil)
        for preference in [DolbyVisionPreference.automatic, .baseLayerOnly] {
            let served = Served(p5, range: .pq, vui: hdr10VUI, preference: preference, display: .dolbyVision)
            #expect(served.declared == p5)
            #expect(!served.stripsRecord)
            #expect(served.codecs == "dvh1.05.06")
            #expect(served.supplemental == nil)
            #expect(served.criteria == .dolbyVision)
        }
    }

    @Test("a packet without a parseable RPU reads no profile")
    func unparseableRPUReadsNothing() {
        // Length-prefixed: a slice NAL, then a type-62 NAL whose body is no RPU.
        let packet: [UInt8] = [0, 0, 0, 3, 0x02, 0x01, 0xAA, 0, 0, 0, 3, 0x7C, 0x01, 0x00]
        packet.withUnsafeBufferPointer { bytes in
            #expect(DolbyVisionRecordAudit.rpuProfile(inPacket: bytes, framing: .lengthPrefixed(4)) == nil)
        }
        let noRPU: [UInt8] = [0, 0, 0, 3, 0x02, 0x01, 0xAA]
        noRPU.withUnsafeBufferPointer { bytes in
            #expect(DolbyVisionRecordAudit.rpuProfile(inPacket: bytes, framing: .lengthPrefixed(4)) == nil)
        }
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
            masterServed: true, masterDeclaresDolbyVision: true, masterIsDolbyVisionOnly: true
        ) == .mediaPlaylist)
    }

    @Test("a refused 8.x master with a DV claim drops the claim first")
    func profile8DropsTheClaim() {
        #expect(MasterRejection.fallbackTier(
            masterServed: true, masterDeclaresDolbyVision: true, masterIsDolbyVisionOnly: false
        ) == .withoutDolbyVision)
    }

    @Test("a master without a DV claim goes to the media playlist, as before")
    func noClaimGoesToMediaPlaylist() {
        #expect(MasterRejection.fallbackTier(
            masterServed: true, masterDeclaresDolbyVision: false, masterIsDolbyVisionOnly: false
        ) == .mediaPlaylist)
    }

    /// Master refused → one media-playlist fallback → that refused too: the
    /// chain ends there instead of minting the same media playlist forever.
    @Test("a refused media playlist has no fallback left")
    func mediaPlaylistEndsTheChain() {
        let first = MasterRejection.fallbackTier(
            masterServed: true, masterDeclaresDolbyVision: true, masterIsDolbyVisionOnly: true
        )
        #expect(first == .mediaPlaylist)
        // The fallback session served the media playlist, so no master.
        for (declares, dvOnly) in [(false, false), (true, true), (true, false)] {
            #expect(MasterRejection.fallbackTier(
                masterServed: false, masterDeclaresDolbyVision: declares, masterIsDolbyVisionOnly: dvOnly
            ) == nil)
        }
    }

    @Test("the end of the chain is no master rejection to classify")
    func chainEndIsNotARejection() {
        let end = PrismCoreSession.NoMasterToFallBackFrom()
        #expect(!PrismCoreSession.isMasterRejection(end))
        guard case .unknown = PrismCoreError.classify(end) else {
            Issue.record("expected .unknown")
            return
        }
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

// MARK: - The audit's reads

/// The audit against a real demuxer: where it reads from and how long it may
/// take. The fixture carries no RPU, so the answer is always `nil`; what is
/// checked is the read position and the budget.
@Suite("Record audit reads", .serialized)
struct DolbyVisionRecordAuditScanTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// The caption scout reads up to 28 video packets before the audit runs,
    /// to EOF on a short source. Without its own rewind the audit's first
    /// read returned EOF and a relabelled record stood.
    @Test("the audit reads from the head even after a scout left the input at EOF")
    func auditRewindsBeforeReading() throws {
        let url = try fixture("hevc_eac3.mkv")
        let video = try #require(try SourceProbe.open(url: url).info.video)
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let reader = try #require(packet)
        while av_read_frame(context, reader) >= 0 { av_packet_unref(reader) }

        #expect(DolbyVisionRecordAudit.scan(input: context, video: video) == nil)
        // It stopped after its eight video packets, not at EOF: it read the head.
        #expect(av_read_frame(context, reader) >= 0, "the audit read nothing: it never rewound")
        av_packet_unref(reader)
    }

    /// Behind a host's range proxy every new Range request waits for a whole
    /// forwarded bite (8 MB, over a second on a slow link), longer than the
    /// audit's budget. An audit that always rewound spent the budget on that
    /// one request, read no RPU, and served a relabelled Profile 7 Blu-ray as
    /// Profile 5 — corrupt colours on a Dolby Vision display. Mid-file, the
    /// next packets answer without a new request.
    @Test("mid-file, the audit reads on without a new Range request")
    func auditReadsForwardWithoutSeeking() async throws {
        let url = try fixture("hevc_eac3.mkv")
        let video = try #require(try SourceProbe.open(url: url).info.video)
        let server = try RangeFixtureServer(media: try Data(contentsOf: url))
        let served = try await server.start()
        defer { server.stop() }
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, served.absoluteString, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let reader = try #require(packet)
        // Where a scout leaves the session: a few packets past the head.
        for _ in 0..<4 {
            #expect(av_read_frame(context, reader) >= 0)
            av_packet_unref(reader)
        }
        let requestsBefore = server.ranges.count
        let positionBefore = avio_tell(try #require(context.pointee.pb))

        #expect(DolbyVisionRecordAudit.scan(input: context, video: video) == nil)
        #expect(server.ranges.count == requestsBefore, "the audit sought: \(server.ranges)")
        #expect(avio_tell(try #require(context.pointee.pb)) >= positionBefore, "the audit went back to the head")
    }

    @Test("a stalled source cannot hold the audit past its time budget")
    func auditIsBounded() async throws {
        let url = try fixture("hevc_eac3.mkv")
        let video = try #require(try SourceProbe.open(url: url).info.video)
        let media = try Data(contentsOf: url)
        // ~30 KB/s: the header arrives, eight HEVC packets would take seconds.
        let server = try RangeFixtureServer(media: media, bytesPerSecond: 30_000, firstByteDelay: 0)
        let served = try await server.start()
        defer { server.stop() }
        let guardian = ReadInterruptGuard()
        var input: UnsafeMutablePointer<AVFormatContext>? = guardian.makeContext()
        try FFmpegError.check(avformat_open_input(&input, served.absoluteString, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)

        let started = ContinuousClock.now
        let profile = DolbyVisionRecordAudit.scan(
            input: context, video: video, interruptGuard: guardian, timeBudget: .milliseconds(50)
        )
        let spent = ContinuousClock.now - started
        #expect(profile == nil)
        #expect(spent < .seconds(2), "audit took \(spent)")
        #expect(context.pointee.pb?.pointee.error ?? 0 >= 0, "the latched abort must be cleared")
        // Production carries on: the head rewind and a read still work.
        #expect(av_seek_frame(context, -1, 0, AVSEEK_FLAG_BACKWARD) >= 0)
        avformat_flush(context)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        #expect(av_read_frame(context, try #require(packet)) >= 0)

        // A byte budget alone also stops it, on a local file.
        var local: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&local, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&local) }
        #expect(DolbyVisionRecordAudit.scan(input: try #require(local), video: video, byteBudget: 0) == nil)
    }
}
