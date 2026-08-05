import Foundation

/// Reads the **JOC (Dolby Atmos) signal** out of an E-AC-3 syncframe.
///
/// ## Why this has to exist
///
/// AVFoundation engages the Dolby/MAT pipeline only when the `dec3` box declares
/// the TS 103 420 type-A extension. FFmpeg's mp4 muxer does not carry that
/// declaration through a stream copy — verified against plain `ffmpeg -c copy`,
/// which produces the same extension-less six-byte box — so an Atmos track
/// remuxed by anyone's FFmpeg plays as plain Dolby Digital Plus. The objects are
/// still in the elementary stream; nothing tells the system so.
///
/// Which means PrismCore has to read the signal itself. It lives in the
/// bitstream's `addbsi` field, at the end of the BSI, and getting there means
/// walking every optional field in between — there is no shortcut, because each
/// field's presence depends on the ones before it.
///
/// ## Provenance
///
/// The walk below is ported from Aether's own Matroska remuxer
/// (`AetherCore/Playback/Remux/AudioBitstreamConfig.swift`), which had to solve
/// exactly this problem and had already paid for the knowledge on a device. Field
/// order and widths follow FFmpeg's `eac3_parse_header` (`ac3_parser.c`) for the
/// cases this scope reaches: `strmtyp == 0` and `fscod != 3`.
///
/// Best-effort by design: any truncated or unexpected field reads as "no
/// extension", so a frame this can't fully walk leaves the output exactly as
/// FFmpeg wrote it rather than inventing a declaration.
enum EAC3Syncframe {

    /// `complexity_index_type_a` when this frame carries the TS 103 420 type-A
    /// (JOC / Atmos) extension; `nil` for plain (E-)AC-3, and for anything the
    /// walk can't follow.
    ///
    /// - Parameter bytes: one demuxed E-AC-3 packet. The syncframe is expected at
    ///   the start, which is what libavformat delivers for a stream-copied track.
    static func atmosComplexityIndex(in bytes: [UInt8]) -> Int? {
        // A packet is not one frame. Blu-ray-style Dolby Digital Plus carries an
        // AC-3 core frame first (bsid 6, and its bytes 2–3 are a CRC that reads
        // as nonsense `strmtyp`/`substreamid` if you assume E-AC-3), with the
        // E-AC-3 substreams after it — and the JOC signal lives in the
        // *independent* E-AC-3 substream's `addbsi`. Parsing offset zero and
        // giving up, which is what a single-frame reader does, finds nothing on
        // such a source.
        //
        // So scan for a syncword that really does open an independent E-AC-3
        // substream. False syncs are cheap to reject: the walk only returns a
        // value when it lands on `addbsie` with the type-A flag set, which random
        // payload bytes essentially never do.
        var offset = 0
        let limit = min(bytes.count, Self.scanLimit)
        while offset + 6 < limit {
            guard bytes[offset] == 0x0B, bytes[offset + 1] == 0x77 else {
                offset += 1
                continue
            }
            if let index = atmosComplexityIndex(inFrameAt: offset, of: bytes) { return index }
            offset += 2
        }
        return nil
    }

    /// How far into a packet to look. A Blu-ray DD+ packet is a few KB and the
    /// independent substream sits near its front; scanning further would be
    /// paying per packet for nothing.
    private static let scanLimit = 65_536

    /// The walk, assuming a syncframe starts exactly at `offset`.
    private static func atmosComplexityIndex(inFrameAt offset: Int, of bytes: [UInt8]) -> Int? {
        var reader = BitReader(bytes, startingAtByte: offset)

        guard reader.read(16) == 0x0B77 else { return nil }   // syncword
        // Independent (0) and dependent (1) substreams both carry the signal.
        // Dolby's Blu-ray-style DD+ carriage puts JOC in the DEPENDENT substream,
        // which is why restricting to 0 — as a single-frame reader does — finds
        // nothing on such a source.
        guard let streamType = reader.read(2), streamType <= 1 else { return nil }
        _ = reader.read(3)                                    // substreamid
        guard reader.read(11) != nil else { return nil }       // frmsiz
        guard let fscod = reader.read(2), fscod != 3 else { return nil }
        guard let numblkscod = reader.read(2) else { return nil }
        guard let acmod = reader.read(3), let lfeon = reader.read(1) else { return nil }
        guard let bsid = reader.read(5), bsid > 10, bsid <= 16 else { return nil }

        let numblks = [1, 2, 3, 6][numblkscod]
        return extensionTypeA(
            &reader, acmod: acmod, lfeon: lfeon, numblks: numblks, isDependent: streamType == 1
        )
    }

