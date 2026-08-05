import Foundation

/// The `dec3` box (`EC3SpecificBox`, ETSI TS 102 366 Annex F) as it ends up in a
/// produced init segment — parsed back out so we can check what we actually
/// served.
///
/// ## Why this exists
///
/// `CHANNELS="16/JOC"` in the master playlist is how a *rendition* is advertised
/// as Atmos, and it is necessary — but it is not what engages Atmos. AVFoundation
/// only takes the Dolby/MAT route when the **`dec3` box** carries the TS 103 420
/// type-A extension (`flag_ec3_extension_type_a` plus
/// `complexity_index_type_a`); without it the same bitstream plays as plain
/// Dolby Digital Plus. That is a device finding, not a reading of the spec — it
/// cost Aether a debugging round in its own remuxer (#976 step-0), and the same
/// trap is waiting for anyone who assumes the playlist attribute is the whole
/// story.
///
/// PrismCore doesn't write the box — FFmpeg's `movenc` does, from frames it
/// accumulates while muxing. That should carry the extension through a
/// stream-copy, but "should" is doing a lot of work: the moov is written under
/// `delay_moov` after only the first few frames, which is exactly the window in
/// which a frame-accumulating writer can come up short. So rather than trust it,
/// this makes the served bytes inspectable.
///
/// Deliberately a reader, not a writer: PrismCore's premise is that the source's
/// own bits reach the player untouched, and an audio config we synthesized would
/// be a claim about a bitstream we didn't parse.
struct EAC3Configuration: Equatable {

    /// `data_rate`, in kbit/s, as the box declares it.
    let dataRate: Int
    /// Number of independent substreams the box describes.
    let independentSubstreamCount: Int
    /// `acmod` of the first independent substream.
    let acmod: Int
    /// `lfeon` of the first independent substream.
    let hasLFE: Bool
    /// `complexity_index_type_a` when the box carries the TS 103 420 type-A
    /// extension — i.e. when this is Atmos as far as AVFoundation is concerned.
    /// `nil` means the box describes plain (E-)AC-3.
    let atmosComplexityIndex: Int?

    /// Whether AVFoundation will engage the Dolby/MAT pipeline for this box.
    var declaresAtmos: Bool { atmosComplexityIndex != nil }

    /// Channel count from `acmod` + `lfeon` (TS 102 366 Table 5.8) — the bed,
    /// not the object count, so an Atmos track reads 6 here. This is exactly why
    /// HLS needs the separate `16/JOC` form.
    var channelCount: Int {
        let perACMOD = [2, 1, 2, 3, 3, 4, 4, 5]
        guard acmod >= 0, acmod < perACMOD.count else { return 0 }
        return perACMOD[acmod] + (hasLFE ? 1 : 0)
    }

    /// Parse a `dec3` payload (box header already stripped).
    ///
    /// `nil` when the payload is too short to frame the fields — a box we can't
    /// read is reported as unreadable rather than as "no Atmos", because those
    /// two answers lead somewhere very different.
    static func parse(dec3 payload: [UInt8]) -> EAC3Configuration? {
        var reader = BitReader(payload)
        guard let dataRate = reader.read(13),
              let substreamsMinusOne = reader.read(3)
        else { return nil }

        // Only the first independent substream is read: the box lists them in
        // order and PrismCore's renditions carry one apiece.
        guard let fscod = reader.read(2), fscod <= 3,
              reader.read(5) != nil,          // bsid
              reader.read(1) != nil,          // reserved
              reader.read(1) != nil,          // asvc
              reader.read(3) != nil,          // bsmod
              let acmod = reader.read(3),
              let lfeon = reader.read(1),
              reader.read(3) != nil,          // reserved
              let dependentSubstreams = reader.read(4)
        else { return nil }

        // A substream with no dependents carries one reserved bit in its place;
        // with dependents it carries the 9-bit chan_loc instead.
        if dependentSubstreams == 0 {
            guard reader.read(1) != nil else { return nil }
        } else {
            guard reader.read(9) != nil else { return nil }
        }

        // The type-A extension is optional and sits at the tail. Absent bits are
        // "no extension" — a plain DD+ box simply ends here.
        var complexityIndex: Int?
        if let reserved = reader.read(7), reserved >= 0,
           let flag = reader.read(1), flag == 1,
           let index = reader.read(8) {
            complexityIndex = index
        }

        return EAC3Configuration(
            dataRate: dataRate,
            independentSubstreamCount: substreamsMinusOne + 1,
            acmod: acmod,
            hasLFE: lfeon == 1,
            atmosComplexityIndex: complexityIndex
        )
    }

