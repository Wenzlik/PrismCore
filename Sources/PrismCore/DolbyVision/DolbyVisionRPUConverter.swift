import Foundation
#if canImport(Libdovi)
import Libdovi
#endif

/// Converts a Dolby Vision **Profile 7** video stream into **Profile 8.1** as it
/// is remuxed, so a dual-layer source AVPlayer has no decoder for arrives as a
/// single-layer HDR10-base stream it does.
///
/// ## What P7 actually is, and what conversion means
///
/// Profile 7 is the Blu-ray shape: an HDR10 base layer, a separate enhancement
/// layer, and an RPU written in *dual-layer* form. No Apple platform decodes the
/// enhancement layer. Profile 8.1 is the same HDR10 base with a *single-layer*
/// RPU — so the conversion is two edits and no re-encode:
///
/// 1. rewrite each RPU (NAL type 62) into its 8.1 form, and
/// 2. drop the enhancement layer, i.e. every NAL whose `nuh_layer_id` is
///    non-zero.
///
/// The base layer's picture NALs are untouched: the bits AVPlayer receives are
/// still the source's own, which is the whole premise of the remux path. What the
/// viewer loses is the enhancement layer's extra precision — which was
/// unreachable anyway, since the alternative for these files is Prism, where DV
/// dies at the door entirely.
///
/// ## Availability
///
/// libdovi does the RPU surgery — the same library mpv uses, already linked into
/// MPVKit's `_FFmpeg` target, so this adds no dependency. It is nonetheless
/// behind `canImport`: if a host builds against an MPVKit that doesn't export the
/// module, the converter reports itself unavailable and P7 sources keep routing to
/// Prism. Same discipline as `AudioBridge` and the missing `eac3` encoder — a
/// capability that can't be delivered says so rather than failing at playback.
final class DolbyVisionRPUConverter {

    /// libdovi's conversion mode 2: "convert to profile 8.1". Modes 1 (MEL),
    /// 3 (P5 → 8.1) and 4 (→ 8.4 HLG) exist and are deliberately unused — 8.1 is
    /// the one profile whose base layer Apple's stack presents natively as
    /// HDR10, which is what makes the fallback honest when DV isn't engaged.
    private static let convertToProfile81: UInt8 = 2

    /// Whether conversion can run at all in this build.
    static var isAvailable: Bool {
        #if canImport(Libdovi)
        return true
        #else
        return false
        #endif
    }

    /// NAL length prefix width, from the source's `hvcC`.
    private let lengthSize: Int

    /// Counters for the one-line summary the remuxer logs. A P7 stream whose RPUs
    /// all failed to convert is indistinguishable at playback from one that
    /// converted cleanly (both play — one as DV, one as plain HDR10), so without
    /// these the only symptom of a broken conversion is a user saying the DV logo
    /// never appeared.
    private(set) var convertedRPUs = 0
    private(set) var failedRPUs = 0
    private(set) var droppedEnhancementLayerNALs = 0

    /// - Parameter lengthSize: from `HEVCNALUnits.lengthSize(fromHVCC:)`. A
    ///   source whose record can't be read isn't convertible: without the prefix
    ///   width the packet can't be walked at all.
    init?(lengthSize: Int?) {
        guard Self.isAvailable, let lengthSize else { return nil }
        self.lengthSize = lengthSize
    }

    /// Converted packet payload, or `nil` when this packet needed no change (the
    /// caller then writes the original buffer untouched).
    func convert(packet bytes: [UInt8]) -> [UInt8]? {
        HEVCNALUnits.rewrite(bytes, lengthSize: lengthSize) { unit in
            // The enhancement layer goes first: it is the larger half of the
            // saving, and an EL NAL never carries an RPU we want.
            if unit.layerID != 0 {
                droppedEnhancementLayerNALs += 1
                return .drop
            }
            guard unit.type == 62 else { return .keep }
            guard let converted = Self.convertRPU(Array(unit.bytes)) else {
                failedRPUs += 1
                // Keep the unconverted RPU rather than dropping it. A P7 RPU in
                // a stream declared 8.1 is wrong, but the declaration is what
                // this session's master says — and `HLSRemuxer` only makes that
                // claim when conversion succeeded (see `dolbyVisionForOutput`).
                // Dropping RPUs here would instead corrupt the DV metadata of a
                // stream we may still be serving as honest P7-to-Prism.
                return .keep
            }
            convertedRPUs += 1
            return .replace(converted)
        }
    }

    /// One RPU NAL (including its two-byte HEVC header) through libdovi.
    private static func convertRPU(_ nal: [UInt8]) -> [UInt8]? {
        #if canImport(Libdovi)
        return nal.withUnsafeBufferPointer { buffer -> [UInt8]? in
            guard let base = buffer.baseAddress,
                  let rpu = dovi_parse_unspec62_nalu(base, buffer.count)
            else { return nil }
            defer { dovi_rpu_free(rpu) }

            guard dovi_convert_rpu_with_mode(rpu, convertToProfile81) == 0 else { return nil }
            guard let written = dovi_write_unspec62_nalu(rpu) else { return nil }
            defer { dovi_data_free(written) }
            guard let data = written.pointee.data, written.pointee.len > 0 else { return nil }
            return Array(UnsafeBufferPointer(start: data, count: Int(written.pointee.len)))
        }
        #else
        return nil
        #endif
    }
}

extension DolbyVisionConfiguration {

    /// The configuration a converted stream should be *declared* as: same DV
    /// level, profile 8, HDR10 base compatibility, single layer.
    ///
    /// `MasterPlaylistBuilder` reads `baseLayerSignalCompatibilityID == 1` to
    /// emit the `db1p` brand, so this is what turns a P7 source into a
    /// `SUPPLEMENTAL-CODECS="dvh1.08.<level>/db1p"` claim — the exact hand-off the
    /// builder's `dolbyVisionBrand` doc anticipated.
    var convertedToProfile81: DolbyVisionConfiguration {
        DolbyVisionConfiguration(
            versionMajor: versionMajor,
            versionMinor: versionMinor,
            profile: 8,
            level: level,
            rpuPresent: true,
            enhancementLayerPresent: false,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: 1
        )
    }
}
