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
