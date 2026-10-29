import Testing
import Foundation
@testable import PrismCore

/// Per-frame RPU health of the Profile 7 → 8.1 conversion: every picture of a
/// stream declared 8.1 should leave with a converted RPU, after its pictures,
/// with display-management metadata — and what the conversion does to the
/// source's mapping is counted.
///
/// ffmpeg cannot synthesize an RPU, so `SyntheticRPU` writes one bit by bit from
/// the RPU syntax as FFmpeg's public decoder (`libavcodec/dovi_rpudec.c`)
/// reads it: a Profile 7 header, one-piece polynomial curves, linear-deadzone
/// NLQ, optional display-management metadata with an L1 block, CRC-32/MPEG-2.
@Suite("Dolby Vision RPU health")
struct DolbyVisionRPUHealthTests {

    @Test("A synthetic Profile 7 RPU converts; libdovi reads FEL and MEL apart")
    func syntheticRPUConverts() throws {
        guard DolbyVisionRPUConverter.isAvailable else { return }
        let fel = try #require(DolbyVisionRPUConverter.convertRPU(SyntheticRPU(fullEnhancementLayer: true).nal))
        #expect(fel.fullEnhancementLayer)
        #expect(fel.hasDisplayMetadata)
        let mel = try #require(DolbyVisionRPUConverter.convertRPU(SyntheticRPU(fullEnhancementLayer: false).nal))
        #expect(!mel.fullEnhancementLayer)
        // The output is a type-62 NAL (header 0x7C01), as the packet rewrite needs.
        #expect(Array(fel.bytes.prefix(2)) == [0x7C, 0x01])
    }

    @Test("Mode 2 replaces a real mapping with the identity, and only a real one is counted")
    func mappingReplacement() throws {
        guard DolbyVisionRPUConverter.isAvailable else { return }
        let identity = try #require(DolbyVisionRPUConverter.convertRPU(SyntheticRPU(identityMapping: true).nal))
        #expect(!identity.replacedMapping)
        let curved = try #require(DolbyVisionRPUConverter.convertRPU(SyntheticRPU(identityMapping: false).nal))
        #expect(curved.replacedMapping)
        // Both leave as the same identity-mapped 8.1 RPU: the mapping is all that differed.
        #expect(identity.bytes == curved.bytes)
    }

    @Test("Display-management metadata is carried through, and its absence counted")
    func displayMetadata() throws {
        guard DolbyVisionRPUConverter.isAvailable else { return }
        let without = try #require(DolbyVisionRPUConverter.convertRPU(SyntheticRPU(displayMetadata: false).nal))
        #expect(!without.hasDisplayMetadata)
    }

    @Test("Per packet: pictures without an RPU, RPUs ahead of their picture, and the converted RPUs' findings")
    func packetAccounting() throws {
        guard DolbyVisionRPUConverter.isAvailable else { return }
        let converter = try #require(DolbyVisionRPUConverter(lengthSize: 4))
        let picture = Self.nal(type: 1)
        let el = Self.nal(type: 63)
        let rpu = SyntheticRPU(identityMapping: false).nal

        // The shape of a P7 access unit: picture, enhancement layer, RPU last.
        let converted = try #require(converter.convert(packet: Self.packet([picture, el, rpu])))
        let units = try #require(HEVCNALUnits.units(in: converted, lengthSize: 4))
        #expect(units.map(\.type) == [1, 62])
        #expect(converter.convertedRPUs == 1 && converter.droppedEnhancementLayerNALs == 1)
        #expect(converter.picturesWithoutRPU == 0 && converter.rpusBeforePicture == 0)
        #expect(converter.mappingsReplacedByIdentity == 1 && converter.fullEnhancementLayerRPUs == 1)
        #expect(converter.rpusWithoutDisplayMetadata == 0)

        // An access unit with no RPU at all: untouched, and counted.
        #expect(converter.convert(packet: Self.packet([picture])) == nil)
        #expect(converter.picturesWithoutRPU == 1)
        // With its enhancement layer (rewritten) but still no RPU: counted too.
        #expect(converter.convert(packet: Self.packet([picture, el])) != nil)
        #expect(converter.picturesWithoutRPU == 2)
        // An RPU libdovi refuses is dropped, so its picture leaves without one.
        #expect(converter.convert(packet: Self.packet([picture, Self.nal(type: 62)])) != nil)
        #expect(converter.failedRPUs == 1 && converter.picturesWithoutRPU == 3)
        // An RPU ahead of its picture is kept where it is, and counted.
        _ = converter.convert(packet: Self.packet([rpu, picture]))
        #expect(converter.rpusBeforePicture == 1 && converter.picturesWithoutRPU == 3)
        // Parameter sets and SEI alone are no picture.
        _ = converter.convert(packet: Self.packet([Self.nal(type: 32), Self.nal(type: 39)]))
        #expect(converter.picturesWithoutRPU == 3)

        let stats = DolbyVisionConversionStats(
            convertedRPUs: converter.convertedRPUs, failedRPUs: converter.failedRPUs,
            droppedEnhancementLayerNALs: converter.droppedEnhancementLayerNALs,
            picturesWithoutRPU: converter.picturesWithoutRPU, rpusBeforePicture: converter.rpusBeforePicture
        )
        #expect(stats.picturesWithoutRPU == 3 && stats.rpusBeforePicture == 1)
    }

