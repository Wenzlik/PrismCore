import Foundation

/// Broadcast HLG that its VUI does not admit to.
///
/// HLG is backward compatible by design, and broadcast encoders lean on that:
/// the VUI (and so the container, and so `AVCodecParameters`) says BT.709 or
/// BT.2020 10-bit — an SDR transfer an SDR receiver can show as it is — while
/// an `alternative_transfer_characteristics` SEI (payloadType 147, in both
/// ITU-T H.265 and H.264) names the transfer the picture was really mastered
/// in: `preferred_transfer_characteristics` 18, ARIB STD-B67. Read from the
/// tags alone, such a source plays as flat SDR on an HDR panel.
///
/// No new reads: the remuxer's closed-caption scout already walks the SEI of
/// the first video packets (`ClosedCaptionScout`), and the message rides with
/// every random-access picture, so the first packet answers.
enum AlternativeTransferSEI {

    static let payloadType = 147
    /// `transfer_characteristics` code point for ARIB STD-B67 (HLG).
    static let aribSTDB67 = 18

    /// `preferred_transfer_characteristics` of the first payloadType-147
    /// message in one compressed video packet, or `nil`.
    static func preferredTransfer(
        inPacket bytes: UnsafeBufferPointer<UInt8>,
        framing: HEVCNALUnits.Framing,
        codec: HEVCNALUnits.Codec
    ) -> Int? {
        var found: Int?
        HEVCNALUnits.scan(bytes, framing: framing, codec: codec) { type, payload in
            guard found == nil, HEVCNALUnits.isSEI(type, codec: codec) else { return }
            HEVCNALUnits.forEachSEIMessage(inSEINAL: payload) { payloadType, message in
                guard payloadType == Self.payloadType, let preferred = message.first else { return true }
                found = Int(preferred)
                return false
            }
        }
        return found
    }

    /// Whether to serve the source as HLG on the strength of the SEI.
    ///
    /// Only over a VUI that claims an SDR transfer or none: a PQ or HLG tag is
    /// already an answer, and Dolby Vision decides its range from its record.
    /// The BT.2020 SDR transfers count, because "BT.2020 10-bit + SEI 18" is
    /// exactly how broadcast HLG is commonly signalled.
    static func signalsHLG(
        probed: DynamicRange,
        dolbyVision: DolbyVisionConfiguration?,
        colorTransferName: String?,
        preferredTransfer: Int?
    ) -> Bool {
        guard preferredTransfer == aribSTDB67, probed == .sdr, dolbyVision == nil else { return false }
        // `av_color_transfer_name` spells unspecified "unknown".
        switch colorTransferName {
        case nil, "unknown", "bt709", "bt2020-10", "bt2020-12": return true
        default: return false
        }
    }
}
