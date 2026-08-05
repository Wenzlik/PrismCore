import Foundation

/// Rewrites an `hvcC` record into the shape a `hvc1` sample entry has to have.
///
/// Pure bytes in, bytes out — no libavformat, no I/O — so every rule below is
/// pinned by a unit test rather than by a device.
///
/// ## Why a stream-copied `hvcC` needs normalizing at all
///
/// FFmpeg's `mp4` muxer copies HEVC extradata into the sample entry verbatim and
/// names that entry **`hvc1`**. `hvc1` and `hev1` are not interchangeable: `hvc1`
/// asserts that every parameter set lives in the sample entry and none arrives
/// in band, which is what `array_completeness=1` on each array declares. Matroska
/// `CodecPrivate` very often carries `array_completeness=0` (perfectly legal, and
/// what a `hev1` entry would want) — so a straight copy produces a `hvc1` entry
/// whose own arrays say "there may be more parameter sets in the bitstream".
/// VideoToolbox is entitled to distrust that, and the failure it produces is the
/// worst kind: not a clean rejection at parse time but an item that goes
/// `.readyToPlay` and then stalls or renders garbage on the first stream switch.
///
/// The second half is what the arrays *contain*. Records in the wild carry SEI
/// arrays (NAL types 39/40), and a Dolby Vision source can carry the RPU's
/// unspecified NAL type (62) here too. Neither belongs in a sample entry: SEI is
/// per-picture data, and an RPU in the `hvcC` is an RPU no decoder will look for.
/// Both get dropped, leaving VPS/SPS/PPS in that order — the order ISO 14496-15
/// asks for and the order every reference muxer writes.
///
/// What is deliberately **not** touched: the 22-byte header, which carries the
/// profile_tier_level the `CODECS` string is printed from. Normalizing arrays
/// cannot change the PTL, so the declaration `MasterPlaylistBuilder` derives from
/// the source record still matches the init segment byte for byte — which is the
/// property AVPlayer checks.
enum HVCCNormalizer {

    /// VPS, SPS, PPS: the only NAL types a `hvc1` sample entry carries, in the
    /// order they are written.
    private static let keptNALTypes: [UInt8] = [32, 33, 34]

    /// The fixed part of an `HEVCDecoderConfigurationRecord`: version byte,
    /// 12 PTL bytes, then the eight bytes of chroma/depth/frame-rate fields,
    /// ending at `numOfArrays` (byte 22).
    private static let headerLength = 22

    /// Returns the normalized record, or `nil` when nothing needed changing (so
    /// callers can leave the source's own extradata in place) or when the record
    /// can't be parsed with confidence.
    ///
    /// `nil` on a parse failure is the safe answer, not a silent one: refusing to
    /// rewrite bytes we don't fully understand leaves exactly the behaviour v0
    /// shipped, whereas a half-understood rewrite would corrupt the sample entry.
    static func normalize(hvcC data: Data) -> Data? {
        let bytes = [UInt8](data)
        // header + numOfArrays
        guard bytes.count > headerLength, bytes[0] == 1 else { return nil }

        let arrayCount = Int(bytes[headerLength])
        var cursor = headerLength + 1
        /// NAL type → its NAL units, in the order the record listed them.
        var arrays: [UInt8: [[UInt8]]] = [:]
        var sawIncompleteArray = false
        var sawDroppableArray = false

        for _ in 0..<arrayCount {
            guard cursor + 3 <= bytes.count else { return nil }
            let header = bytes[cursor]
            let nalType = header & 0x3F
            if header & 0x80 == 0 { sawIncompleteArray = true }
            let naluCount = Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])
            cursor += 3

            var units: [[UInt8]] = []
            for _ in 0..<naluCount {
                guard cursor + 2 <= bytes.count else { return nil }
                let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
                cursor += 2
                guard cursor + length <= bytes.count else { return nil }
                units.append(Array(bytes[cursor..<(cursor + length)]))
                cursor += length
            }

            if keptNALTypes.contains(nalType) {
                // A record that split one NAL type across two arrays is legal;
                // merging them preserves every parameter set.
                arrays[nalType, default: []].append(contentsOf: units)
            } else if !units.isEmpty {
                sawDroppableArray = true
            }
        }

        // No parameter sets at all means this isn't a record we can vouch for —
        // Annex-B extradata reaches here as garbage that happens to start with
        // a 1 byte, and `SourceProbe` already routes those media-direct.
        guard arrays[33]?.isEmpty == false else { return nil }

        let arraysAreOrdered = Self.arraysAreAlreadyOrdered(bytes: bytes, arrayCount: arrayCount)
        guard sawIncompleteArray || sawDroppableArray || !arraysAreOrdered else { return nil }

        var output = Array(bytes[0..<headerLength])
        output.append(UInt8(keptNALTypes.filter { arrays[$0]?.isEmpty == false }.count))
        for nalType in keptNALTypes {
            guard let units = arrays[nalType], !units.isEmpty else { continue }
            // array_completeness = 1: every parameter set of this type is here,
            // which is the assertion `hvc1` makes.
            output.append(0x80 | nalType)
            output.append(UInt8((units.count >> 8) & 0xFF))
            output.append(UInt8(units.count & 0xFF))
            for unit in units {
                output.append(UInt8((unit.count >> 8) & 0xFF))
                output.append(UInt8(unit.count & 0xFF))
                output.append(contentsOf: unit)
            }
        }
        return Data(output)
    }

    /// Are the record's arrays already in VPS → SPS → PPS order?
    ///
    /// Cheap re-walk of just the array headers. Worth it: the common case is a
    /// record that needs no rewrite at all, and returning `nil` there means the
    /// muxer keeps the source's own extradata pointer instead of us allocating a
    /// copy per session.
    private static func arraysAreAlreadyOrdered(bytes: [UInt8], arrayCount: Int) -> Bool {
        var cursor = headerLength + 1
        var seen: [UInt8] = []
        for _ in 0..<arrayCount {
            guard cursor + 3 <= bytes.count else { return false }
            seen.append(bytes[cursor] & 0x3F)
            let naluCount = Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])
            cursor += 3
            for _ in 0..<naluCount {
                guard cursor + 2 <= bytes.count else { return false }
                cursor += 2 + (Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1]))
            }
        }
        return seen == keptNALTypes.filter(seen.contains)
    }
}