    @Test("The report's new counters are optional: an earlier report still decodes")
    func reportDecodesWithoutCounters() throws {
        let earlier = #"{"convertedRPUs":10,"failedRPUs":0,"droppedEnhancementLayerNALs":10,"staleUnconvertedPackets":0,"isClean":true}"#
        let decoded = try JSONDecoder().decode(
            SessionDiagnosticReport.Runtime.DolbyVisionConversion.self, from: Data(earlier.utf8)
        )
        #expect(decoded.convertedRPUs == 10 && decoded.picturesWithoutRPU == nil)
    }

    // MARK: - Packets

    private static func packet(_ units: [[UInt8]]) -> [UInt8] {
        units.flatMap { unit in
            [UInt8(unit.count >> 24 & 0xFF), UInt8(unit.count >> 16 & 0xFF), UInt8(unit.count >> 8 & 0xFF),
             UInt8(unit.count & 0xFF)] + unit
        }
    }

    private static func nal(type: UInt8) -> [UInt8] { [type << 1, 0x01, 0xAA] }
}

/// A Profile 7 RPU (`unspec62` NAL), written from the RPU syntax FFmpeg's decoder reads.
struct SyntheticRPU {
    var fullEnhancementLayer = true
    var identityMapping = false
    var displayMetadata = true

    private static let coefficientLog2Denominator = 23

