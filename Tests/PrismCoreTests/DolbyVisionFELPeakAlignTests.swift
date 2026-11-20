import Testing
@testable import PrismCore

// The opt-in P7 FEL peak alignment. There is no P7 FEL fixture, and libdovi
// cannot author one, so every RPU here is assembled bit by bit by
// `SyntheticRPU` — the DM syntax in the order and widths the aligner assumes,
// with a junk "header + mapping" in front that the aligner must skip without
// parsing. A synthetic RPU proves our half (offsets, CRC, escaping, the
// rules); that the offsets match what libdovi writes is proved per RPU at run
// time, by the read-back the converter does, and needs a real disc to see.

private typealias Aligner = DolbyVisionRPUPeakAligner
private typealias DM = DolbyVisionRPUPeakAligner.DMFields

// MARK: - Synthetic RPU

private struct BitWriter {
    var bytes: [UInt8] = []
    var count = 0

    mutating func bit(_ on: Bool) {
        if count % 8 == 0 { bytes.append(0) }
        if on { bytes[count / 8] |= UInt8(0x80) >> UInt8(count % 8) }
        count += 1
    }

    mutating func put(_ value: UInt64, _ width: Int) {
        for i in stride(from: width - 1, through: 0, by: -1) { bit((value >> UInt64(i)) & 1 == 1) }
    }

    mutating func ue(_ value: UInt64) {
        let coded = value + 1
        let length = 64 - coded.leadingZeroBitCount
        put(0, length - 1)
        put(coded, length)
    }

    mutating func align() {
        while count % 8 != 0 { bit(false) }
    }
}

/// MSB-first read, independent of the aligner's `BitReader` on purpose.
private func bits(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
    (0..<width).reduce(UInt64(0)) { value, i in
        value << 1 | UInt64((bytes[(at + i) / 8] >> (7 - UInt8((at + i) % 8))) & 1)
    }
}

private struct SyntheticRPU {
    var coefficients: [Int16] = [9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0]
    var sourceMinPQ: UInt16 = 62
    var sourceMaxPQ: UInt16 = 3696
    var level1: DM.Level1? = DM.Level1(minPQ: 0, maxPQ: 3600, avgPQ: 1200)
    var level6: DM.Level6? = DM.Level6(maxMasteringNits: 4000, minMastering: 50, maxCLL: 3500, maxFALL: 400)
    var level2TargetMaxPQ: UInt16 = 2081
    var includeLevel5 = true
    var includeLevel255 = false
    /// Puts the coefficient pattern into the "mapping" too: the DM block's
    /// position is then ambiguous.
    var coefficientsAlsoInMapping = false
    static let diagonal: UInt64 = 42

    struct Built {
        var nal: [UInt8] = []
        /// Unescaped, from the 0x19 prefix to the 0x80 terminator.
        var rpu: [UInt8] = []
        var coefficientsAt = 0
        var sourceMaxAt = 0
        var diagonalAt = 0
        var level1At: Int?
        var level2At = 0
        var level6At: Int?
        var crcAt: Int { rpu.count - 5 }
    }

    /// What libdovi would report for this RPU.
    var reported: DM {
        DM(
            yccToRGB: coefficients.map { UInt16(bitPattern: $0) },
            sourceMinPQ: sourceMinPQ,
            sourceMaxPQ: sourceMaxPQ,
            level1: level1,
            level6: level6,
            untouched: [Int64(level2TargetMaxPQ), Int64(Self.diagonal)]
        )
    }

