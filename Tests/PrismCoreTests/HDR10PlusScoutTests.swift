import Testing
import Foundation
import Libavformat
@testable import PrismCore

/// The HDR10+ (ST 2094-40) scout: a bounded bitstream read whose answer is
/// `seen`, `notSeenWithinBudget` or `unknown` — never "absent".
///
/// The fixtures are 10-bit PQ HEVC with a real ST 2094-40 SEI injected before
/// every picture (`Fixtures/generate_hdr10plus.sh`); FFmpeg's own decoder
/// reads them back as HDR10+ side data, which is what keeps these tests from
/// merely agreeing with the scout's reading of the syntax. They prove the
/// detection, not playback: whether AVPlayer and a panel *render* HDR10+ from
/// an HLS-fMP4 is a device question, and nothing here claims it.
@Suite("HDR10+ scout", .serialized)
struct HDR10PlusScoutTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func version(_ t35: [UInt8]) -> Int? {
        HDR10PlusScout.applicationVersion(inT35: t35[...])
    }

    private func version(
        _ packet: [UInt8], _ framing: HEVCNALUnits.Framing, _ codec: HEVCNALUnits.Codec = .hevc
    ) -> Int? {
        packet.withUnsafeBufferPointer {
            HDR10PlusScout.applicationVersion(inPacket: $0, framing: framing, codec: codec)
        }
    }

    // MARK: - The T.35 header

    @Test("Samsung's ST 2094-40 header is recognised, and nothing that merely resembles it")
    func t35Header() {
        #expect(version(FuzzSeeds.hdr10PlusT35Payload) == 1)
        #expect(version([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x00]) == 0)
        // A version this code has not read the syntax of is not called HDR10+.
        #expect(version([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x02]) == nil)
        // Same country, other providers: A/53 captions (GA94), and Dolby's
        // provider code — both ride SEI type 4 beside HDR10+ in real files.
        #expect(version([0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34, 0x03]) == nil)
        #expect(version([0xB5, 0x00, 0x3B, 0x00, 0x00, 0x08, 0x00]) == nil)
        // Samsung, but another application.
        #expect(version([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x05, 0x01]) == nil)
        // Truncated before the version byte.
        #expect(version([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]) == nil)
        #expect(version([]) == nil)
    }

    // MARK: - The packet walk

    @Test("An HDR10+ message is found behind decoy messages, in either carriage")
    func packetWalk() {
        #expect(version(FuzzSeeds.hdr10PlusAccessUnit(annexB: false), .lengthPrefixed(4)) == 1)
        #expect(version(FuzzSeeds.hdr10PlusAccessUnit(annexB: true), .annexB) == 1)
        // The same bytes read under the wrong NAL header size find no SEI:
        // the HEVC SEI type byte (0x4E) is not H.264's SEI type.
        #expect(version(FuzzSeeds.hdr10PlusAccessUnit(annexB: true), .annexB, .h264) == nil)
    }

    @Test("The message only counts inside an SEI unit, and in payload type 4")
    func onlySEIPayloadType4Counts() {
        let t35 = FuzzSeeds.hdr10PlusT35Payload
        func unit(_ header: [UInt8], _ payloadType: UInt8) -> [UInt8] {
            let body = header + [payloadType, UInt8(t35.count)] + t35 + [0x80]
            let count = body.count
            return [0, 0, UInt8(count >> 8), UInt8(count & 0xFF)] + body
        }
        // HEVC prefix and suffix SEI both carry it.
        #expect(version(unit([39 << 1, 0x01], 4), .lengthPrefixed(4)) == 1)
        #expect(version(unit([40 << 1, 0x01], 4), .lengthPrefixed(4)) == 1)
        // H.264 SEI (type 6, one-byte header).
        #expect(version(unit([0x06], 4), .lengthPrefixed(4), .h264) == 1)
        // The same bytes as user_data_unregistered (5) are not T.35 at all.
        #expect(version(unit([39 << 1, 0x01], 5), .lengthPrefixed(4)) == nil)
        // …and in a slice NAL they are picture data that happens to match.
        #expect(version(unit([0x02, 0x01], 4), .lengthPrefixed(4)) == nil)
    }

    @Test("Emulation prevention inside the message loop is removed before sizes are read")
    func emulationPreventionIsHonoured() {
        // A 3-byte registered-data message of 00 00 00, escaped on the wire as
        // 00 00 03 00, then HDR10+. Read without unescaping, the first message
        // swallows a byte of the second and the header never lines up.
        let t35 = FuzzSeeds.hdr10PlusT35Payload
        let body: [UInt8] = [39 << 1, 0x01, 0x04, 0x03, 0x00, 0x00, 0x03, 0x00]
            + [0x04, UInt8(t35.count)] + t35 + [0x80]
        let packet: [UInt8] = [0, 0, 0, UInt8(body.count)] + body
        #expect(version(packet, .lengthPrefixed(4)) == 1)
    }

    /// The caption reader moved onto the shared SEI loop; its answers must
    /// not have moved with it, and it must still ignore HDR10+'s message.
    @Test("The shared SEI loop still feeds captions, and never reads HDR10+ as one")
    func captionsUnaffected() {
        let triplets = FuzzSeeds.captionedAccessUnit.withUnsafeBufferPointer {
            A53CaptionData.triplets(in: $0, framing: .annexB, codec: .h264)
        }
        #expect(triplets.count == 6)
        let fromHDR10Plus = FuzzSeeds.hdr10PlusAccessUnit(annexB: true).withUnsafeBufferPointer {
            A53CaptionData.triplets(in: $0, framing: .annexB, codec: .hevc)
        }
        // The seed's caption decoy declares zero triplets; the HDR10+ message
        // after it must not contribute any.
        #expect(fromHDR10Plus.isEmpty)
    }

    // MARK: - Through SourceProbe

    @Test("The scan is opt-in: a default open reads no packets for it and reports nil")
    func scanIsOptIn() throws {
        let probed = try SourceProbe.open(url: try fixture("hevc_hdr10plus.mkv"))
        #expect(probed.info.hdr10Plus == nil)
        #expect(probed.timing.hdr10PlusScan == .zero)
    }

    @Test("HDR10+ is seen in length-prefixed (Matroska) carriage, on the first packet")
    func seenInMatroska() throws {
        let probed = try SourceProbe.open(url: try fixture("hevc_hdr10plus.mkv"), hdr10Plus: .standard)
        let finding = try #require(probed.info.hdr10Plus)
        #expect(finding.verdict == .seen)
        #expect(finding.isSeen)
        #expect(finding.applicationVersion == 1)
        #expect(finding.videoPacketsScanned == 1)
        #expect(finding.videoPacketBudget == 24)
        #expect(finding.streamIndex == probed.info.video?.streamIndex)
        // The rest of the description is what it always was: the scan adds a
        // finding, it does not reinterpret the stream.
        #expect(probed.info.video?.dynamicRange == .pq)
    }

    @Test("HDR10+ is seen in Annex-B (MPEG-TS) carriage")
    func seenInTransportStream() throws {
        let probed = try SourceProbe.open(url: try fixture("hevc_hdr10plus.ts"), hdr10Plus: .standard)
        #expect(probed.info.hdr10Plus?.verdict == .seen)
        #expect(probed.info.hdr10Plus?.applicationVersion == 1)
    }

    @Test("A source without HDR10+ is 'not seen within budget', having spent exactly the budget")
    func notSeenSpendsTheBudget() throws {
        for (name, budget) in [("hevc_eac3.mkv", 24), ("h264_aac.mkv", 10), ("hevc_eac3.mkv", 1)] {
            let probed = try SourceProbe.open(url: try fixture(name), hdr10Plus: .scan(videoPackets: budget))
            let finding = try #require(probed.info.hdr10Plus, "\(name)")
            #expect(finding.verdict == .notSeenWithinBudget, "\(name)")
            #expect(finding.applicationVersion == nil)
            #expect(finding.videoPacketsScanned == budget, "\(name)")
            #expect(finding.videoPacketBudget == budget)
        }
    }

    @Test("A budget longer than the stream still answers 'not seen within budget', never 'absent'")
    func shortStreamIsStillOnlyNotSeen() throws {
        let probed = try SourceProbe.open(url: try fixture("hevc_eac3.mkv"), hdr10Plus: .scan(videoPackets: 10_000))
        let finding = try #require(probed.info.hdr10Plus)
        #expect(finding.verdict == .notSeenWithinBudget)
        #expect(finding.videoPacketsScanned == 192)
    }

    @Test("A codec whose SEI the scout does not walk is 'unknown', and costs no reads")
    func unscannedCodecIsUnknown() throws {
        for name in ["av1_aac.mkv", "vp9.webm"] {
            let probed = try SourceProbe.open(url: try fixture(name), hdr10Plus: .standard)
            let finding = try #require(probed.info.hdr10Plus, "\(name)")
            #expect(finding.verdict == .unknown(.codecNotScanned), "\(name)")
            #expect(finding.videoPacketsScanned == 0)
        }
    }

    @Test("No video track, no finding")
    func audioOnlyHasNoFinding() throws {
        let probed = try SourceProbe.open(url: try fixture("audio_only_multi.mka"), hdr10Plus: .standard)
        #expect(probed.info.video == nil)
        #expect(probed.info.hdr10Plus == nil)
    }

    @Test("openDetached carries the scan through")
    func detachedCarriesTheScan() async throws {
        let probed = try await SourceProbe.openDetached(
            url: try fixture("hevc_hdr10plus.mkv"), hdr10Plus: .standard
        )
        #expect(probed.info.hdr10Plus?.verdict == .seen)
    }

    /// The scan consumes packets from the context a session then adopts. The
    /// producer must still start at the head — and the SEI the scout found
    /// must reach the served segment, because stream-copy is the whole
    /// reason HDR10+ survives at all.
    @Test("An adopted, scanned context still produces from the head, with the HDR10+ SEI intact")
    func adoptedScannedContextCarriesTheSEI() async throws {
        let source = try fixture("hevc_hdr10plus.mkv")
        let probed = try SourceProbe.open(url: source, hdr10Plus: .standard)
        #expect(probed.info.hdr10Plus?.isSeen == true)
        let session = try PrismCoreSession(
            url: source, display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: false),
            probed: probed
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        #expect(!probed.holdsContext)

        let base = playlist.deletingLastPathComponent()
        let (head, response) = try await URLSession.uncached.data(from: base.appendingPathComponent("seg00000.m4s"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let tfdt = try #require(head.range(of: Data("tfdt".utf8)))
        let decodeTime = head[tfdt.upperBound + 4 ..< tfdt.upperBound + 12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        #expect(decodeTime == 0, "head segment decode time \(decodeTime)")
        // Samsung's T.35 header, application 4 version 1 — no 00 00 pair in
        // it, so no emulation prevention can have split it on the wire.
        let header = Data([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01])
        #expect(head.range(of: header) != nil, "the HDR10+ SEI did not survive the stream-copy")
    }

    /// The contract this change keeps: detection is reporting only. The
    /// manifest a scanned source gets is byte-for-byte the one an unscanned
    /// open gets — no `VIDEO-RANGE`, `CODECS` or rendition change rides on
    /// the finding until a device run shows one helps.
    @Test("The finding changes nothing in the master playlist")
    func masterPlaylistIsUnchanged() async throws {
        let source = try fixture("hevc_hdr10plus.mkv")
        let display = DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: false)

        func master(scan: HDR10PlusScan) async throws -> String {
            let probed = try SourceProbe.open(url: source, hdr10Plus: scan)
            let session = try PrismCoreSession(url: source, display: display, probed: probed)
            let playlist = try await session.start()
            let text = try String(contentsOf: playlist, encoding: .utf8)
            await session.stop()
            return text
        }
        let scanned = try await master(scan: .standard)
        let unscanned = try await master(scan: .off)
        #expect(scanned == unscanned)
        #expect(scanned.contains("VIDEO-RANGE=PQ"))
    }
}
