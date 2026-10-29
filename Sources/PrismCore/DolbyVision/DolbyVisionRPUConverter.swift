import Foundation
#if canImport(Libdovi)
import Libdovi
#endif

/// Converts a Dolby Vision **Profile 7** video stream into **Profile 8.1** as it
/// is remuxed, so a dual-layer source AVPlayer has no decoder for arrives as a
/// single-layer HDR10-base stream it does.
///
/// ## What P7 actually is, and what conversion means
///
/// Profile 7 is the Blu-ray shape: an HDR10 base layer, a separate enhancement
/// layer, and an RPU written in *dual-layer* form. No Apple platform decodes the
/// enhancement layer. Profile 8.1 is the same HDR10 base with a *single-layer*
/// RPU — so the conversion is two edits and no re-encode:
///
/// 1. rewrite each RPU (NAL type 62) into its 8.1 form, and
/// 2. drop the enhancement layer — every `unspec63` NAL (type 63). NOT "every
///    non-zero `nuh_layer_id`", which is what this used to say and do: an
///    interleaved P7 stream puts the EL, the RPU and the base layer all on
///    layer 0, so that test never matched and the EL survived into a stream
///    declared single-layer (see `isEnhancementLayer`).
///
/// The base layer's picture NALs are untouched: the bits AVPlayer receives are
/// still the source's own, which is the whole premise of the remux path. What the
/// viewer loses is the enhancement layer's extra precision — which was
/// unreachable anyway, since the alternative for these files is Prism, where DV
/// dies at the door entirely.
///
/// ## Availability
///
/// libdovi does the RPU surgery — the same library mpv uses, already linked into
/// MPVKit's `_FFmpeg` target, so this adds no dependency. It is nonetheless
/// behind `canImport`: if a host builds against an MPVKit that doesn't export the
/// module, the converter reports itself unavailable and P7 sources keep routing to
/// Prism. Same discipline as `AudioBridge` and the missing `eac3` encoder — a
/// capability that can't be delivered says so rather than failing at playback.
final class DolbyVisionRPUConverter {

    /// libdovi's conversion mode 2: "convert to profile 8.1". Modes 1 (MEL),
    /// 3 (P5 → 8.1) and 4 (→ 8.4 HLG) exist and are deliberately unused — 8.1 is
    /// the one profile whose base layer Apple's stack presents natively as
    /// HDR10, which is what makes the fallback honest when DV isn't engaged.
    private static let convertToProfile81: UInt8 = 2

    /// `unspec63` — how a muxed dual-layer HEVC stream carries the Dolby Vision
    /// enhancement layer. The RPU is `unspec62`; the EL is this. Both sit on
    /// `nuh_layer_id == 0`, which is why the layer id cannot be used to find
    /// either of them.
    private static let nalTypeEnhancementLayer: UInt8 = 63

    /// Whether conversion can run at all in this build.
    static var isAvailable: Bool {
        #if canImport(Libdovi)
        return true
        #else
        return false
        #endif
    }

    /// NAL length prefix width, from the source's `hvcC`.
    private let lengthSize: Int

    /// Counters for the one-line summary the remuxer logs. A P7 stream whose RPUs
    /// all failed to convert is indistinguishable at playback from one that
    /// converted cleanly (both play — one as DV, one as plain HDR10), so without
    /// these the only symptom of a broken conversion is a user saying the DV logo
    /// never appeared.
    private(set) var convertedRPUs = 0
    private(set) var failedRPUs = 0
    private(set) var droppedEnhancementLayerNALs = 0

    /// Packets this converter DECIDED to rewrite and then could not: the walk
    /// found an RPU or an enhancement layer, but `HEVCNALUnits.rewrite` refused
    /// — the packet did not frame, or the output buffer could not be allocated.
    /// The demuxer's original bytes are emitted in that case, so such a packet
    /// reaches the muxer with its enhancement layer and its unconverted
    /// Profile 7 RPU intact, inside a stream declared single-layer 8.1. That is
    /// the same mismatch that made a P7 title play black, so it is counted and
    /// it makes `isClean` false rather than passing silently.
    private(set) var staleUnconvertedPackets = 0

    /// Per-frame RPU health, for the black-screen question (see
    /// `DolbyVisionConversionStats`): pictures that left with no RPU, RPUs that
    /// left ahead of their picture, RPUs whose mapping the conversion replaced
    /// with the identity, RPUs without display-management metadata, and RPUs
    /// that came from a full enhancement layer stream.
    private(set) var picturesWithoutRPU = 0
    private(set) var rpusBeforePicture = 0
    private(set) var mappingsReplacedByIdentity = 0
    private(set) var rpusWithoutDisplayMetadata = 0
    private(set) var fullEnhancementLayerRPUs = 0