    func build() -> Built {
        var w = BitWriter()
        var b = Built()
        w.put(0x19, 8)
        w.put(0x08, 8) // header stand-in
        // Mapping stand-in, byte aligned so its `00 00 0x` runs reach the NAL
        // and have to be escaped — before and after any rewrite.
        for byte in [0x00, 0x00, 0x01, 0x5A, 0x00, 0x00, 0x00, 0x02, 0xC3] as [UInt64] { w.put(byte, 8) }
        if coefficientsAlsoInMapping {
            for c in coefficients { w.put(UInt64(UInt16(bitPattern: c)), 16) }
        }
        w.put(0b10110, 5) // the DM block off a byte boundary, as in a real RPU
        w.ue(0); w.ue(1); w.ue(0) // affected / current dm id, scene_refresh_flag
        b.coefficientsAt = w.count
        for c in coefficients { w.put(UInt64(UInt16(bitPattern: c)), 16) }
        for offset in [8_388_608, 67_108_864, 67_108_864] as [UInt64] { w.put(offset, 32) }
        for c in [7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962] as [UInt64] { w.put(c, 16) }
        w.put(65535, 16); w.put(0, 16); w.put(0, 16); w.put(0, 32) // signal_eotf, params 0–2
        w.put(12, 5); w.put(0, 2); w.put(0, 2); w.put(0, 2) // bit depth, colour space, chroma, range
        w.put(UInt64(sourceMinPQ), 12)
        b.sourceMaxAt = w.count
        w.put(UInt64(sourceMaxPQ), 12)
        b.diagonalAt = w.count
        w.put(Self.diagonal, 10)

        let blocks = (level1 == nil ? 0 : 1) + 1 + (includeLevel5 ? 1 : 0)
            + (includeLevel255 ? 1 : 0) + (level6 == nil ? 0 : 1)
        w.ue(UInt64(blocks))
        w.align()
        if let l1 = level1 {
            w.ue(5); w.put(1, 8)
            b.level1At = w.count
            w.put(UInt64(l1.minPQ), 12); w.put(UInt64(l1.maxPQ), 12); w.put(UInt64(l1.avgPQ), 12); w.put(0, 4)
        }
        w.ue(11); w.put(2, 8)
        b.level2At = w.count
        w.put(UInt64(level2TargetMaxPQ), 12)
        for _ in 0..<5 { w.put(2048, 12) }
        w.put(2048, 13); w.put(0, 3)
        if includeLevel5 {
            w.ue(7); w.put(5, 8)
            for v in [0, 0, 280, 280] as [UInt64] { w.put(v, 13) }
            w.put(0, 4)
        }
        if includeLevel255 {
            w.ue(6); w.put(255, 8)
            for _ in 0..<6 { w.put(0x11, 8) }
        }
        if let l6 = level6 {
            w.ue(8); w.put(6, 8)
            b.level6At = w.count
            for v in [l6.maxMasteringNits, l6.minMastering, l6.maxCLL, l6.maxFALL] { w.put(UInt64(v), 16) }
        }
        w.align()
        w.put(UInt64(Aligner.crc32(w.bytes[1...])), 32)
        w.put(0x80, 8)
        b.rpu = w.bytes
        b.nal = [62 << 1, 0x01] + Aligner.escape(w.bytes)
        return b
    }
}

/// Stands in for libdovi's read-back: the fields at the offsets the builder
/// recorded, or `nil` if the NAL does not parse (wrong length, bad CRC).
private func syntheticReader(_ built: SyntheticRPU.Built) -> ([UInt8]) -> DM? {
    { nal in
        guard nal.count > 2, nal[0] >> 1 == 62 else { return nil }
        let rpu = Aligner.unescape(Array(nal[2...]))
        guard rpu.count == built.rpu.count else { return nil }
        let crcAt = rpu.count - 5
        guard bits(rpu, crcAt * 8, 32) == UInt64(Aligner.crc32(rpu[1..<crcAt])) else { return nil }
        return DM(
            yccToRGB: (0..<9).map { UInt16(bits(rpu, built.coefficientsAt + 16 * $0, 16)) },
            sourceMinPQ: UInt16(bits(rpu, built.sourceMaxAt - 12, 12)),
            sourceMaxPQ: UInt16(bits(rpu, built.sourceMaxAt, 12)),
            level1: built.level1At.map {
                DM.Level1(
                    minPQ: UInt16(bits(rpu, $0, 12)),
                    maxPQ: UInt16(bits(rpu, $0 + 12, 12)),
                    avgPQ: UInt16(bits(rpu, $0 + 24, 12))
                )
            },
            level6: built.level6At.map {
                DM.Level6(
                    maxMasteringNits: UInt16(bits(rpu, $0, 16)),
                    minMastering: UInt16(bits(rpu, $0 + 16, 16)),
                    maxCLL: UInt16(bits(rpu, $0 + 32, 16)),
                    maxFALL: UInt16(bits(rpu, $0 + 48, 16))
                )
            },
            untouched: [Int64(bits(rpu, built.level2At, 12)), Int64(bits(rpu, built.diagonalAt, 10))]
        )
    }
}