    var nal: [UInt8] {
        var bits = BitWriter()
        // rpu_data_header
        bits.write(2, 6)                       // rpu_type
        bits.write(18, 11)                     // rpu_format
        bits.write(1, 4)                       // vdr_rpu_profile
        bits.write(0, 4)                       // vdr_rpu_level
        bits.write(1, 1)                       // vdr_seq_info_present
        bits.write(0, 1)                       // chroma_resampling_explicit_filter_flag
        bits.write(0, 2)                       // coefficient_data_type: fixed point
        bits.unsigned(Self.coefficientLog2Denominator)
        bits.write(1, 2)                       // vdr_rpu_normalized_idc
        bits.write(0, 1)                       // bl_video_full_range_flag
        bits.unsigned(2)                       // bl_bit_depth_minus8 (10)
        bits.unsigned(2)                       // el_bit_depth_minus8 (10)
        bits.unsigned(4)                       // vdr_bit_depth_minus8 (12)
        bits.write(0, 1)                       // spatial_resampling_filter_flag
        bits.write(0, 3)                       // reserved
        bits.write(1, 1)                       // el_spatial_resampling_filter_flag
        bits.write(0, 1)                       // disable_residual_flag
        bits.write(displayMetadata ? 1 : 0, 1) // vdr_dm_metadata_present
        bits.write(0, 1)                       // use_prev_vdr_rpu
        bits.unsigned(0)                       // vdr_rpu_id
        bits.unsigned(0)                       // mapping_color_space
        bits.unsigned(0)                       // mapping_chroma_format_idc
        for _ in 0..<3 {
            bits.unsigned(0)                   // num_pivots_minus2: one piece
            bits.write(0, 10)                  // pivot 0
            bits.write(1023, 10)               // pivot 1 (delta)
        }
        bits.write(0, 3)                       // nlq_method_idc: linear deadzone
        bits.write(0, 10)
        bits.write(1023, 10)                   // nlq pivots
        bits.unsigned(0)                       // num_x_partitions_minus1
        bits.unsigned(0)                       // num_y_partitions_minus1
        // vdr_rpu_data_payload: per component one first-order polynomial,
        // y = c0 + c1·x — the identity is (0, 1); otherwise (0, 0.5).
        for _ in 0..<3 {
            bits.unsigned(0)                   // mapping_idc: polynomial
            bits.unsigned(0)                   // poly_order_minus1
            bits.write(0, 1)                   // linear_interp_flag
            coefficient(&bits, integer: 0, fraction: 0)
            if identityMapping {
                coefficient(&bits, integer: 1, fraction: 0)
            } else {
                coefficient(&bits, integer: 0, fraction: 1 << (Self.coefficientLog2Denominator - 1))
            }
        }
        for _ in 0..<3 {
            // A minimal enhancement layer's NLQ is the neutral one (offset 0,
            // input range 1, no deadzone); a full one's is not.
            bits.write(fullEnhancementLayer ? 512 : 0, 10)   // nlq_offset
            bits.unsigned(fullEnhancementLayer ? 0 : 1)     // vdr_in_max, integer part
            bits.write(fullEnhancementLayer ? 1 << 22 : 0, Self.coefficientLog2Denominator)
            bits.unsigned(0)                                 // linear_deadzone_slope
            bits.write(fullEnhancementLayer ? 1 << 20 : 0, Self.coefficientLog2Denominator)
            bits.unsigned(0)                                 // linear_deadzone_threshold
            bits.write(0, Self.coefficientLog2Denominator)
        }
        if displayMetadata {
            bits.unsigned(0)                   // affected_dm_metadata_id
            bits.unsigned(0)                   // current_dm_metadata_id
            bits.unsigned(0)                   // scene_refresh_flag
            // BT.2020 YCbCr → RGB (×2^13), offsets (×2^28), RGB → LMS (×2^14).
            for value in [9575, 0, 14742, 9575, -1754, -5712, 9575, 17561, 0] { bits.write(UInt64(UInt16(bitPattern: Int16(value))), 16) }
            for value in [16_777_216, 134_217_728, 134_217_728] { bits.write(UInt64(value), 32) }
            for value in [7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962] { bits.write(UInt64(value), 16) }
            bits.write(65535, 16)              // signal_eotf
            bits.write(0, 16)
            bits.write(0, 16)
            bits.write(0, 32)
            bits.write(12, 5)                  // signal_bit_depth
            bits.write(0, 2)                   // signal_color_space
            bits.write(0, 2)                   // signal_chroma_format
            bits.write(1, 2)                   // signal_full_range_flag
            bits.write(62, 12)                 // source_min_pq
            bits.write(3696, 12)               // source_max_pq
            bits.write(42, 10)                 // source_diagonal
            bits.unsigned(1)                   // num_ext_blocks
            bits.align()
            bits.unsigned(5)                   // ext_block_length (bytes)
            bits.write(1, 8)                   // level 1
            bits.write(0, 12)                  // min_pq
            bits.write(2081, 12)               // max_pq
            bits.write(1229, 12)               // avg_pq
            bits.write(0, 4)                   // padding to the block length
        }
        bits.align()
        var payload = bits.bytes
        let crc = Self.crc32MPEG2(payload)
        payload += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF), 0x80]
        return [0x7C, 0x01] + Self.escaped([0x19] + payload)
    }

    /// A fixed-point coefficient: se(v) integer part, then the fraction.
    private func coefficient(_ bits: inout BitWriter, integer: Int, fraction: UInt64) {
        bits.signed(integer)
        bits.write(fraction, Self.coefficientLog2Denominator)
    }

    /// HEVC emulation prevention: 0x03 after two zero bytes when the next is ≤ 3.
    private static func escaped(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    private static func crc32MPEG2(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? crc << 1 ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }
}

private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var count = 0

    mutating func write(_ value: UInt64, _ width: Int) {
        for shift in stride(from: width - 1, through: 0, by: -1) {
            if count % 8 == 0 { bytes.append(0) }
            if value >> UInt64(shift) & 1 == 1 { bytes[bytes.count - 1] |= 0x80 >> UInt8(count % 8) }
            count += 1
        }
    }

    mutating func write(_ value: Int, _ width: Int) { write(UInt64(value), width) }

    /// ue(v)
    mutating func unsigned(_ value: Int) {
        let code = UInt64(value + 1)
        let length = 64 - code.leadingZeroBitCount
        write(0, length - 1)
        write(code, length)
    }

    /// se(v)
    mutating func signed(_ value: Int) {
        unsigned(value > 0 ? 2 * value - 1 : -2 * value)
    }

    mutating func align() {
        while count % 8 != 0 { write(0, 1) }
    }
}
