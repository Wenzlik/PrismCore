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
