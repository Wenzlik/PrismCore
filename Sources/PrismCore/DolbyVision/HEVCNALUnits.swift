import Foundation

/// Walks and rewrites the NAL units inside a length-prefixed HEVC packet — the
/// form libavformat's mov and matroska demuxers hand us (`hvcC`-style: each NAL
/// preceded by a 1/2/4-byte big-endian length, never Annex-B start codes).
///
/// Pure and allocation-conscious: the RPU rewrite this exists for runs on **every
/// video packet** of a Profile 7 source, so the no-change path must not copy the
/// packet, and the change path must copy it exactly once.
enum HEVCNALUnits {

    /// One NAL unit, as the rewriter sees it.
    struct Unit {
        /// `nal_unit_type`: 32 VPS, 33 SPS, 34 PPS, 39/40 SEI, 62 the
        /// unspecified type Dolby Vision carries its RPU in.
        let type: UInt8
        /// `nuh_layer_id`. Non-zero is an enhancement layer — what makes a
        /// Profile 7 stream dual-layer, and what no Apple decoder will take.
        let layerID: UInt8
        /// The whole NAL unit including its two-byte header, without the length
        /// prefix. A slice into the caller's buffer: valid for the duration of
        /// the transform call only.
        let bytes: ArraySlice<UInt8>
    }

    /// `lengthSizeMinusOne + 1` out of an `hvcC` record: how many bytes each NAL
    /// length prefix occupies. Returns `nil` for a record too short to ask.
    static func lengthSize(fromHVCC data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count > 21, bytes[0] == 1 else { return nil }
        return Int(bytes[21] & 0x03) + 1
    }

    /// Every NAL unit in the packet, or `nil` if the lengths don't frame it
    /// exactly (a truncated packet, or Annex-B data misread as length-prefixed).
    ///
    /// Framing failure has to be `nil` rather than best-effort: a partially
    /// parsed packet rewritten back would splice garbage into the bitstream,
    /// where leaving the packet untouched merely leaves the RPU unconverted.
    static func units(in bytes: [UInt8], lengthSize: Int) -> [Unit]? {
        guard (1...4).contains(lengthSize) else { return nil }
        var units: [Unit] = []
        var cursor = 0
        while cursor < bytes.count {
            guard cursor + lengthSize <= bytes.count else { return nil }
            var length = 0
            for offset in 0..<lengthSize {
                length = (length << 8) | Int(bytes[cursor + offset])
            }
            cursor += lengthSize
            // A zero-length NAL is not a thing, and treating one as valid would
            // spin this loop forever.
            guard length > 1, cursor + length <= bytes.count else { return nil }
            let header0 = bytes[cursor]
            let header1 = bytes[cursor + 1]
            units.append(
                Unit(
                    type: (header0 >> 1) & 0x3F,
                    layerID: ((header0 & 0x01) << 5) | (header1 >> 3),
                    bytes: bytes[cursor..<(cursor + length)]
                )
            )
            cursor += length
        }
        return units.isEmpty ? nil : units
    }

    /// What the rewriter should do with one NAL unit.
    enum Disposition {
        case keep
        case drop
        case replace([UInt8])
    }

    /// Rebuild a packet, passing each NAL through `transform`.
    ///
    /// Returns `nil` when every unit was kept — the caller then leaves the
    /// packet's own buffer alone, which is the hot path for every packet that
    /// carries no RPU and no enhancement layer. `.keep` is deliberately a case
    /// rather than "return the same bytes": comparing a returned array against
    /// the slice would allocate once per NAL per packet to discover nothing
    /// happened.
    static func rewrite(
        _ bytes: [UInt8],
        lengthSize: Int,
        transform: (Unit) -> Disposition
    ) -> [UInt8]? {
        guard let units = units(in: bytes, lengthSize: lengthSize) else { return nil }

        var dispositions: [Disposition] = []
        dispositions.reserveCapacity(units.count)
        var changed = false
        for unit in units {
            let disposition = transform(unit)
            if case .keep = disposition {} else { changed = true }
            dispositions.append(disposition)
        }
        guard changed else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for (unit, disposition) in zip(units, dispositions) {
            let payload: ArraySlice<UInt8>
            switch disposition {
            case .keep: payload = unit.bytes
            case .drop: continue
            case .replace(let replacement):
                guard !replacement.isEmpty else { continue }
                payload = replacement[...]
            }
            for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
                output.append(UInt8((payload.count >> shift) & 0xFF))
            }
            output.append(contentsOf: payload)
        }
        return output
    }
}
