import Testing
import Foundation
import Libavutil
@testable import PrismCore

/// Broadcast HLG behind an SDR VUI: the payloadType-147 read out of synthetic
/// NAL units, and the decision that turns it into a served HLG range.
@Suite("Alternative transfer SEI")
struct AlternativeTransferSEITests {

    /// An HEVC prefix SEI NAL (type 39) holding the given messages, each
    /// `(payloadType, payload)` with single-byte type and size, plus the stop bit.
    private func hevcSEI(_ messages: [(Int, [UInt8])]) -> [UInt8] {
        var rbsp: [UInt8] = []
        for (type, payload) in messages {
            rbsp += [UInt8(type), UInt8(payload.count)] + payload
        }
        return [39 << 1, 0x01] + rbsp + [0x80]
    }

    private func lengthPrefixed(_ units: [[UInt8]]) -> [UInt8] {
        units.flatMap { unit in
            [0, 0, UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit
        }
    }

    private func preferred(
        _ packet: [UInt8], _ framing: HEVCNALUnits.Framing, _ codec: HEVCNALUnits.Codec = .hevc
    ) -> Int? {
        packet.withUnsafeBufferPointer {
            AlternativeTransferSEI.preferredTransfer(inPacket: $0, framing: framing, codec: codec)
        }
    }

    /// A slice NAL (IDR_W_RADL, type 19) — not SEI, must be ignored.
    private let slice: [UInt8] = [19 << 1, 0x01, 0xAF, 0x00, 0x11]

    @Test("ARIB STD-B67 is read from a length-prefixed HEVC packet")
    func lengthPrefixedHLG() {
        let packet = lengthPrefixed([hevcSEI([(147, [18])]), slice])
        #expect(preferred(packet, .lengthPrefixed(4)) == 18)
    }

    @Test("…and from Annex B")
    func annexBHLG() {
        let packet = [0x00, 0x00, 0x00, 0x01] + hevcSEI([(147, [18])])
            + [0x00, 0x00, 0x01] + slice
        #expect(preferred(packet, .annexB) == 18)
    }

    @Test("The message is found behind other SEI messages in the same NAL")
    func behindOtherMessages() {
        // Mastering display colour volume (137) and content light level (144) first.
        let sei = hevcSEI([(137, [UInt8](repeating: 0x11, count: 24)), (144, [0x03, 0xE8, 0x01, 0x90]), (147, [18])])
        #expect(preferred(lengthPrefixed([sei]), .lengthPrefixed(4)) == 18)
    }

    @Test("Another preferred transfer is reported as itself")
    func otherTransfer() {
        // 16 = SMPTE ST 2084 (PQ).
        #expect(preferred(lengthPrefixed([hevcSEI([(147, [16])])]), .lengthPrefixed(4)) == 16)
    }

    @Test("No 147 message, no SEI, or an empty one: nil")
    func absent() {
        #expect(preferred(lengthPrefixed([hevcSEI([(144, [0x03, 0xE8, 0x01, 0x90])]), slice]), .lengthPrefixed(4)) == nil)
        #expect(preferred(lengthPrefixed([slice]), .lengthPrefixed(4)) == nil)
        #expect(preferred(lengthPrefixed([hevcSEI([(147, [])])]), .lengthPrefixed(4)) == nil)
        #expect(preferred([], .lengthPrefixed(4)) == nil)
    }

    // MARK: - The decision

    private func signals(
        _ transfer: String?, preferred: Int? = 18, probed: DynamicRange = .sdr,
        dolbyVision: DolbyVisionConfiguration? = nil
    ) -> Bool {
        AlternativeTransferSEI.signalsHLG(
            probed: probed, dolbyVision: dolbyVision,
            colorTransferName: transfer, preferredTransfer: preferred
        )
    }

    @Test("An SDR or unspecified VUI with SEI 18 is served as HLG")
    func sdrVUIWithHLGSEI() {
        for transfer in [nil, "unknown", "bt709", "bt2020-10", "bt2020-12"] {
            #expect(signals(transfer), "\(transfer ?? "nil")")
        }
    }

    /// The probe reads names from `av_color_transfer_name`; asking the linked
    /// libavutil keeps the switch honest if that spelling ever moves, rather
    /// than trusting a hard-coded guess at it.
    @Test("The unspecified transfer, as libavutil names it, counts as SDR")
    func unspecifiedTransferAsLibavutilNamesIt() {
        let name = av_color_transfer_name(AVCOL_TRC_UNSPECIFIED).map { String(cString: $0) }
        #expect(name == "unknown")
        #expect(signals(name))
        let bt709 = av_color_transfer_name(AVCOL_TRC_BT709).map { String(cString: $0) }
        #expect(signals(bt709))
    }

    @Test("Everything else keeps the probe's range")
    func otherwiseUnchanged() {
        #expect(!signals("bt709", preferred: nil))
        #expect(!signals("bt709", preferred: 16))
        // A VUI that already says PQ or HLG has answered.
        #expect(!signals("smpte2084", probed: .pq))
        #expect(!signals("arib-std-b67", probed: .hlg))
        // A transfer that is neither SDR-compatible nor unspecified.
        #expect(!signals("linear"))
        // Dolby Vision decides its range from its record.
        let profile81 = DolbyVisionConfiguration(
            versionMajor: 1, versionMinor: 0, profile: 8, level: 6,
            rpuPresent: true, enhancementLayerPresent: false,
            baseLayerPresent: true, baseLayerSignalCompatibilityID: 2
        )
        #expect(!signals("bt709", dolbyVision: profile81))
    }

    @Test func captionScoutDoesNotStopBeforeTheTransferIsSettled() {
        // Printed CC1 on a non-keyframe: the SEI could still be one IRAP away.
        #expect(!ClosedCaptionScout.isSettled(printedCC1: true, preferredTransfer: nil, sawRandomAccess: false))
        // A keyframe read without the SEI: the source has none.
        #expect(ClosedCaptionScout.isSettled(printedCC1: true, preferredTransfer: nil, sawRandomAccess: true))
        // The SEI already found.
        #expect(ClosedCaptionScout.isSettled(printedCC1: true, preferredTransfer: 18, sawRandomAccess: false))
        // Captions not settled: keep reading whatever the transfer says.
        #expect(!ClosedCaptionScout.isSettled(printedCC1: false, preferredTransfer: 18, sawRandomAccess: true))
    }
}
