import Testing
import Foundation
@testable import PrismCore

/// What the master says about captions riding in the video's SEI. Unsaid,
/// AVPlayer finds them itself and lists them next to the WebVTT rendition the
/// engine already made of the same service — on iOS sometimes switched on.
@Suite("Closed-caption signaling", .serialized)
struct ClosedCaptionSignalingTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func variant(
        closedCaptions: [MasterPlaylistBuilder.ClosedCaptionRendition] = []
    ) -> MasterPlaylistBuilder.VariantDescription {
        MasterPlaylistBuilder.VariantDescription(
            bandwidth: 1_000_000,
            videoCodec: .explicit("avc1.640028"),
            audioRenditions: [.init(name: "English", codecString: "mp4a.40.2", uri: "audio0/index.m3u8")],
            closedCaptions: closedCaptions
        )
    }

    private func streamInf(_ master: String) throws -> String {
        try #require(master.split(separator: "\n").first { $0.hasPrefix("#EXT-X-STREAM-INF:") })
            .description
    }

    @Test("A variant that declares no captions says CLOSED-CAPTIONS=NONE")
    func noneByDefault() throws {
        let master = try MasterPlaylistBuilder.build(variant())
        #expect(try streamInf(master).hasSuffix(",CLOSED-CAPTIONS=NONE"))
        #expect(!master.contains("TYPE=CLOSED-CAPTIONS"))
    }

    @Test("Declared in-band services get a CLOSED-CAPTIONS group the variant names")
    func declaredServices() throws {
        let master = try MasterPlaylistBuilder.build(variant(closedCaptions: [
            .init(name: "English (CC1)", language: "eng", channel: 1),
            .init(name: "English (CC3)", language: "eng", channel: 3),
        ]))
        #expect(master.contains("""
        #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="English (CC1)",LANGUAGE="eng",\
        DEFAULT=NO,AUTOSELECT=NO,INSTREAM-ID="CC1"
        #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="English (CC3)",LANGUAGE="eng",\
        DEFAULT=NO,AUTOSELECT=NO,INSTREAM-ID="CC3"
        """))
        let line = try streamInf(master)
        #expect(line.hasSuffix(",CLOSED-CAPTIONS=\"cc\""))
        #expect(!line.contains("NONE"))
        // In-band services have no URI, so the readiness and segverify walk
        // must see exactly the playlists it saw before.
        #expect(PrismCoreSession.playlistURIs(inMaster: master) == ["audio0/index.m3u8", "index.m3u8"])
    }

    private func servedMaster(_ name: String, inBand: Bool) async throws -> String {
        let source = try fixture(name)
        let session = try PrismCoreSession(
            url: source,
            // hevc_captioned.mkv is PQ: without an HDR-ready display it plays
            // media-direct and there is no master to look at.
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: false),
            inBandClosedCaptions: inBand
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        #expect(playlist.lastPathComponent == HLSRemuxer.masterPlaylistFileName)
        return try String(contentsOf: playlist, encoding: .utf8)
    }

    @Test("A captioned source is served CLOSED-CAPTIONS=NONE, its WebVTT rendition kept")
    func captionedSourceHidesInBandByDefault() async throws {
        let master = try await servedMaster("hevc_captioned.mkv", inBand: false)
        #expect(try streamInf(master).contains("CLOSED-CAPTIONS=NONE"))
        #expect(!master.contains("TYPE=CLOSED-CAPTIONS"))
        #expect(master.contains("TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"CC1\""))
    }

    @Test("Opting in declares the service the scout found")
    func optInDeclaresScoutedService() async throws {
        let master = try await servedMaster("hevc_captioned.mkv", inBand: true)
        #expect(master.contains(
            "#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID=\"cc\",NAME=\"CC1\",DEFAULT=NO,AUTOSELECT=NO,INSTREAM-ID=\"CC1\""
        ))
        #expect(!master.contains("INSTREAM-ID=\"CC2\""))
        #expect(try streamInf(master).contains("CLOSED-CAPTIONS=\"cc\""))
    }

    @Test("Opting in on a source without captions still says NONE")
    func optInWithoutCaptionsSaysNone() async throws {
        let master = try await servedMaster("h264_aac.mkv", inBand: true)
        #expect(try streamInf(master).contains("CLOSED-CAPTIONS=NONE"))
        #expect(!master.contains("TYPE=CLOSED-CAPTIONS"))
    }

    @Test("A successor carries the opt-in")
    func successorCarriesOptIn() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"), inBandClosedCaptions: true)
        let successor = try await session.makeSession { $0.dialogueBoost = [] }
        let carried = await successor.options.inBandClosedCaptions
        await successor.stop()
        await session.stop()
        #expect(carried)
    }
}
