import Foundation

/// Lowers the peak / mastering metadata of a converted **Profile 7 FEL → 8.1**
/// RPU to what the base layer actually carries. Opt-in
/// (`PrismCoreSession.Options.alignFELDeliveryMetadata`), off by default.
///
/// ## Why
///
/// A FEL RPU describes the *reconstructed* picture: base layer plus the full
/// enhancement layer's residual, typically mastered to 4000 nit. The 8.1
/// conversion drops the EL, so what reaches the display is the base layer
/// alone — typically graded to 1000 nit — while the RPU still tells display
/// management the frame peaks at 4000. DM then tone-maps for highlights that
/// are not there, and the picture comes out darker than the base layer's own
/// HDR10 grade. Rewriting the peak fields to the base layer's is a metadata
/// edit only: the enhancement layer is never decoded or reconstructed.
///
/// ## Why only these fields, and only downwards
///
/// - `source_max_pq` and L1 `max_pq` are what DM reads as "how bright does
///   this content get"; L1 `avg_pq` is clamped only so it cannot exceed the
///   new max. L1 `min_pq` and `source_min_pq` are black level — unaffected.
/// - L6 is the HDR10 fallback (MDCV / MaxCLL); its mastering peak and MaxCLL
///   get the same clamp, MaxFALL and the mastering minimum do not.
/// - L2 / L8 trims, L5 active area, L9 / L10 / L11 and the (already no-op)
///   mapping are left alone: trims are the colourist's intent per *target*
///   display and have no base-layer equivalent to derive from.
/// - Every edit is `min(old, base-layer peak)`. Nothing is ever raised.
///
/// Nobody has measured (dEITP) that this improves the picture, and clamping
/// too low would clip highlights the base layer does carry, hence: opt-in,
/// FEL only (a MEL's base layer plus RPU already *is* the whole picture, so
/// there is nothing to correct), base layer ≤ 1000 nit, RPU ≥ 4000 nit, and
/// any doubt about the bitstream leaves the converted RPU untouched.
///
/// ## How, without a writer for these fields
///
/// libdovi (as linked) reads every DM field but can only *write* L5 and the
/// mapping, so this patches the RPU libdovi already wrote, in place, at fixed
/// bit widths. The DM block's offset is found without parsing the mapping
/// syntax ahead of it: the nine `ycc_to_rgb` coefficients libdovi reports form
/// a 144-bit pattern that must occur exactly once; every field after them up
/// to `source_diagonal` is fixed width, and the ext blocks are walked by their
/// declared lengths. Before anything is written, every value read at those
/// offsets must equal what libdovi reported — an offset that is wrong reads
/// the wrong number and the RPU is left as converted. The CRC is recomputed
/// only after the original CRC is reproduced by the same routine.
///
/// The approach (fixed-width DM patch, CRC fix-up, FEL-only gate) converges
/// with the referenční implementace's; this code is our own.
///
/// Pure and free of libdovi so it can be tested on RPUs a test assembles.
enum DolbyVisionRPUPeakAligner {

    /// The DM values this type reads, validates and may rewrite, as libdovi
    /// reports them. `untouched` is everything else libdovi reports, opaque
    /// here: it must read back identical after a rewrite.
    struct DMFields: Equatable {
        struct Level1: Equatable {
            var minPQ: UInt16
            var maxPQ: UInt16
            var avgPQ: UInt16
        }

        struct Level6: Equatable {
            var maxMasteringNits: UInt16
            var minMastering: UInt16
            var maxCLL: UInt16
            var maxFALL: UInt16
        }

        /// The nine `ycc_to_rgb_coef` values, as their 16-bit two's
        /// complement bit patterns (how the bitstream carries them).
        var yccToRGB: [UInt16]
        var sourceMinPQ: UInt16
        var sourceMaxPQ: UInt16
        var level1: Level1?
        var level6: Level6?
        var untouched: [Int64] = []
    }

    // MARK: - Eligibility and new values

    /// The base layer's MDCV peak must fall here. The top is the task's
    /// "1000 nit" with room for a rational that does not land on the integer;
    /// the bottom refuses a mastering peak too low to be a real HDR grade — a
    /// garbage MDCV would otherwise clamp every frame to near black.
    static let baseLayerPeakRange: ClosedRange<Double> = 400...1000.5