    /// The BSI walk from just past `bsid` to `addbsi`.
    private static func extensionTypeA(
        _ reader: inout BitReader, acmod: Int, lfeon: Int, numblks: Int, isDependent: Bool
    ) -> Int? {
        // Volume control, once per programme (twice for dual mono, acmod 0).
        for _ in 0..<(acmod == 0 ? 2 : 1) {
            guard reader.skip(5) else { return nil }                          // dialnorm
            if reader.read(1) == 1 { guard reader.skip(8) else { return nil } } // compr
        }

        // A dependent substream declares which channels it carries, and the field
        // only exists there. Skipping it would misalign every optional field that
        // follows — the walk might still land on something that looks like
        // `addbsi`, which is the worst kind of wrong.
        if isDependent, reader.read(1) == 1 {
            guard reader.skip(16) else { return nil }                          // chanmap
        }

        // Mixing metadata.
        if reader.read(1) == 1 {
            if acmod > 2 {
                guard reader.skip(2) else { return nil }                       // dmixmod
                if acmod & 1 != 0 { guard reader.skip(6) else { return nil } }  // c mix levels
                if acmod & 4 != 0 { guard reader.skip(6) else { return nil } }  // sur mix levels
            }
            if lfeon == 1, reader.read(1) == 1 {
                guard reader.skip(5) else { return nil }                       // lfemixlevcod
            }
            // strmtyp == 0: mixing info for downstream mixers.
            for _ in 0..<(acmod == 0 ? 2 : 1) {
                if reader.read(1) == 1 { guard reader.skip(6) else { return nil } }  // pgmscl
            }
            if reader.read(1) == 1 { guard reader.skip(6) else { return nil } }      // extpgmscl
            switch reader.read(2) {                                           // mixdef
            case 1: guard reader.skip(5) else { return nil }
            case 2: guard reader.skip(12) else { return nil }
            case 3:
                guard let mixdeflen = reader.read(5),
                      reader.skip((mixdeflen + 2) * 8) else { return nil }
            default: break
            }
            if acmod < 2 {                                                    // pan info
                for _ in 0..<(acmod == 0 ? 2 : 1) {
                    if reader.read(1) == 1 { guard reader.skip(14) else { return nil } }
                }
            }
            if reader.read(1) == 1 {                                          // frmmixcfginfoe
                if numblks == 1 {
                    guard reader.skip(5) else { return nil }
                } else {
                    for _ in 0..<numblks {
                        if reader.read(1) == 1 { guard reader.skip(5) else { return nil } }
                    }
                }
            }
        }

        // Informational metadata.
        if reader.read(1) == 1 {
            guard reader.skip(5) else { return nil }             // bsmod + copyrightb + origbs
            if acmod == 2 { guard reader.skip(4) else { return nil } }   // dsurmod/dheadphonmod
            if acmod >= 6 { guard reader.skip(2) else { return nil } }   // dsurexmod
            for _ in 0..<(acmod == 0 ? 2 : 1) {
                if reader.read(1) == 1 { guard reader.skip(8) else { return nil } }  // audprodinfo
            }
            guard reader.skip(1) else { return nil }             // sourcefscod (fscod != 3)
        }

        // Converter sync flag, on independent streams shorter than six blocks.
        if numblks != 6 { guard reader.skip(1) else { return nil } }

        // addbsi: first byte is reserved(7) + flag_ec3_extension_type_a(1),
        // second is complexity_index_type_a.
        guard reader.read(1) == 1,                              // addbsie
              let addbsil = reader.read(6), addbsil >= 1,        // ≥ 2 addbsi bytes
              reader.skip(7),
              reader.read(1) == 1                               // flag_ec3_extension_type_a
        else { return nil }
        return reader.read(8)                                   // complexity_index_type_a
    }

    /// MSB-first bit reader. `read` returns `nil` and `skip` returns `false` past
    /// the end, so every optional field either advances honestly or aborts the
    /// walk — a walk that guessed would produce a wrong complexity index, which
    /// is worse than no declaration.
    private struct BitReader {
        private let bytes: [UInt8]
        private var bitPosition = 0

        init(_ bytes: [UInt8], startingAtByte offset: Int = 0) {
            self.bytes = bytes
            bitPosition = offset * 8
        }

        mutating func read(_ count: Int) -> Int? {
            guard count > 0, count <= 32, bitPosition + count <= bytes.count * 8 else {
                return nil
            }
            var value = 0
            for _ in 0..<count {
                let byte = bytes[bitPosition >> 3]
                value = (value << 1) | ((Int(byte) >> (7 - (bitPosition & 7))) & 1)
                bitPosition += 1
            }
            return value
        }

        /// Advance without materialising a value — `mixdef` case 3 can span 264
        /// bits, which would overflow `read`'s accumulator.
        mutating func skip(_ count: Int) -> Bool {
            guard bitPosition + count <= bytes.count * 8 else { return false }
            bitPosition += count
            return true
        }
    }
}