/// `source` with `target`'s values written in — the RPU a correct rewrite
/// must produce, CRC and all.
private func applying(_ target: DM, to source: SyntheticRPU) -> SyntheticRPU {
    var expected = source
    expected.sourceMaxPQ = target.sourceMaxPQ
    expected.level1 = target.level1
    expected.level6 = target.level6
    return expected
}

// MARK: - The aligner, pure

@Suite("Profile 7 FEL peak alignment — aligner")
struct DolbyVisionFELPeakAlignerTests {

    @Test("CRC-32/MPEG-2 check value: poly 04C11DB7, init FFFFFFFF, no reflection, no final XOR")
    func crcKnownAnswer() {
        #expect(Aligner.crc32(Array("123456789".utf8)) == 0x0376_E6E7)
    }

    @Test("an identity rewrite reproduces the original NAL, CRC included")
    func identityRewriteReproducesCRC() throws {
        let source = SyntheticRPU()
        let built = source.build()
        let out = try #require(Aligner.rewrite(built.nal, reported: source.reported, target: source.reported))
        #expect(out == built.nal)
    }

    @Test("PQ codes round up, so a clamp never cuts below the nits asked for")
    func pqCodes() {
        #expect(Aligner.pqCode(nits: 100) == 2081)
        #expect(Aligner.pqCode(nits: 1000) == 3079)
        #expect(Aligner.pqCode(nits: 4000) == 3697)
        #expect(Aligner.pqCode(nits: 10_000) == 4095)
    }

    @Test("FEL over a 1000-nit base: source max, L1 max/avg, L6 peak and MaxCLL lowered; all else bit-identical")
    func alignsFEL() throws {
        let source = SyntheticRPU(level1: DM.Level1(minPQ: 7, maxPQ: 3600, avgPQ: 3300))
        let built = source.build()
        let target = try #require(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000))
        #expect(target.sourceMaxPQ == 3079)
        #expect(target.sourceMinPQ == 62)
        // avg follows max down; min is black level and stays.
        #expect(target.level1 == DM.Level1(minPQ: 7, maxPQ: 3079, avgPQ: 3079))
        // Mastering minimum and MaxFALL stay.
        #expect(target.level6 == DM.Level6(maxMasteringNits: 1000, minMastering: 50, maxCLL: 1000, maxFALL: 400))
        #expect(target.untouched == source.reported.untouched)

        let out = try #require(Aligner.rewrite(built.nal, reported: source.reported, target: target))
        let expected = applying(target, to: source).build()
        #expect(out == expected.nal)
        // Parses (CRC valid) and reads back as the target.
        #expect(syntheticReader(built)(out) == target)

        // Every bit that changed is inside a field the rules allow, or the CRC.
        let before = built.rpu
        let after = Aligner.unescape(Array(out[2...]))
        try #require(before.count == after.count)
        let l1 = try #require(built.level1At)
        let l6 = try #require(built.level6At)
        let allowed: [Range<Int>] = [
            built.sourceMaxAt..<(built.sourceMaxAt + 12),
            (l1 + 12)..<(l1 + 36),
            l6..<(l6 + 16),
            (l6 + 32)..<(l6 + 48),
            (built.crcAt * 8)..<(built.crcAt * 8 + 32),
        ]
        var changed = 0
        for bit in 0..<(before.count * 8) where bits(before, bit, 1) != bits(after, bit, 1) {
            changed += 1
            #expect(allowed.contains { $0.contains(bit) }, "bit \(bit) changed outside the aligned fields")
        }
        #expect(changed > 0)
    }