    /// 3696 is the 12-bit PQ code of 4000 nit (3999.7). Below it the RPU's
    /// peak is not far enough above any eligible base layer to be the FEL
    /// reconstruction gap this exists for — leave it alone.
    static let minimumSourceMaxPQ: UInt16 = 3696

    static func isEligibleBaseLayerPeak(_ nits: Double?) -> Bool {
        guard let nits, nits.isFinite else { return false }
        return baseLayerPeakRange.contains(nits)
    }

    /// The fields after alignment, or `nil` when this RPU is not to be touched
    /// (not FEL, base-layer peak unknown or out of range, RPU peak not high
    /// enough, no L1). `nil` is "not eligible", not a failure.
    static func target(
        for reported: DMFields, elType: String?, baseLayerPeakNits: Double?
    ) -> DMFields? {
        // Exactly the string `classify` maps to `.fel` — a MEL or unknown RPU
        // is never touched (see the type's doc).
        guard DolbyVisionRPUConverter.classify(elType: elType) == .fel,
              isEligibleBaseLayerPeak(baseLayerPeakNits),
              let peak = baseLayerPeakNits,
              reported.sourceMaxPQ >= minimumSourceMaxPQ,
              let l1 = reported.level1
        else { return nil }
        let peakPQ = pqCode(nits: peak)
        // Rounded up, like the PQ code: the clamp must never sit below the
        // base layer's own mastering peak.
        let peakNits = UInt16(peak.rounded(.up))
        var out = reported
        out.sourceMaxPQ = min(reported.sourceMaxPQ, peakPQ)
        let newMax = min(l1.maxPQ, peakPQ)
        // An L1 whose black level sits above the new peak cannot be made
        // consistent by lowering two of its three values; it is not a frame
        // this was designed for.
        guard l1.minPQ <= newMax else { return nil }
        out.level1 = DMFields.Level1(minPQ: l1.minPQ, maxPQ: newMax, avgPQ: min(l1.avgPQ, newMax))
        if var l6 = reported.level6 {
            l6.maxMasteringNits = min(l6.maxMasteringNits, peakNits)
            l6.maxCLL = min(l6.maxCLL, peakNits)
            out.level6 = l6
        }
        return out
    }

    /// SMPTE ST 2084 inverse EOTF to a 12-bit code, rounded UP so a clamp at
    /// this code never cuts below `nits`. The small epsilon keeps an exact
    /// code from being pushed one up by floating-point noise.
    static func pqCode(nits: Double) -> UInt16 {
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let y = pow(max(0, min(nits, 10_000)) / 10_000, m1)
        let v = pow((c1 + c2 * y) / (1 + c3 * y), m2)
        return UInt16(min(4095, (v * 4095 - 1e-9).rounded(.up)))
    }

    // MARK: - Rewrite

    /// `nal` — a whole unspec62 NAL as libdovi wrote it (2-byte header,
    /// escaped RPU) — with `reported`'s fields replaced by `target`'s, or
    /// `nil` when the bitstream could not be proved to hold `reported` where
    /// this expects it. `nil` means "leave it as converted".
    static func rewrite(_ nal: [UInt8], reported: DMFields, target: DMFields) -> [UInt8]? {
        guard nal.count > 2, (nal[0] >> 1) & 0x3F == 62 else { return nil }
        let escaped = Array(nal[2...])
        var rpu = unescape(escaped)
        // Our escaper must reproduce libdovi's exactly, or the bytes we did
        // not mean to touch would change form on the way out.
        guard escape(rpu) == escaped else { return nil }
        guard let layout = locate(in: rpu, reported: reported),
              target.yccToRGB == reported.yccToRGB,
              target.sourceMinPQ == reported.sourceMinPQ,
              target.untouched == reported.untouched,
              (target.level1 == nil) == (reported.level1 == nil),
              (target.level6 == nil) == (reported.level6 == nil)
        else { return nil }

        write(target.sourceMaxPQ, width: 12, at: layout.sourceMaxPQ, into: &rpu)
        if let l1 = target.level1, let at = layout.level1 {
            write(l1.maxPQ, width: 12, at: at + 12, into: &rpu)
            write(l1.avgPQ, width: 12, at: at + 24, into: &rpu)
        }
        if let l6 = target.level6, let at = layout.level6 {
            write(l6.maxMasteringNits, width: 16, at: at, into: &rpu)
            write(l6.maxCLL, width: 16, at: at + 32, into: &rpu)
        }
        let crcAt = rpu.count - 5
        let crc = crc32(rpu[1..<crcAt])
        for i in 0..<4 { rpu[crcAt + i] = UInt8(truncatingIfNeeded: crc >> (24 - 8 * i)) }
        return Array(nal[0..<2]) + escape(rpu)
    }