    /// Per-packet tallies, committed to the counters above only once the
    /// rewrite has actually landed.
    ///
    /// `dispose` runs during the disposition WALK, which finishes before
    /// `rewrite` asks for a buffer — so counting there and stopping counted
    /// work that was then thrown away by a framing or allocation failure, while
    /// the stale original went out. The stats said the enhancement layer had
    /// been dropped when it had not: exactly the reading that hid the
    /// `unspec63` bug in the first place.
    private var pendingConverted = 0
    private var pendingFailed = 0
    private var pendingDropped = 0
    /// What this packet's walk saw: a base-layer picture, an RPU kept ahead of
    /// one, and the converted RPUs' findings.
    private var pendingPicture = false
    private var pendingRPUBeforePicture = false
    private var pendingMappingsReplaced = 0
    private var pendingWithoutDisplayMetadata = 0
    private var pendingFullEnhancementLayer = 0

    /// - Parameter lengthSize: from `HEVCNALUnits.lengthSize(fromHVCC:)`. A
    ///   source whose record can't be read isn't convertible: without the prefix
    ///   width the packet can't be walked at all.
    init?(lengthSize: Int?) {
        guard Self.isAvailable, let lengthSize else { return nil }
        self.lengthSize = lengthSize
    }

    /// Converted packet payload, or `nil` when this packet needed no change (the
    /// caller then writes the original buffer untouched).
    func convert(packet bytes: [UInt8]) -> [UInt8]? {
        resetPending()
        // `transform` runs only after `rewrite` has validated the whole packet,
        // so having been called at all IS the proof that it framed — no second
        // walk, on any path.
        var framed = false
        let rewritten = HEVCNALUnits.rewrite(bytes, lengthSize: lengthSize) { unit in
            framed = true
            return self.dispose(unit)
        }
        commitPending(rewrote: rewritten != nil, framed: framed)
        return rewritten
    }

    /// The copy loop's shape: walk the packet's own buffer, and only when
    /// something changed write the result once into the buffer `allocate`
    /// returns (see `HEVCNALUnits.rewrite(_:lengthSize:transform:into:)`).
    func convert(
        packet bytes: UnsafeBufferPointer<UInt8>,
        into allocate: (Int) -> UnsafeMutablePointer<UInt8>?
    ) -> Bool {
        resetPending()
        var framed = false
        let rewrote = HEVCNALUnits.rewrite(
            bytes,
            lengthSize: lengthSize,
            transform: { unit in
                framed = true
                return self.dispose(unit)
            },
            into: allocate
        )
        commitPending(rewrote: rewrote, framed: framed)
        return rewrote
    }

    private func resetPending() {
        pendingConverted = 0
        pendingFailed = 0
        pendingDropped = 0
        pendingPicture = false
        pendingRPUBeforePicture = false
        pendingMappingsReplaced = 0
        pendingWithoutDisplayMetadata = 0
        pendingFullEnhancementLayer = 0
    }

    /// `rewrote == false` means one of two things, and only one of them is
    /// harmless: either nothing needed changing (no RPU, no enhancement layer —
    /// every packet of every non-P7 source), or the rewrite was WANTED and
    /// refused. The pending tally tells them apart: work was decided, so the
    /// original bytes went out stale.
    private func commitPending(rewrote: Bool, framed: Bool) {
        let decidedAChange = pendingConverted + pendingFailed + pendingDropped > 0
        guard rewrote else {
            // A packet that did not FRAME is stale too, and the pending tally
            // cannot see it: `HEVCNALUnits.rewrite` validates the whole packet
            // before it calls `dispose`, so nothing was ever decided and the
            // original went to the muxer unexamined — enhancement layer and
            // unconverted RPU included.
            if decidedAChange || !framed {
                staleUnconvertedPackets += 1
            } else if pendingPicture {
                // Framed and untouched: no RPU and no enhancement layer in it.
                picturesWithoutRPU += 1
            }
            resetPending()
            return
        }
        convertedRPUs += pendingConverted
        failedRPUs += pendingFailed
        droppedEnhancementLayerNALs += pendingDropped
        if pendingPicture, pendingConverted == 0 { picturesWithoutRPU += 1 }
        if pendingRPUBeforePicture { rpusBeforePicture += 1 }
        mappingsReplacedByIdentity += pendingMappingsReplaced
        rpusWithoutDisplayMetadata += pendingWithoutDisplayMetadata
        fullEnhancementLayerRPUs += pendingFullEnhancementLayer
        resetPending()
    }