    @Test("values already at or below the base layer's are never raised")
    func neverRaises() throws {
        let source = SyntheticRPU(
            level1: DM.Level1(minPQ: 0, maxPQ: 2900, avgPQ: 1200),
            level6: DM.Level6(maxMasteringNits: 600, minMastering: 50, maxCLL: 800, maxFALL: 400)
        )
        let target = try #require(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000))
        #expect(target.sourceMaxPQ == 3079)
        #expect(target.level1 == source.level1)
        #expect(target.level6 == source.level6)
    }

    @Test("MEL, unknown or misspelt el_type, and out-of-range peaks are not eligible")
    func ineligible() {
        let reported = SyntheticRPU().reported
        #expect(Aligner.target(for: reported, elType: "MEL", baseLayerPeakNits: 1000) == nil)
        #expect(Aligner.target(for: reported, elType: nil, baseLayerPeakNits: 1000) == nil)
        #expect(Aligner.target(for: reported, elType: "fel", baseLayerPeakNits: 1000) == nil)
        #expect(Aligner.target(for: reported, elType: "FEL", baseLayerPeakNits: nil) == nil)
        #expect(Aligner.target(for: reported, elType: "FEL", baseLayerPeakNits: 4000) == nil)
        #expect(Aligner.target(for: reported, elType: "FEL", baseLayerPeakNits: 1000.6) == nil)
        #expect(Aligner.target(for: reported, elType: "FEL", baseLayerPeakNits: 399) == nil)
        #expect(Aligner.target(for: reported, elType: "FEL", baseLayerPeakNits: .nan) == nil)
        // The tolerance edge is in.
        #expect(Aligner.target(for: reported, elType: "FEL", baseLayerPeakNits: 1000.5) != nil)
    }

    @Test("an RPU not far above the base layer is left alone")
    func rpuPeakNotHighEnough() {
        var source = SyntheticRPU()
        source.sourceMaxPQ = 3079 // ≈ the base layer's own 1000 nit
        #expect(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000) == nil)
        source.sourceMaxPQ = Aligner.minimumSourceMaxPQ - 1
        #expect(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000) == nil)
        source.sourceMaxPQ = Aligner.minimumSourceMaxPQ
        #expect(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000) != nil)
    }

    @Test("an RPU without L1 is not a structure this recognises")
    func noLevel1() {
        let source = SyntheticRPU(level1: nil)
        #expect(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000) == nil)
    }

    @Test("a coefficient pattern found twice is ambiguous: no rewrite")
    func ambiguousPattern() throws {
        let source = SyntheticRPU(coefficientsAlsoInMapping: true)
        let built = source.build()
        let target = try #require(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000))
        #expect(Aligner.rewrite(built.nal, reported: source.reported, target: target) == nil)
    }

    @Test("any field that does not read back as reported refuses the rewrite")
    func selfValidationMismatch() throws {
        let source = SyntheticRPU()
        let built = source.build()

        var wrongMin = source.reported
        wrongMin.sourceMinPQ += 1
        var wrongAvg = source.reported
        wrongAvg.level1?.avgPQ += 1
        var wrongMaxCLL = source.reported
        wrongMaxCLL.level6?.maxCLL += 1
        // libdovi saw no L6, the bitstream walk found one.
        var noL6 = source.reported
        noL6.level6 = nil
        // Coefficients that are not in the stream at all.
        var otherCoefficients = source.reported
        otherCoefficients.yccToRGB[0] ^= 0x0100

        // Each target derives from its own (wrong) report, so the refusal is
        // `locate` reading the bitstream, not a target/report mismatch.
        for reported in [wrongMin, wrongAvg, wrongMaxCLL, noL6, otherCoefficients] {
            let target = try #require(Aligner.target(for: reported, elType: "FEL", baseLayerPeakNits: 1000))
            #expect(Aligner.rewrite(built.nal, reported: reported, target: target) == nil)
        }
    }