    /// Bit offsets (from the first byte of the unescaped RPU, the 0x19
    /// prefix) of the fields `rewrite` edits.
    struct Layout: Equatable {
        var sourceMaxPQ: Int
        /// Start of the L1 payload (`min_pq`; max at +12, avg at +24).
        var level1: Int?
        /// Start of the L6 payload (mastering max; min +16, MaxCLL +32,
        /// MaxFALL +48).
        var level6: Int?
    }

    /// Where `reported`'s fields sit in `rpu` (unescaped), or `nil` unless
    /// every one of them reads back exactly as reported.
    static func locate(in rpu: [UInt8], reported: DMFields) -> Layout? {
        // prefix(1) + at least one header byte + crc(4) + 0x80 terminator.
        guard rpu.count >= 7, rpu[0] == 0x19, rpu[rpu.count - 1] == 0x80,
              reported.yccToRGB.count == 9
        else { return nil }
        let crcAt = rpu.count - 5
        let stored = rpu[crcAt..<(crcAt + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // The proof that CRC algorithm and coverage are right: they must
        // reproduce the CRC libdovi wrote, or a rewrite would ship a CRC
        // nothing downstream accepts.
        guard crc32(rpu[1..<crcAt]) == stored else { return nil }

        var reader = BitReader(bytes: rpu, end: crcAt * 8)
        // The RPU's DM block starts at an arbitrary bit (it follows ue(v)
        // fields), so the coefficient pattern is searched at every bit.
        var pattern: [UInt8] = []
        for coef in reported.yccToRGB {
            pattern.append(UInt8(coef >> 8))
            pattern.append(UInt8(coef & 0xFF))
        }
        let matches = reader.occurrences(of: pattern, from: 8)
        guard matches.count == 1, let start = matches.first else { return nil }

        // ycc_to_rgb 9×16, ycc_to_rgb_offset 3×32, rgb_to_lms 9×16,
        // signal_eotf 16, signal_eotf_param0/1 2×16, signal_eotf_param2 32,
        // signal_bit_depth 5, signal_color_space 2, signal_chroma_format 2,
        // signal_full_range_flag 2 — the widths libdovi's `DoviVdrDmData`
        // types and the public DM syntax give.
        let sourceMinAt = start + 144 + 96 + 144 + 16 + 32 + 32 + 5 + 2 + 2 + 2
        reader.position = sourceMinAt
        guard reader.read(12) == UInt64(reported.sourceMinPQ),
              reader.read(12) == UInt64(reported.sourceMaxPQ),
              reader.read(10) != nil, // source_diagonal
              let blockCount = reader.readUE()
        else { return nil }

        var layout = Layout(sourceMaxPQ: sourceMinAt + 12)
        if blockCount > 0 {
            // dm_alignment_zero_bit: zeros up to the next byte boundary.
            while reader.position % 8 != 0 {
                guard reader.read(1) == 0 else { return nil }
            }
            // A real RPU carries a handful; this bound only keeps a corrupt
            // ue(v) from turning into a long walk.
            guard blockCount <= 64 else { return nil }
            for _ in 0..<blockCount {
                guard let length = reader.readUE(), let level = reader.read(8),
                      length <= 1024
                else { return nil }
                let payload = reader.position
                let end = payload + Int(length) * 8
                guard end <= reader.end else { return nil }
                switch level {
                case 1:
                    // A second L1 would make "the" L1 ambiguous.
                    guard length >= 5, layout.level1 == nil else { return nil }
                    layout.level1 = payload
                case 6:
                    guard length >= 8, layout.level6 == nil else { return nil }
                    layout.level6 = payload
                default:
                    break
                }
                reader.position = end
            }
        }

        // Every value at the computed offsets must be libdovi's, field for
        // field — including presence: a block libdovi saw and we did not (it
        // sits in the CM v4.0 list we do not walk, say) is a skip.
        guard (layout.level1 == nil) == (reported.level1 == nil),
              (layout.level6 == nil) == (reported.level6 == nil)
        else { return nil }
        if let at = layout.level1, let l1 = reported.level1 {
            reader.position = at
            guard reader.read(12) == UInt64(l1.minPQ),
                  reader.read(12) == UInt64(l1.maxPQ),
                  reader.read(12) == UInt64(l1.avgPQ)
            else { return nil }
        }
        if let at = layout.level6, let l6 = reported.level6 {
            reader.position = at
            guard reader.read(16) == UInt64(l6.maxMasteringNits),
                  reader.read(16) == UInt64(l6.minMastering),
                  reader.read(16) == UInt64(l6.maxCLL),
                  reader.read(16) == UInt64(l6.maxFALL)
            else { return nil }
        }
        return layout
    }

    // MARK: - Bitstream primitives

    /// MSB-first reader over `bytes`, refusing to read past `end` (a bit
    /// offset — the CRC, which no field may run into).
    struct BitReader {
        let bytes: [UInt8]
        let end: Int
        var position = 0

        init(bytes: [UInt8], end: Int) {
            self.bytes = bytes
            self.end = min(end, bytes.count * 8)
        }

        func bit(at index: Int) -> UInt8 {
            (bytes[index >> 3] >> (7 - UInt8(index & 7))) & 1
        }

        mutating func read(_ width: Int) -> UInt64? {
            guard width <= 64, position + width <= end else { return nil }
            var value: UInt64 = 0
            for i in 0..<width { value = value << 1 | UInt64(bit(at: position + i)) }
            position += width
            return value
        }

        /// Exp-Golomb ue(v). More than 31 leading zeros is not a value any
        /// RPU field holds.
        mutating func readUE() -> UInt64? {
            var zeros = 0
            while true {
                guard let b = read(1) else { return nil }
                if b == 1 { break }
                zeros += 1
                guard zeros <= 31 else { return nil }
            }
            guard let suffix = read(zeros) else { return nil }
            return (UInt64(1) << UInt64(zeros)) - 1 + suffix
        }

        /// Every bit offset ≥ `from` at which `pattern`'s bits begin and end
        /// before `end`.
        func occurrences(of pattern: [UInt8], from start: Int) -> [Int] {
            let width = pattern.count * 8
            guard width > 0, start + width <= end else { return [] }
            var found: [Int] = []
            for offset in start...(end - width) {
                var matched = true
                for i in 0..<width where bit(at: offset + i) != (pattern[i >> 3] >> (7 - UInt8(i & 7))) & 1 {
                    matched = false
                    break
                }
                if matched { found.append(offset) }
            }
            return found
        }
    }

    /// Writes the low `width` bits of `value` MSB-first at bit `offset`,
    /// leaving every other bit as it was.
    static func write(_ value: UInt16, width: Int, at offset: Int, into bytes: inout [UInt8]) {
        for i in 0..<width {
            let bit = UInt8((value >> UInt16(width - 1 - i)) & 1)
            let index = offset + i
            let mask = UInt8(0x80) >> UInt8(index & 7)
            bytes[index >> 3] = bit == 1 ? bytes[index >> 3] | mask : bytes[index >> 3] & ~mask
        }
    }

    /// HEVC emulation prevention: `00 00 0x` (x ≤ 3) becomes `00 00 03 0x`.
    static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 64)
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

    /// Inverse of `escape`: every `03` that follows `00 00` is dropped.
    static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// CRC-32/MPEG-2 (poly 0x04C11DB7, init 0xFFFFFFFF, no reflection, no
    /// final XOR) — the RPU's `rpu_data_crc32`, over the RPU from after the
    /// 0x19 prefix up to the CRC. `locate` proves both choices on every RPU
    /// before trusting them.
    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }
}