    private func dispose(_ unit: HEVCNALUnits.Unit) -> HEVCNALUnits.Disposition {
        // The enhancement layer goes first: it is the larger half of the
        // saving, and an EL NAL never carries an RPU we want.
        //
        // It is identified by NAL TYPE 63 (`unspec63`), not by `nuh_layer_id`.
        // That distinction was this converter's central bug: a muxed dual-layer
        // stream carries its EL as unspec63 with `nuh_layer_id == 0` — every
        // NAL in a real P7 stream is layer 0 — so the `layerID != 0` test below
        // never fired and the EL rode straight through into an fMP4 whose
        // `dvvC` declares `el_present = 0`. AVPlayer was handed a stream
        // declared single-layer 8.1 that still contained the enhancement layer:
        // the base layer decoded (which is why audio played and no decode error
        // was ever reported), the Dolby Vision path did not, and the viewer got
        // a black picture. With Dolby Vision off nothing claims DV, AVPlayer
        // ignores an unknown NAL type, and the same file plays — which is
        // exactly the shape the bug report had.
        //
        // The `layerID` test stays as well: a genuinely layered carriage would
        // put the EL on a non-zero layer, and dropping it there is equally
        // right. `droppedEnhancementLayerNALs` reading zero on a real P7 source
        // was the symptom, not the expected result — see the note in
        // `RealMediaVerificationTests`.
        if Self.isEnhancementLayer(type: unit.type, layerID: unit.layerID) {
            pendingDropped += 1
            return .drop
        }
        if unit.type < 32 {
            // A base-layer picture (VCL). One already followed by a kept RPU
            // means the RPU sits ahead of a picture of its access unit.
            pendingPicture = true
            if pendingConverted > 0 { pendingRPUBeforePicture = true }
        }
        guard unit.type == 62 else { return .keep }
        guard let conversion = Self.convertRPU(Array(unit.bytes)) else {
            pendingFailed += 1
            // Drop it. The old code kept the unconverted RPU, on the reasoning
            // that the 8.1 claim is only made when conversion succeeded — which
            // is not true: `HLSRemuxer` declares 8.1 because a converter EXISTS
            // (`outputDolbyVision`), before a single packet has been through it,
            // and the master and init segment are published long before any
            // failure could be known. Keeping the RPU therefore shipped a P7 RPU
            // inside a container declaring `profile 8` and `el_present = 0` —
            // the same class of lie as the enhancement layer riding through
            // above, and the same black picture.
            //
            // Dropping degrades that frame to its clean HDR10 base, which the
            // container already describes correctly. `failedRPUs` is what says
            // the 8.1 declaration stopped covering every frame, and `isClean`
            // reports it to the host.
            return .drop
        }
        pendingConverted += 1
        if conversion.replacedMapping { pendingMappingsReplaced += 1 }
        if !conversion.hasDisplayMetadata { pendingWithoutDisplayMetadata += 1 }
        if conversion.fullEnhancementLayer { pendingFullEnhancementLayer += 1 }
        return .replace(conversion.bytes)
    }

    /// Whether this NAL is enhancement layer, and so must not reach a stream
    /// declared single-layer 8.1.
    ///
    /// Pure and `internal` on purpose: the whole bug was in this one predicate,
    /// and it must stay provable without libdovi or a real disc — the converter
    /// itself cannot even be constructed in a build that has neither.
    static func isEnhancementLayer(type: UInt8, layerID: UInt8) -> Bool {
        type == nalTypeEnhancementLayer || layerID != 0
    }

    /// One converted RPU, and what the conversion did to it.
    struct Conversion {
        /// The 8.1 RPU NAL, header included.
        let bytes: [UInt8]
        /// The source's mapping was not already the identity: libdovi's mode 2
        /// replaced it (its documented 8.1 conversion — "both luma and chroma
        /// mapping curves are set to no-op"), so this frame's 8.1 RPU maps the
        /// base layer as it is. Read off the source's own curves
        /// (`isIdentity`): libdovi's mode 4, "preserving" the mapping, writes a
        /// curve of its own rather than the source's (measured, libdovi 3.3.2),
        /// so comparing the two conversions says nothing.
        let replacedMapping: Bool
        /// The converted RPU carries display-management metadata (its L1, L2,
        /// L6 … extension blocks).
        let hasDisplayMetadata: Bool
        /// libdovi's reading of the source RPU: a full enhancement layer stream.
        let fullEnhancementLayer: Bool
    }

