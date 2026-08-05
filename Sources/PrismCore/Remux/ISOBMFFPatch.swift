import Foundation

/// Finds a box inside a produced fMP4 init segment and replaces its payload,
/// keeping every enclosing box's size field honest.
///
/// Two patches need this — the `dec3` JOC declaration and a `hvcC` whose
/// parameter sets have to be filled in — and both grow their box, which is the
/// part that isn't a splice: an fMP4 sample entry is nested six deep
/// (`moov/trak/mdia/minf/stbl/stsd/<entry>/<config>`) and every level carries its
/// own byte count. Miss one and the tree stops parsing at the first stale length.
///
/// Deliberately not a general ISO-BMFF library: it descends only the containers
/// that lead to a sample entry, and it reads init segments this package wrote.
enum ISOBMFFPatch {

    /// Where a box is, and which boxes enclose it.
    struct Location {
        /// Offset of the box's own 4-byte size field.
        let boxStart: Int
        /// The box's payload, excluding its 8-byte header.
        let payload: Range<Int>
        /// Box-start offsets of every enclosing box, outermost first.
        let ancestorStarts: [Int]
    }

    /// Visual sample entries carry 78 bytes of fixed fields before their child
    /// boxes; audio entries carry 28.
    private static let sampleEntryHeaderLengths: [String: Int] = [
        "hvc1": 78, "hev1": 78, "dvh1": 78, "dvhe": 78, "avc1": 78,
        "ec-3": 28, "ac-3": 28, "mp4a": 28,
    ]
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    /// Locate `type`, or `nil` when the tree doesn't hold one.
    static func locate(_ type: String, in data: Data) -> Location? {
        func walk(_ range: Range<Int>, ancestors: [Int]) -> Location? {
            var cursor = range.lowerBound
            while cursor + 8 <= range.upperBound {
                let size = Int(data[cursor]) << 24 | Int(data[cursor + 1]) << 16
                    | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
                let boxType = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
                // A malformed or 64-bit-size box ends the walk: refusing to patch
                // is always survivable, guessing is not.
                guard size >= 8, cursor + size <= range.upperBound else { return nil }
                let payload = (cursor + 8)..<(cursor + size)

                if boxType == type {
                    return Location(boxStart: cursor, payload: payload, ancestorStarts: ancestors)
                }
                if containers.contains(boxType) {
                    if let found = walk(payload, ancestors: ancestors + [cursor]) { return found }
                } else if boxType == "stsd" {
                    // version+flags(4) + entry_count(4) precede the entries.
                    if payload.count > 8,
                       let found = walk(
                           (payload.lowerBound + 8)..<payload.upperBound,
                           ancestors: ancestors + [cursor]
                       ) {
                        return found
                    }
                } else if let fixed = sampleEntryHeaderLengths[boxType] {
                    if payload.count > fixed,
                       let found = walk(
                           (payload.lowerBound + fixed)..<payload.upperBound,
                           ancestors: ancestors + [cursor]
                       ) {
                        return found
                    }
                }
                cursor += size
            }
            return nil
        }
        return walk(0..<data.count, ancestors: [])
    }

    /// Replace the located box's payload, growing or shrinking every enclosing
    /// box to match.
    static func replacePayload(
        at location: Location, in data: Data, with payload: Data
    ) -> Data {
        let delta = payload.count - location.payload.count
        var patched = data
        patched.replaceSubrange(location.payload, with: payload)
        guard delta != 0 else { return patched }
        // Innermost last: each write is at a fixed offset that earlier writes
        // don't move, since every ancestor starts before this box does.
        for boxStart in location.ancestorStarts + [location.boxStart] {
            let current = Int(patched[boxStart]) << 24 | Int(patched[boxStart + 1]) << 16
                | Int(patched[boxStart + 2]) << 8 | Int(patched[boxStart + 3])
            let grown = current + delta
            patched[boxStart] = UInt8((grown >> 24) & 0xFF)
            patched[boxStart + 1] = UInt8((grown >> 16) & 0xFF)
            patched[boxStart + 2] = UInt8((grown >> 8) & 0xFF)
            patched[boxStart + 3] = UInt8(grown & 0xFF)
        }
        return patched
    }
}