    /// Most-significant-bit-first bit reader over a byte buffer. Returns `nil`
    /// past the end rather than zero-filling: for the extension tail, "ran out of
    /// bits" and "the flag is zero" have to stay distinguishable.
    private struct BitReader {
        private let bytes: [UInt8]
        private var bitOffset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func read(_ count: Int) -> Int? {
            guard count > 0, count <= 32, bitOffset + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                let byte = bytes[bitOffset >> 3]
                let bit = (byte >> (7 - UInt8(bitOffset & 7))) & 1
                value = (value << 1) | Int(bit)
                bitOffset += 1
            }
            return value
        }
    }
}

// MARK: - Patching a produced init segment

extension EAC3Configuration {

    /// Add the TS 103 420 type-A (JOC / Atmos) declaration to the `dec3` box of a
    /// produced fMP4 init segment.
    ///
    /// Returns `nil` when there is nothing to do — no `dec3`, or a box that
    /// already declares the extension — so the caller keeps the muxer's bytes.
    ///
    /// The tail is two bytes: `reserved(7) + flag_ec3_extension_type_a(1)` then
    /// `complexity_index_type_a(8)`. Two bytes that a box tree has to be told
    /// about, which is the whole reason this isn't a one-line splice: every
    /// ancestor's `size` field has to grow with it, or the tree stops parsing at
    /// the first stale length.
    static func patch(initSegment data: Data, atmosComplexityIndex index: Int) -> Data? {
        guard (0...255).contains(index) else { return nil }
        guard let located = locateDec3(in: data) else { return nil }

        // Already declared: leave it be. This is what makes the patch idempotent
        // and what will make it a no-op if FFmpeg ever starts carrying the
        // extension itself.
        if let existing = parse(dec3: [UInt8](data[located.payload])), existing.declaresAtmos {
            return nil
        }

        var patched = data
        // Append the tail to the payload first — the offsets below are still
        // valid because insertion happens at the payload's END, so every
        // ancestor's start offset is unchanged.
        patched.insert(
            contentsOf: [0x01, UInt8(index)],
            at: located.payload.upperBound
        )
        // 0x01 is reserved(7)=0 + flag=1; the next byte is the index.

        // Grow every enclosing box, innermost last so earlier writes don't move.
        for boxStart in located.ancestorStarts + [located.boxStart] {
            let current = Int(patched[boxStart]) << 24 | Int(patched[boxStart + 1]) << 16
                | Int(patched[boxStart + 2]) << 8 | Int(patched[boxStart + 3])
            let grown = current + 2
            patched[boxStart] = UInt8((grown >> 24) & 0xFF)
            patched[boxStart + 1] = UInt8((grown >> 16) & 0xFF)
            patched[boxStart + 2] = UInt8((grown >> 8) & 0xFF)
            patched[boxStart + 3] = UInt8(grown & 0xFF)
        }
        return patched
    }

    /// Where the `dec3` box is, and which boxes enclose it.
    ///
    /// The ancestor list is what makes growing the box safe: an fMP4 sample entry
    /// is nested six deep (`moov/trak/mdia/minf/stbl/stsd/ec-3/dec3`) and each
    /// level carries its own byte count.
    private static func locateDec3(
        in data: Data
    ) -> (boxStart: Int, payload: Range<Int>, ancestorStarts: [Int])? {
        func walk(
            _ range: Range<Int>, ancestors: [Int]
        ) -> (Int, Range<Int>, [Int])? {
            var cursor = range.lowerBound
            while cursor + 8 <= range.upperBound {
                let size = Int(data[cursor]) << 24 | Int(data[cursor + 1]) << 16
                    | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
                let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
                guard size >= 8, cursor + size <= range.upperBound else { return nil }
                let payload = (cursor + 8)..<(cursor + size)

                if type == "dec3" { return (cursor, payload, ancestors) }
                switch type {
                case "moov", "trak", "mdia", "minf", "stbl":
                    if let found = walk(payload, ancestors: ancestors + [cursor]) { return found }
                case "stsd":
                    // version+flags(4) + entry_count(4) precede the entries.
                    if payload.count > 8,
                       let found = walk(
                           (payload.lowerBound + 8)..<payload.upperBound,
                           ancestors: ancestors + [cursor]
                       ) {
                        return found
                    }
                case "ec-3", "ac-3":
                    // AudioSampleEntry's 28 fixed bytes precede its children.
                    if payload.count > 28,
                       let found = walk(
                           (payload.lowerBound + 28)..<payload.upperBound,
                           ancestors: ancestors + [cursor]
                       ) {
                        return found
                    }
                default:
                    break
                }
                cursor += size
            }
            return nil
        }
        return walk(0..<data.count, ancestors: [])
    }
}