    /// One RPU NAL (including its two-byte HEVC header) through libdovi.
    static func convertRPU(_ nal: [UInt8]) -> Conversion? {
        #if canImport(Libdovi)
        return nal.withUnsafeBufferPointer { buffer -> Conversion? in
            guard let base = buffer.baseAddress,
                  let rpu = dovi_parse_unspec62_nalu(base, buffer.count)
            else { return nil }
            defer { dovi_rpu_free(rpu) }
            var fullEnhancementLayer = false
            if let header = dovi_rpu_get_header(rpu) {
                fullEnhancementLayer = header.pointee.el_type.map { String(cString: $0) == "FEL" } ?? false
                dovi_rpu_free_header(header)
            }
            // nil (no mapping of its own: a `use_prev_vdr_rpu` RPU) is not counted.
            var replacedMapping = false
            if let mapping = dovi_rpu_get_data_mapping(rpu) {
                replacedMapping = !isIdentity(mapping.pointee)
                dovi_rpu_free_data_mapping(mapping)
            }

            guard dovi_convert_rpu_with_mode(rpu, convertToProfile81) == 0 else { return nil }
            var hasDisplayMetadata = false
            if let header = dovi_rpu_get_header(rpu) {
                hasDisplayMetadata = header.pointee.vdr_dm_metadata_present_flag
                dovi_rpu_free_header(header)
            }
            guard let written = dovi_write_unspec62_nalu(rpu) else { return nil }
            defer { dovi_data_free(written) }
            guard let data = written.pointee.data, written.pointee.len > 0 else { return nil }
            return Conversion(
                bytes: Array(UnsafeBufferPointer(start: data, count: Int(written.pointee.len))),
                replacedMapping: replacedMapping,
                hasDisplayMetadata: hasDisplayMetadata,
                fullEnhancementLayer: fullEnhancementLayer
            )
        }
        #else
        return nil
        #endif
    }

    #if canImport(Libdovi)
    /// Whether every component maps the base layer as it is: one piece, a
    /// first-order polynomial y = 0 + 1·x — the curves mode 2 writes.
    private static func isIdentity(_ mapping: DoviRpuDataMapping) -> Bool {
        withUnsafePointer(to: mapping.curves) { tuple in
            tuple.withMemoryRebound(to: DoviReshapingCurve.self, capacity: Int(DoviNUM_COMPONENTS)) { curves in
                (0..<Int(DoviNUM_COMPONENTS)).allSatisfy { index in
                    let curve = curves[index]
                    guard curve.num_pivots_minus2 == 0, curve.mapping_idc == 0,
                          let polynomial = curve.polynomial?.pointee,
                          polynomial.poly_order_minus1.len == 1, polynomial.poly_order_minus1.data[0] == 0,
                          polynomial.poly_coef_int.len == 1, polynomial.poly_coef.len == 1,
                          let integers = polynomial.poly_coef_int.list[0]?.pointee,
                          let fractions = polynomial.poly_coef.list[0]?.pointee,
                          integers.len == 2, fractions.len == 2
                    else { return false }
                    return integers.data[0] == 0 && integers.data[1] == 1 && fractions.data[0] == 0 && fractions.data[1] == 0
                }
            }
        }
    }
    #endif
}

/// What a Profile 7 → 8.1 conversion did over the course of a session.
///
/// Exposed because "did it work" has no other observable answer: a P7 source
/// whose RPUs all failed to convert still plays — as plain HDR10 — so the only
/// other symptom is a viewer reporting that Dolby Vision never engaged.
public struct DolbyVisionConversionStats: Sendable, Equatable {
    /// RPU NALs rewritten into single-layer 8.1 form.
    public let convertedRPUs: Int
    /// RPU NALs libdovi refused. DROPPED, not left in place (which is what this
    /// said, and did, before 2.0.1): a stale Profile 7 RPU inside a container
    /// declaring `profile 8` is the same mismatch that made a P7 title play
    /// black. A non-zero count here means the 8.1 declaration stopped
    /// describing every frame, which is worth a host's log line.
    public let failedRPUs: Int
    /// Enhancement-layer NALs dropped — the other half of making a dual-layer
    /// stream single-layer.
    public let droppedEnhancementLayerNALs: Int
    /// Packets the converter decided to rewrite and could not — the packet did
    /// not frame, or the output buffer could not be allocated — so the
    /// demuxer's original bytes went out with their enhancement layer and their
    /// unconverted RPU intact, inside a stream declared single-layer 8.1.
    ///
    /// Counted separately because the tallies above deliberately no longer
    /// include that work: they are committed only once a rewrite has landed.
    /// Anything here is the black-screen mismatch on a rarer path.
    public let staleUnconvertedPackets: Int

