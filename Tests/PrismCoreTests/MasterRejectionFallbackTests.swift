import Testing
import Foundation
@testable import PrismCore

/// The tiered master-rejection fallback: a refused master that claimed Dolby
/// Vision is retried once WITHOUT the claim (same renditions, same subtitles,
/// same VIDEO-RANGE) before falling to the muxed shape; a master with no DV
/// claim to drop goes straight to muxed, exactly as the single-tier fallback
/// always did.
@Suite("Master-rejection fallback tiers")
struct MasterRejectionFallbackTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    // MARK: - The decision (pure)

    private func variant(
        dolbyVision: DolbyVisionConfiguration?,
        displayIsDolbyVisionCapable: Bool
    ) -> MasterPlaylistBuilder.VariantDescription {
        MasterPlaylistBuilder.VariantDescription(
            bandwidth: 30_000_000,
            frameRate: 23.976,
            dynamicRange: dolbyVision == nil ? .sdr : .pq,
            videoCodec: .explicit("hvc1.2.4.L153.B0"),
            dolbyVision: dolbyVision,
            displayIsDolbyVisionCapable: displayIsDolbyVisionCapable
        )
    }

    private func profile81() -> DolbyVisionConfiguration {
        DolbyVisionConfiguration(
            versionMajor: 1, versionMinor: 0, profile: 8, level: 6,
            rpuPresent: true, enhancementLayerPresent: false,
            baseLayerPresent: true, baseLayerSignalCompatibilityID: 1
        )
    }

    private func profile7() -> DolbyVisionConfiguration {
        DolbyVisionConfiguration(
            versionMajor: 1, versionMinor: 0, profile: 7, level: 6,
            rpuPresent: true, enhancementLayerPresent: true,
            baseLayerPresent: true, baseLayerSignalCompatibilityID: 0
        )
    }

    /// 8.2 — a Rec.709 base, which no Apple platform presents as DV.
    private func profile82() -> DolbyVisionConfiguration {
        DolbyVisionConfiguration(
            versionMajor: 1, versionMinor: 0, profile: 8, level: 6,
            rpuPresent: true, enhancementLayerPresent: false,
            baseLayerPresent: true, baseLayerSignalCompatibilityID: 2
        )
    }

    private func profile5() -> DolbyVisionConfiguration {
        DolbyVisionConfiguration(
            versionMajor: 1, versionMinor: 0, profile: 5, level: 6,
            rpuPresent: true, enhancementLayerPresent: false,
            baseLayerPresent: false, baseLayerSignalCompatibilityID: 0
        )
    }

    @Test("8.1 on a DV display claims DV — the tier has something to drop")
    func supplementalCountsAsClaim() {
        #expect(MasterPlaylistBuilder.declaresDolbyVision(
            variant(dolbyVision: profile81(), displayIsDolbyVisionCapable: true)
        ))
    }

    @Test("8.1 on a non-DV display claims nothing — no tier to insert")
    func clampedSupplementalIsNoClaim() {
        #expect(!MasterPlaylistBuilder.declaresDolbyVision(
            variant(dolbyVision: profile81(), displayIsDolbyVisionCapable: false)
        ))
    }

    @Test("profile 5's dvh1 primary is a claim even without a supplemental")
    func profile5PrimaryIsClaim() {
        #expect(MasterPlaylistBuilder.declaresDolbyVision(
            variant(dolbyVision: profile5(), displayIsDolbyVisionCapable: true)
        ))
    }

    @Test("no Dolby Vision, no claim")
    func plainVariantIsNoClaim() {
        #expect(!MasterPlaylistBuilder.declaresDolbyVision(
            variant(dolbyVision: nil, displayIsDolbyVisionCapable: true)
        ))
    }

    // MARK: - The other half of dropping the claim

    /// Dropping the manifest's claim is not dropping Dolby Vision: the sample
    /// entry's `dvvC` box is refused by AVPlayer's compatibility gate on its
    /// own, so a tier that re-serves it cannot win. Before this rule the
    /// DV-less retry was unwinnable by construction for every DV source — it
    /// paid a whole new session (reopen, reprobe, produce) to earn a second
    /// identical `-11868`.
    @Test("the DV-less tier strips the record, not just the claim")
    func retryStripsTheRecord() {
        #expect(HLSRemuxer.shouldStripDolbyVisionRecord(
            declared: profile81(), displayIsDolbyVisionCapable: false
        ))
    }

    @Test("a DV display keeps the record — it is what engages Dolby Vision")
    func capableDisplayKeepsTheRecord() {
        #expect(!HLSRemuxer.shouldStripDolbyVisionRecord(
            declared: profile81(), displayIsDolbyVisionCapable: true
        ))
    }

    /// P5's record is not an upgrade over a base layer, it is the description
    /// of a picture that has no base layer at all. Strip it and IPT-PQc2 is
    /// read as YCbCr — the green-and-purple misread. A non-DV display is
    /// refused a master a level up instead.
    @Test("profile 5 keeps its record on any display")
    func profile5NeverStripped() {
        #expect(!HLSRemuxer.shouldStripDolbyVisionRecord(
            declared: profile5(), displayIsDolbyVisionCapable: false
        ))
    }

    /// The case a DV-capable display used to fall straight through. A P7
    /// source that is NOT being converted (no libdovi in this build, an `hvcC`
    /// we couldn't read, no RPUs) keeps the record `avcodec_parameters_copy`
    /// brought across — so the served `hvc1` entry carried a `dvcC` announcing
    /// a dual-layer stream Apple has no decoder for, while the manifest printed
    /// no DV claim at all, because `dolbyVisionBrand` returns nil for 7. A
    /// sample entry claiming what the manifest doesn't is the same mismatch
    /// `retryStripsTheRecord` exists for.
    @Test("profile 7 is stripped even on a Dolby Vision display")
    func profile7StrippedOnCapableDisplay() {
        #expect(HLSRemuxer.shouldStripDolbyVisionRecord(
            declared: profile7(), displayIsDolbyVisionCapable: true
        ))
        #expect(HLSRemuxer.shouldStripDolbyVisionRecord(
            declared: profile7(), displayIsDolbyVisionCapable: false
        ))
    }

    /// 8.2's base is Rec.709 — plain SDR `hvc1` is the honest signaling, and
    /// the manifest already prints no claim for it. The record has to go the
    /// same way for the same reason.
    @Test("profile 8.2 is stripped even on a Dolby Vision display")
    func profile82StrippedOnCapableDisplay() {
        #expect(HLSRemuxer.shouldStripDolbyVisionRecord(
            declared: profile82(), displayIsDolbyVisionCapable: true
        ))
    }

    /// A converted P7 is declared 8.1 by then, so it takes the 8.1 path and
    /// keeps its record — the conversion is not undone by this rule.
    @Test("a converted P7 is 8.1 by the time it gets here, and keeps its record")
    func convertedProfile7KeepsItsRecord() {
        #expect(!HLSRemuxer.shouldStripDolbyVisionRecord(
            declared: profile7().convertedToProfile81, displayIsDolbyVisionCapable: true
        ))
    }

    @Test("no Dolby Vision, nothing to strip")
    func plainSourceIsUntouched() {
        #expect(!HLSRemuxer.shouldStripDolbyVisionRecord(
            declared: nil, displayIsDolbyVisionCapable: false
        ))
    }

    // MARK: - The factory (end to end, no DV claim to drop)

    @Test("a master with no DV claim falls straight to the muxed shape")
    func noClaimFallsToMuxed() async throws {
        // SDR source with a stream-copyable audio track: the session serves a
        // master (renditions shape), and that master carries no DV claim.
        let session = try PrismCoreSession(url: try fixture("hevc_eac3.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        #expect(playlist.lastPathComponent == HLSRemuxer.masterPlaylistFileName)

        let fallback = try await session.makeMasterRejectionFallbackSession()
        let fallbackPlaylist = try await fallback.start()
        defer { Task { await fallback.stop() } }
        // Muxed shape: media playlist served directly, no master on disk.
        #expect(fallbackPlaylist.lastPathComponent == HLSRemuxer.mediaPlaylistFileName)
    }
}
