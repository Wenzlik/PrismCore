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
    static let keptNALTypes: [UInt8] = [32, 33, 34]

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

    // MARK: - Patching a produced init segment

    /// Normalize the `hvcC` **inside a produced fMP4 init segment**.
    ///
    /// This exists because normalizing the source's extradata is not sufficient,
    /// which the end-to-end test found the hard way: FFmpeg's `mp4` muxer does not
    /// copy our record into the sample entry — `ff_isom_write_hvcc` *rebuilds* one
    /// from the parameter sets it collected, and writes `array_completeness = 0`
    /// while naming the entry `hvc1`. So the input-side rewrite decides which
    /// parameter sets exist (dropping SEI and RPU arrays, which do propagate) and
    /// this decides what the sample entry finally asserts about them.
    ///
    /// Returns `nil` when there is nothing to patch — no `hvcC` (H.264 sources),
    /// or a record already in form.
    static func patch(initSegment data: Data) -> Data? {
        guard let payload = locateHVCCPayload(in: data) else { return nil }
        guard let normalized = normalize(hvcC: data.subdata(in: payload)) else { return nil }
        // A length change would move every following box and invalidate the
        // enclosing `size` fields up the tree. It shouldn't happen — the arrays
        // the input-side pass drops never reach here — so the safe answer is to
        // leave the segment exactly as the muxer wrote it rather than splice a
        // tree we'd have to re-frame.
        guard normalized.count == payload.count else { return nil }
        var patched = data
        patched.replaceSubrange(payload, with: normalized)
        return patched
    }

    /// Byte range of the `hvcC` box's payload inside an ISO-BMFF tree.
    ///
    /// Descends only what leads to a sample entry, and treats an HEVC sample
    /// entry as a container whose children begin 78 bytes in (the
    /// `VisualSampleEntry` fixed fields). Not a general parser — it reads init
    /// segments this package wrote.
    private static func locateHVCCPayload(in data: Data) -> Range<Int>? {
        func walk(_ range: Range<Int>) -> Range<Int>? {
            var cursor = range.lowerBound
            while cursor + 8 <= range.upperBound {
                let size = Int(data[cursor]) << 24 | Int(data[cursor + 1]) << 16
                    | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
                let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
                // A malformed or extended-size box ends the walk: `nil` leaves
                // the segment untouched, which is always survivable.
                guard size >= 8, cursor + size <= range.upperBound else { return nil }
                let payload = (cursor + 8)..<(cursor + size)

                if type == "hvcC" { return payload }
                switch type {
                case "moov", "trak", "mdia", "minf", "stbl":
                    if let found = walk(payload) { return found }
                case "stsd":
                    // version+flags(4) + entry_count(4), then the sample entries.
                    if payload.count > 8,
                       let found = walk((payload.lowerBound + 8)..<payload.upperBound) {
                        return found
                    }
                case "hvc1", "hev1", "dvh1", "dvhe":
                    if payload.count > 78,
                       let found = walk((payload.lowerBound + 78)..<payload.upperBound) {
                        return found
                    }
                default:
                    break
                }
                cursor += size
            }
            return nil
        }
        return walk(0..<data.count)
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

// MARK: - Filling in a parameter-set-less record

extension HVCCNormalizer {

    /// Whether a record carries no parameter sets at all.
    ///
    /// Some MP4 and MPEG-TS sources ship a 23-byte `hvcC` with `numOfArrays = 0`
    /// because their VPS/SPS/PPS travel in band, with the samples. The record
    /// parses — its profile_tier_level is real, so a `CODECS` string can be
    /// derived from it — but a `hvc1` sample entry built from it promises
    /// parameter sets that aren't there, and FFmpeg writes an empty `hvcC` box
    /// besides. AVPlayer has nothing to configure a decoder from.
    static func carriesNoParameterSets(hvcC data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 23, bytes[0] == 1 else { return false }
        return bytes[22] == 0
    }

    /// Build a complete record from a parameter-set-less one plus parameter sets
    /// harvested from the bitstream.
    ///
    /// The 22-byte header is kept verbatim: it is the profile_tier_level the
    /// `CODECS` string is printed from, so filling in the arrays cannot change
    /// what the manifest already claimed.
    ///
    /// `nil` when the header can't be trusted or no SPS was harvested — a record
    /// without an SPS is no more usable than the empty one it replaces.
    static func record(
        fillingIn data: Data, withParameterSets sets: [UInt8: [[UInt8]]]
    ) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 23, bytes[0] == 1 else { return nil }
        guard sets[33]?.isEmpty == false else { return nil }

        var output = Array(bytes[0..<22])
        let present = keptNALTypes.filter { sets[$0]?.isEmpty == false }
        output.append(UInt8(present.count))
        for nalType in present {
            guard let units = sets[nalType] else { continue }
            // array_completeness = 1: this record now really does hold them all,
            // which is what `hvc1` asserts.
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

    /// Fill in the `hvcC` of a produced init segment, growing the box tree.
    ///
    /// Separate from `patch(initSegment:)` because they answer different
    /// questions: that one normalizes a record that has parameter sets, this one
    /// supplies the parameter sets a record never had.
    /// - Parameter sourceRecord: the source's own record, which donates the
    ///   22-byte profile_tier_level header. Required because FFmpeg writes an
    ///   *empty* box for a parameter-set-less record — there is no header left in
    ///   the segment to keep, and inventing one would mean inventing a profile.
    static func patch(
        initSegment data: Data,
        sourceRecord: Data,
        withParameterSets sets: [UInt8: [[UInt8]]]
    ) -> Data? {
        guard let location = ISOBMFFPatch.locate("hvcC", in: data) else { return nil }
        let existing = data.subdata(in: location.payload)
        // Only ever fills a gap: a record that already carries parameter sets is
        // `patch(initSegment:)`'s business.
        guard existing.isEmpty || carriesNoParameterSets(hvcC: existing) else { return nil }
        guard let filled = record(fillingIn: sourceRecord, withParameterSets: sets) else {
            return nil
        }
        return ISOBMFFPatch.replacePayload(at: location, in: data, with: filled)
    }
}