    /// Pictures (packets with a base-layer VCL NAL) that reached the muxer with
    /// no RPU: their access unit carried none, or libdovi refused it
    /// (`failedRPUs`) and it was dropped. In a stream declared 8.1 every picture
    /// should carry one; how a Dolby Vision decoder treats a picture without
    /// one is not specified publicly, which is why it is counted.
    public let picturesWithoutRPU: Int
    /// Packets whose converted RPU sits ahead of a base-layer picture of the
    /// same packet. Dolby Vision streams put the RPU after the access unit's
    /// pictures; a decoder that expects it there may not apply it.
    public let rpusBeforePicture: Int
    /// Converted RPUs whose source mapping was not already the identity and
    /// which the conversion replaced with it — libdovi's documented 8.1
    /// conversion (mode 2) does this to every RPU, so on a Profile 7 source this
    /// counts the frames whose 8.1 RPU maps the base layer as it is rather than
    /// as the source's mapping (written for base + enhancement layer) would.
    /// The display-management metadata (L1, L2, L6 …) is kept either way.
    public let mappingsReplacedByIdentity: Int
    /// Converted RPUs that carry no display-management metadata: a Dolby
    /// Vision display has nothing to tone-map those frames by.
    public let rpusWithoutDisplayMetadata: Int
    /// Converted RPUs libdovi read as coming from a full enhancement layer
    /// (FEL) stream — whose base layer alone is not the picture the source
    /// mastered, unlike a minimal enhancement layer's (MEL).
    public let fullEnhancementLayerRPUs: Int

    /// Every field after `droppedEnhancementLayerNALs` defaults, so that
    /// earlier releases stay source compatible for anyone constructing this.
    public init(
        convertedRPUs: Int,
        failedRPUs: Int,
        droppedEnhancementLayerNALs: Int,
        staleUnconvertedPackets: Int = 0,
        picturesWithoutRPU: Int = 0,
        rpusBeforePicture: Int = 0,
        mappingsReplacedByIdentity: Int = 0,
        rpusWithoutDisplayMetadata: Int = 0,
        fullEnhancementLayerRPUs: Int = 0
    ) {
        self.convertedRPUs = convertedRPUs
        self.failedRPUs = failedRPUs
        self.droppedEnhancementLayerNALs = droppedEnhancementLayerNALs
        self.staleUnconvertedPackets = staleUnconvertedPackets
        self.picturesWithoutRPU = picturesWithoutRPU
        self.rpusBeforePicture = rpusBeforePicture
        self.mappingsReplacedByIdentity = mappingsReplacedByIdentity
        self.rpusWithoutDisplayMetadata = rpusWithoutDisplayMetadata
        self.fullEnhancementLayerRPUs = fullEnhancementLayerRPUs
    }

    /// Every RPU converted, none refused, and the enhancement layer actually
    /// gone.
    ///
    /// The EL clause is not belt-and-braces: a dual-layer source reporting zero
    /// dropped EL NALs is precisely the state that hid the `unspec63` bug for
    /// as long as it did — the conversion looked clean while the stream still
    /// carried the layer its own `dvvC` said was absent. If this can read clean
    /// in that state again, nothing will report it but a viewer with a black
    /// screen.
    public var isClean: Bool {
        failedRPUs == 0
            && convertedRPUs > 0
            && droppedEnhancementLayerNALs > 0
            && staleUnconvertedPackets == 0
    }
}

extension DolbyVisionConfiguration {

    /// The configuration a converted stream should be *declared* as: same DV
    /// level, profile 8, HDR10 base compatibility, single layer.
    ///
    /// `MasterPlaylistBuilder` reads `baseLayerSignalCompatibilityID == 1` to
    /// emit the `db1p` brand, so this is what turns a P7 source into a
    /// `SUPPLEMENTAL-CODECS="dvh1.08.<level>/db1p"` claim — the exact hand-off the
    /// builder's `dolbyVisionBrand` doc anticipated.
    var convertedToProfile81: DolbyVisionConfiguration {
        DolbyVisionConfiguration(
            versionMajor: versionMajor,
            versionMinor: versionMinor,
            profile: 8,
            level: level,
            rpuPresent: true,
            enhancementLayerPresent: false,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: 1
        )
    }
}