    @Test("a CRC that does not reproduce refuses the rewrite")
    func corruptCRC() throws {
        let source = SyntheticRPU()
        var rpu = source.build().rpu
        rpu[rpu.count - 2] ^= 0x01
        let nal: [UInt8] = [62 << 1, 0x01] + Aligner.escape(rpu)
        let target = try #require(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000))
        #expect(Aligner.rewrite(nal, reported: source.reported, target: target) == nil)
    }

    @Test("not an unspec62 NAL, or no 0x80 terminator: no rewrite")
    func notAnRPU() throws {
        let source = SyntheticRPU()
        let built = source.build()
        let target = try #require(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000))
        var wrongType = built.nal
        wrongType[0] = 63 << 1
        #expect(Aligner.rewrite(wrongType, reported: source.reported, target: target) == nil)
        var rpu = built.rpu
        rpu[rpu.count - 1] = 0x81
        #expect(Aligner.rewrite([62 << 1, 0x01] + Aligner.escape(rpu), reported: source.reported, target: target) == nil)
    }

    @Test("emulation prevention: escape and unescape are inverses on 00 00 0x runs")
    func escaping() {
        #expect(Aligner.escape([0, 0, 1]) == [0, 0, 3, 1])
        #expect(Aligner.escape([0, 0, 3]) == [0, 0, 3, 3])
        #expect(Aligner.escape([0, 0, 4]) == [0, 0, 4])
        #expect(Aligner.escape([0, 0, 0, 0, 2]) == [0, 0, 3, 0, 0, 3, 2])
        for raw: [UInt8] in [[0, 0, 1], [0, 0, 3], [0, 0, 0, 0, 2], [1, 0, 0, 0, 0, 0, 0x80]] {
            #expect(Aligner.unescape(Aligner.escape(raw)) == raw)
        }
    }

    @Test("a rewrite that creates a 00 00 0x run comes out escaped")
    func rewriteCreatesEscape() throws {
        // L1, L2, L255, L6: the headers in front of L6's payload sum to 56
        // bits, so it starts on a byte boundary and a 512-nit clamp writes
        // 02 00 | 00 00 | 02 00 | 00 00 — a run the source did not have.
        let source = SyntheticRPU(
            level6: DM.Level6(maxMasteringNits: 4000, minMastering: 0, maxCLL: 3000, maxFALL: 0),
            includeLevel5: false,
            includeLevel255: true
        )
        let built = source.build()
        let l6 = try #require(built.level6At)
        try #require(l6 % 8 == 0)
        let target = try #require(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 512))
        #expect(target.level6?.maxMasteringNits == 512)
        #expect(target.level6?.maxCLL == 512)

        let out = try #require(Aligner.rewrite(built.nal, reported: source.reported, target: target))
        let expected = applying(target, to: source).build()
        #expect(out == expected.nal)
        #expect(Aligner.unescape(Array(out[2...])) == expected.rpu)
        // One more escape byte than the source needed, and no unescaped run.
        #expect(out.count > built.nal.count)
        let body = Array(out[2...])
        for i in 0..<(body.count - 2) {
            #expect(!(body[i] == 0 && body[i + 1] == 0 && body[i + 2] <= 2), "unescaped run at \(i)")
        }
        #expect(syntheticReader(built)(out) == target)
    }
}

// MARK: - Through the converter

@Suite("Profile 7 FEL peak alignment — converter")
struct DolbyVisionFELPeakAlignConverterTests {

    private let sourceRPU: [UInt8] = [62 << 1, 0x01, 0xAA, 0xBB]
    private let el: [UInt8] = [63 << 1, 0x01, 0xCC, 0x00, 0x00, 0x03, 0x01]
    private let slice: [UInt8] = [1 << 1, 0x01, 0xDD, 0xEE]

    private func lengthPrefixed(_ units: [[UInt8]]) -> [UInt8] {
        units.flatMap { unit in
            [0, 0, UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit
        }
    }

    private var packet: [UInt8] { lengthPrefixed([sourceRPU, el, slice]) }

    /// Every NAL the injected processor and read-back were handed.
    private final class Seen {
        var processed: [[UInt8]] = []
        var read: [[UInt8]] = []
    }

    private func converter(
        converted: [UInt8],
        elType: String?,
        peak: Double?,
        aligning: Bool = true,
        seen: Seen = Seen(),
        reader: @escaping ([UInt8]) -> DM?
    ) throws -> DolbyVisionRPUConverter {
        try #require(DolbyVisionRPUConverter(
            lengthSize: 4,
            rpuProcessor: { nal in
                seen.processed.append(nal)
                return (converted, elType)
            },
            felPeakAlignment: aligning
                ? DolbyVisionRPUConverter.FELPeakAlignment(baseLayerPeakNits: peak, readFields: { nal in
                    seen.read.append(nal)
                    return reader(nal)
                })
                : nil
        ))
    }

    @Test("FEL, opted in: the RPU is aligned, the EL dropped unread, the slice untouched")
    func alignsThroughConverter() throws {
        let source = SyntheticRPU()
        let built = source.build()
        let target = try #require(Aligner.target(for: source.reported, elType: "FEL", baseLayerPeakNits: 1000))
        let expected = applying(target, to: source).build()
        let seen = Seen()
        let c = try converter(
            converted: built.nal, elType: "FEL", peak: 1000, seen: seen, reader: syntheticReader(built)
        )
        let out = c.convert(packet: packet)
        #expect(out == lengthPrefixed([expected.nal, slice]))
        #expect(c.alignedRPUs == 1)
        #expect(c.alignSkippedRPUs == 0)
        #expect(c.convertedRPUs == 1)
        #expect(c.droppedEnhancementLayerNALs == 1)
        #expect(c.felRPUs == 1)
        // Only RPUs went anywhere near the processor or the read-back: the
        // source RPU to the processor, then the converted and the patched one.
        #expect(seen.processed == [sourceRPU])
        #expect(seen.read == [built.nal, expected.nal])
        #expect(!seen.processed.contains(el) && !seen.read.contains(el))
    }

    @Test("flag off: byte-identical to the conversion without alignment, read-back never called")
    func flagOffIsByteIdentical() throws {
        let built = SyntheticRPU().build()
        let seen = Seen()
        let c = try converter(
            converted: built.nal, elType: "FEL", peak: 1000, aligning: false, seen: seen,
            reader: syntheticReader(built)
        )
        let out = c.convert(packet: packet)
        #expect(out == lengthPrefixed([built.nal, slice]))
        #expect(seen.read.isEmpty)
        #expect(c.alignedRPUs == 0)
        #expect(c.alignSkippedRPUs == 0)

        // And the same as the pre-existing two-argument seam.
        let plain = try #require(DolbyVisionRPUConverter(lengthSize: 4) { _ in (built.nal, "FEL") })
        #expect(plain.convert(packet: packet) == out)
    }

    @Test("MEL, unknown el_type, unknown or too-bright base layer, or an RPU not above it: unchanged, nothing counted")
    func ineligibleIsUnchanged() throws {
        let built = SyntheticRPU().build()
        let lowRPU = SyntheticRPU(sourceMaxPQ: 3079)
        let lowBuilt = lowRPU.build()
        let cases: [(nal: [UInt8], elType: String?, peak: Double?, reader: ([UInt8]) -> DM?)] = [
            (built.nal, "MEL", 1000, syntheticReader(built)),
            (built.nal, nil, 1000, syntheticReader(built)),
            (built.nal, "FEL", nil, syntheticReader(built)),
            (built.nal, "FEL", 4000, syntheticReader(built)),
            (lowBuilt.nal, "FEL", 1000, syntheticReader(lowBuilt)),
        ]
        for item in cases {
            let c = try converter(converted: item.nal, elType: item.elType, peak: item.peak, reader: item.reader)
            #expect(c.convert(packet: packet) == lengthPrefixed([item.nal, slice]))
            #expect(c.alignedRPUs == 0)
            #expect(c.alignSkippedRPUs == 0)
        }
    }

    @Test("read-back disagreeing with the bitstream, or the patched RPU not reading back as intended: original bytes, alignSkipped")
    func skippedKeepsConvertedBytes() throws {
        let source = SyntheticRPU()
        let built = source.build()
        let honest = syntheticReader(built)

        // libdovi "reports" a source max the bitstream does not hold.
        let lying: ([UInt8]) -> DM? = { nal in
            var fields = honest(nal)
            fields?.sourceMaxPQ += 1
            return fields
        }
        // libdovi parses the patched RPU as if nothing changed.
        let stale: ([UInt8]) -> DM? = { _ in source.reported }
        // libdovi refuses the RPU it just wrote.
        let refusing: ([UInt8]) -> DM? = { _ in nil }

        for reader in [lying, stale, refusing] {
            let c = try converter(converted: built.nal, elType: "FEL", peak: 1000, reader: reader)
            #expect(c.convert(packet: packet) == lengthPrefixed([built.nal, slice]))
            #expect(c.alignedRPUs == 0)
            #expect(c.alignSkippedRPUs == 1)
            #expect(c.convertedRPUs == 1)
        }

        // Ambiguous structure, honestly reported.
        let ambiguous = SyntheticRPU(coefficientsAlsoInMapping: true)
        let ambiguousBuilt = ambiguous.build()
        let c = try converter(
            converted: ambiguousBuilt.nal, elType: "FEL", peak: 1000, reader: syntheticReader(ambiguousBuilt)
        )
        #expect(c.convert(packet: packet) == lengthPrefixed([ambiguousBuilt.nal, slice]))
        #expect(c.alignSkippedRPUs == 1)
    }

    @Test("alignment tallies commit only with a landed packet rewrite")
    func alignmentCommitsWithRewrite() throws {
        let built = SyntheticRPU().build()
        let c = try converter(converted: built.nal, elType: "FEL", peak: 1000, reader: syntheticReader(built))
        let rewrote = packet.withUnsafeBufferPointer { buffer in
            c.convert(packet: buffer, into: { _ in nil })
        }
        #expect(!rewrote)
        #expect(c.alignedRPUs == 0)
        #expect(c.staleUnconvertedPackets == 1)
        #expect(c.convert(packet: packet) != nil)
        #expect(c.alignedRPUs == 1)
    }

    @Test("stats: new counters default to zero and change neither isClean nor the label")
    func statsCompatibility() {
        let legacy = DolbyVisionConversionStats(
            convertedRPUs: 10, failedRPUs: 0, droppedEnhancementLayerNALs: 10, felRPUs: 10
        )
        #expect(legacy.alignedRPUs == 0)
        #expect(legacy.alignSkippedRPUs == 0)
        let aligned = DolbyVisionConversionStats(
            convertedRPUs: 10, failedRPUs: 0, droppedEnhancementLayerNALs: 10, felRPUs: 10,
            alignedRPUs: 8, alignSkippedRPUs: 2
        )
        #expect(aligned.isClean == legacy.isClean)
        #expect(aligned.statsLabel == legacy.statsLabel)
        #expect(aligned.statsLabel == "P7 FEL → 8.1")
    }
}
