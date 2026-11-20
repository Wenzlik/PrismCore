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

    /// RPUs whose ORIGINAL (pre-conversion) header named the enhancement layer
    /// FEL or MEL. Diagnostic only — nothing branches on them: the EL is
    /// dropped and the RPU rewritten to 8.1 either way. They exist because the
    /// `dvvC` record cannot say which kind of P7 a source is (see
    /// `DolbyVisionConversionStats.enhancementLayerType`).
    private(set) var felRPUs = 0
    private(set) var melRPUs = 0

    /// FEL RPUs whose peak / mastering fields were lowered to the base
    /// layer's (`DolbyVisionRPUPeakAligner`), and eligible ones left as
    /// converted because the rewrite could not be proved safe. Both stay zero
    /// unless the host opted in.
    private(set) var alignedRPUs = 0
    private(set) var alignSkippedRPUs = 0

    /// Packets this converter DECIDED to rewrite and then could not: the walk
    /// found an RPU or an enhancement layer, but `HEVCNALUnits.rewrite` refused
    /// — the packet did not frame, or the output buffer could not be allocated.
    /// The demuxer's original bytes are emitted in that case, so such a packet
    /// reaches the muxer with its enhancement layer and its unconverted
    /// Profile 7 RPU intact, inside a stream declared single-layer 8.1. That is
    /// the same mismatch that made a P7 title play black, so it is counted and
    /// it makes `isClean` false rather than passing silently.
    private(set) var staleUnconvertedPackets = 0

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
    private var pendingFEL = 0
    private var pendingMEL = 0
    private var pendingAligned = 0
    private var pendingAlignSkipped = 0

    /// - Parameter lengthSize: from `HEVCNALUnits.lengthSize(fromHVCC:)`. A
    ///   source whose record can't be read isn't convertible: without the prefix
    ///   width the packet can't be walked at all.
    /// - Parameter alignFELDeliveryMetadata: the host's opt-in
    ///   (`PrismCoreSession.Options.alignFELDeliveryMetadata`). `false` keeps
    ///   every RPU exactly as libdovi wrote it.
    /// - Parameter baseLayerPeakNits: the source's MDCV max luminance; `nil`
    ///   (unknown) aligns nothing even when opted in.
    convenience init?(
        lengthSize: Int?, alignFELDeliveryMetadata: Bool = false, baseLayerPeakNits: Double? = nil
    ) {
        guard DolbyVisionRPUConverter.isAvailable else { return nil }
        self.init(
            lengthSize: lengthSize,
            rpuProcessor: DolbyVisionRPUConverter.convertRPU,
            felPeakAlignment: alignFELDeliveryMetadata
                ? FELPeakAlignment(baseLayerPeakNits: baseLayerPeakNits, readFields: DolbyVisionRPUConverter.readDMFields)
                : nil
        )
    }

    /// What the opt-in FEL peak alignment needs: the base layer's peak, and a
    /// way to read an RPU NAL's DM fields back — libdovi in production. The
    /// read is injectable for the same reason `rpuProcessor` is: no fixture,
    /// and libdovi may not be linked.
    struct FELPeakAlignment {
        let baseLayerPeakNits: Double?
        let readFields: ([UInt8]) -> DolbyVisionRPUPeakAligner.DMFields?
    }

    /// `nil` = alignment off, which must stay byte-identical to a build
    /// without it.
    private let felPeakAlignment: FELPeakAlignment?

    /// One RPU NAL in, its 8.1 rewrite (or `nil` if refused) and the ORIGINAL
    /// header's raw `el_type` out. Production is always `convertRPU`.
    typealias RPUProcessor = ([UInt8]) -> (converted: [UInt8]?, elType: String?)

    /// The libdovi call, swappable. Internal test seam only: there is no P7
    /// RPU fixture and libdovi cannot author one, so without this nothing
    /// proves the FEL/MEL tallies are captured per RPU and committed only
    /// with a landed rewrite — moving the header read after the conversion,
    /// or forgetting `pendingFEL` in `commitPending`, would pass every
    /// pure test.
    private let rpuProcessor: RPUProcessor

    /// Deliberately NOT gated on `isAvailable`: the injected processor stands
    /// in for libdovi, so the bookkeeping is testable in a build without it.
    init?(
        lengthSize: Int?,
        rpuProcessor: @escaping RPUProcessor,
        felPeakAlignment: FELPeakAlignment? = nil
    ) {
        guard let lengthSize else { return nil }
        self.lengthSize = lengthSize
        self.rpuProcessor = rpuProcessor
        self.felPeakAlignment = felPeakAlignment
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
        pendingFEL = 0
        pendingMEL = 0
        pendingAligned = 0
        pendingAlignSkipped = 0
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
            if decidedAChange || !framed { staleUnconvertedPackets += 1 }
            resetPending()
            return
        }
        convertedRPUs += pendingConverted
        failedRPUs += pendingFailed
        droppedEnhancementLayerNALs += pendingDropped
        felRPUs += pendingFEL
        melRPUs += pendingMEL
        alignedRPUs += pendingAligned
        alignSkippedRPUs += pendingAlignSkipped
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
        guard unit.type == 62 else { return .keep }
        let (converted, rawELType) = rpuProcessor(Array(unit.bytes))
        // Tallied whether or not the conversion then succeeds: the header
        // describes the SOURCE, and a refused RPU says as much about which
        // kind of P7 this is as a converted one.
        switch Self.classify(elType: rawELType) {
        case .fel: pendingFEL += 1
        case .mel: pendingMEL += 1
        case nil: break
        }
        guard let converted else {
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
        return .replace(alignedIfEligible(converted, elType: rawELType))
    }

    /// The converted RPU with its peak fields lowered to the base layer's, or
    /// `converted` itself whenever that is not both wanted and proved safe.
    ///
    /// Two proofs, either of which failing leaves the RPU as converted (and
    /// counts `alignSkippedRPUs`): the aligner's own — every field at its
    /// computed offset reads what libdovi reported, the CRC reproduces — and
    /// libdovi's, after the fact: the patched NAL must parse, and read back
    /// as exactly the intended fields with everything else unchanged. Only
    /// the RPU is ever passed here; the enhancement layer was dropped above
    /// without being read.
    private func alignedIfEligible(_ converted: [UInt8], elType: String?) -> [UInt8] {
        // Cheap gates first: the read-back parses the RPU again, which only
        // an opted-in FEL session with a usable base-layer peak should pay.
        guard let alignment = felPeakAlignment,
              Self.classify(elType: elType) == .fel,
              DolbyVisionRPUPeakAligner.isEligibleBaseLayerPeak(alignment.baseLayerPeakNits)
        else { return converted }
        guard let reported = alignment.readFields(converted) else {
            pendingAlignSkipped += 1
            return converted
        }
        guard let target = DolbyVisionRPUPeakAligner.target(
            for: reported, elType: elType, baseLayerPeakNits: alignment.baseLayerPeakNits
        ) else { return converted }
        guard let patched = DolbyVisionRPUPeakAligner.rewrite(converted, reported: reported, target: target),
              alignment.readFields(patched) == target
        else {
            pendingAlignSkipped += 1
            return converted
        }
        pendingAligned += 1
        return patched
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

    /// libdovi's `el_type` string → our enum. Exact, case-sensitive match on
    /// the two values libdovi writes; anything else (including `nil`, which is
    /// what libdovi reports for a non-P7 RPU) is "unknown" rather than a guess.
    ///
    /// Pure and free of libdovi so the mapping is testable in a build without it.
    static func classify(elType: String?) -> DolbyVisionEnhancementLayerType? {
        switch elType {
        case "FEL": return .fel
        case "MEL": return .mel
        default: return nil
        }
    }

    /// One RPU NAL (including its two-byte HEVC header) through libdovi: the
    /// 8.1 rewrite, or `nil` if libdovi refused it, plus the raw `el_type` the
    /// ORIGINAL RPU declared (`classify` maps it, in `dispose`).
    private static func convertRPU(
        _ nal: [UInt8]
    ) -> (converted: [UInt8]?, elType: String?) {
        #if canImport(Libdovi)
        return nal.withUnsafeBufferPointer { buffer -> (converted: [UInt8]?, elType: String?) in
            guard let base = buffer.baseAddress,
                  let rpu = dovi_parse_unspec62_nalu(base, buffer.count)
            else { return (nil, nil) }
            defer { dovi_rpu_free(rpu) }

            // Read BEFORE converting: mode 2 rewrites the RPU into single-layer
            // 8.1 form, after which the header no longer reports an EL type at
            // all — reading it afterwards would label every P7 "unknown". The
            // header is its own allocation, freed separately from the RPU.
            var elType: String?
            if let header = dovi_rpu_get_header(rpu) {
                elType = header.pointee.el_type.map { String(cString: $0) }
                dovi_rpu_free_header(header)
            }

            guard dovi_convert_rpu_with_mode(rpu, convertToProfile81) == 0 else { return (nil, elType) }
            guard let written = dovi_write_unspec62_nalu(rpu) else { return (nil, elType) }
            defer { dovi_data_free(written) }
            guard let data = written.pointee.data, written.pointee.len > 0 else { return (nil, elType) }
            return (Array(UnsafeBufferPointer(start: data, count: Int(written.pointee.len))), elType)
        }
        #else
        return (nil, nil)
        #endif
    }

    /// One written unspec62 NAL parsed back through libdovi into the fields
    /// the aligner works on, or `nil` if libdovi reports an error, the RPU has
    /// no DM block, or the block is the compressed form (which carries no
    /// coefficients to locate it by).
    ///
    /// `untouched` fingerprints the rest of what libdovi reports — every
    /// other DM scalar and the ext blocks the alignment must never change
    /// (L2, L3, L4, L5, L8, L9, L10, L11, L254, L255) — so the read-back
    /// after a rewrite proves they survived, not just that the new values
    /// landed.
    static func readDMFields(_ nal: [UInt8]) -> DolbyVisionRPUPeakAligner.DMFields? {
        #if canImport(Libdovi)
        return nal.withUnsafeBufferPointer { buffer -> DolbyVisionRPUPeakAligner.DMFields? in
            guard let base = buffer.baseAddress,
                  let rpu = dovi_parse_unspec62_nalu(base, buffer.count)
            else { return nil }
            defer { dovi_rpu_free(rpu) }
            // Parsing returns an object even on failure; the error is how it
            // says so (libdovi's own note on `dovi_rpu_get_error`). A CRC that
            // does not match is one such error.
            guard dovi_rpu_get_error(rpu) == nil, let dmPointer = dovi_rpu_get_vdr_dm_data(rpu) else { return nil }
            defer { dovi_rpu_free_vdr_dm_data(dmPointer) }
            let dm = dmPointer.pointee
            guard !dm.compressed else { return nil }

            let coefficients: [Int16] = [
                dm.ycc_to_rgb_coef0, dm.ycc_to_rgb_coef1, dm.ycc_to_rgb_coef2,
                dm.ycc_to_rgb_coef3, dm.ycc_to_rgb_coef4, dm.ycc_to_rgb_coef5,
                dm.ycc_to_rgb_coef6, dm.ycc_to_rgb_coef7, dm.ycc_to_rgb_coef8,
            ]
            let ext = dm.dm_data
            // UInt64 fields convert truncating: a fingerprint must never be
            // the thing that traps in a playback path.
            var untouched: [Int64] = [
                Int64(truncatingIfNeeded: dm.affected_dm_metadata_id),
                Int64(truncatingIfNeeded: dm.current_dm_metadata_id),
                Int64(truncatingIfNeeded: dm.scene_refresh_flag),
                Int64(dm.ycc_to_rgb_offset0), Int64(dm.ycc_to_rgb_offset1), Int64(dm.ycc_to_rgb_offset2),
                Int64(dm.rgb_to_lms_coef0), Int64(dm.rgb_to_lms_coef1), Int64(dm.rgb_to_lms_coef2),
                Int64(dm.rgb_to_lms_coef3), Int64(dm.rgb_to_lms_coef4), Int64(dm.rgb_to_lms_coef5),
                Int64(dm.rgb_to_lms_coef6), Int64(dm.rgb_to_lms_coef7), Int64(dm.rgb_to_lms_coef8),
                Int64(dm.signal_eotf), Int64(dm.signal_eotf_param0), Int64(dm.signal_eotf_param1),
                Int64(dm.signal_eotf_param2), Int64(dm.signal_bit_depth), Int64(dm.signal_color_space),
                Int64(dm.signal_chroma_format), Int64(dm.signal_full_range_flag), Int64(dm.source_diagonal),
                Int64(truncatingIfNeeded: ext.num_ext_blocks),
            ]
            // A marker per block so "absent" and "present with zeros" differ.
            func block<T>(_ pointer: UnsafePointer<T>?, _ fields: (T) -> [Int64]) {
                guard let pointer else { untouched.append(-1); return }
                untouched.append(1)
                untouched += fields(pointer.pointee)
            }
            func list<T>(_ items: UnsafePointer<UnsafePointer<T>?>?, _ count: Int, _ fields: (T) -> [Int64]) {
                untouched.append(Int64(count))
                guard let items else { return }
                for i in 0..<count { block(items[i], fields) }
            }
            list(ext.level2.list, ext.level2.len) {
                [Int64($0.target_max_pq), Int64($0.trim_slope), Int64($0.trim_offset), Int64($0.trim_power),
                 Int64($0.trim_chroma_weight), Int64($0.trim_saturation_gain), Int64($0.ms_weight)]
            }
            block(ext.level3) { [Int64($0.min_pq_offset), Int64($0.max_pq_offset), Int64($0.avg_pq_offset)] }
            block(ext.level4) { [Int64($0.anchor_pq), Int64($0.anchor_power)] }
            block(ext.level5) {
                [Int64($0.active_area_left_offset), Int64($0.active_area_right_offset),
                 Int64($0.active_area_top_offset), Int64($0.active_area_bottom_offset)]
            }
            list(ext.level8.list, ext.level8.len) {
                [Int64(truncatingIfNeeded: $0.length), Int64($0.target_display_index), Int64($0.trim_slope), Int64($0.trim_offset),
                 Int64($0.trim_power), Int64($0.trim_chroma_weight), Int64($0.trim_saturation_gain),
                 Int64($0.ms_weight), Int64($0.target_mid_contrast), Int64($0.clip_trim)]
            }
            block(ext.level9) { [Int64(truncatingIfNeeded: $0.length), Int64($0.source_primary_index)] }
            list(ext.level10.list, ext.level10.len) {
                [Int64(truncatingIfNeeded: $0.length), Int64($0.target_display_index), Int64($0.target_max_pq),
                 Int64($0.target_min_pq), Int64($0.target_primary_index)]
            }
            block(ext.level11) { [Int64($0.content_type), Int64($0.whitepoint), $0.reference_mode_flag ? 1 : 0] }
            block(ext.level254) { [Int64($0.dm_mode), Int64($0.dm_version_index)] }
            block(ext.level255) { [Int64($0.dm_run_mode), Int64($0.dm_run_version)] }

            return DolbyVisionRPUPeakAligner.DMFields(
                yccToRGB: coefficients.map { UInt16(bitPattern: $0) },
                sourceMinPQ: dm.source_min_pq,
                sourceMaxPQ: dm.source_max_pq,
                level1: ext.level1.map {
                    DolbyVisionRPUPeakAligner.DMFields.Level1(minPQ: $0.pointee.min_pq, maxPQ: $0.pointee.max_pq, avgPQ: $0.pointee.avg_pq)
                },
                level6: ext.level6.map {
                    DolbyVisionRPUPeakAligner.DMFields.Level6(
                        maxMasteringNits: $0.pointee.max_display_mastering_luminance,
                        minMastering: $0.pointee.min_display_mastering_luminance,
                        maxCLL: $0.pointee.max_content_light_level,
                        maxFALL: $0.pointee.max_frame_average_light_level
                    )
                },
                untouched: untouched
            )
        }
        #else
        return nil
        #endif
    }
}

/// Which kind of enhancement layer a Profile 7 source carried, as its RPUs
/// declare it.
///
/// FEL (full enhancement layer) carries a real residual that a dual-layer
/// decoder adds to the base; MEL (minimal) carries next to nothing. Playback
/// does not distinguish them — both are converted to 8.1 and the EL dropped —
/// so this is diagnostics only: it tells a viewer looking at stats what was
/// given up.
public enum DolbyVisionEnhancementLayerType: String, Sendable, Equatable {
    case fel = "FEL"
    case mel = "MEL"
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
    /// RPUs whose original header declared a FEL / MEL enhancement layer.
    /// Counted from the RPU itself because nothing earlier can tell: the
    /// `dvvC` record says only "profile 7, EL present", and the probe never
    /// parses an RPU. So, like every other figure here, these are available
    /// from the first produced segment onwards, not at probe time.
    public let felRPUs: Int
    public let melRPUs: Int
    /// FEL RPUs whose peak / mastering metadata was lowered to the base
    /// layer's (`PrismCoreSession.Options.alignFELDeliveryMetadata`), and
    /// eligible FEL RPUs left exactly as converted because the rewrite could
    /// not be proved safe. Diagnostics only: both are zero unless the host
    /// opted in, and neither enters `isClean` — a skipped RPU still plays as a
    /// correct 8.1 conversion.
    public let alignedRPUs: Int
    public let alignSkippedRPUs: Int

    /// Everything after `droppedEnhancementLayerNALs` defaults so that
    /// existing callers stay source compatible.
    public init(
        convertedRPUs: Int,
        failedRPUs: Int,
        droppedEnhancementLayerNALs: Int,
        staleUnconvertedPackets: Int = 0,
        felRPUs: Int = 0,
        melRPUs: Int = 0,
        alignedRPUs: Int = 0,
        alignSkippedRPUs: Int = 0
    ) {
        self.convertedRPUs = convertedRPUs
        self.failedRPUs = failedRPUs
        self.droppedEnhancementLayerNALs = droppedEnhancementLayerNALs
        self.staleUnconvertedPackets = staleUnconvertedPackets
        self.felRPUs = felRPUs
        self.melRPUs = melRPUs
        self.alignedRPUs = alignedRPUs
        self.alignSkippedRPUs = alignSkippedRPUs
    }

    /// The enhancement layer the source carried, or `nil` when no RPU said.
    ///
    /// FEL wins over MEL: a single FEL RPU means the layer carried a real
    /// residual somewhere, which is the more informative answer for what the
    /// 8.1 conversion threw away.
    public var enhancementLayerType: DolbyVisionEnhancementLayerType? {
        if felRPUs > 0 { return .fel }
        if melRPUs > 0 { return .mel }
        return nil
    }

    /// One-line label for a stats overlay: `"P7 FEL → 8.1"`, `"P7 MEL → 8.1"`,
    /// or `"Profile 7 → 8.1"` while the type is unknown. Diagnostics only —
    /// it says nothing about whether the conversion was clean (`isClean`).
    public var statsLabel: String {
        switch enhancementLayerType {
        case .fel: return "P7 FEL → 8.1"
        case .mel: return "P7 MEL → 8.1"
        case nil: return "Profile 7 → 8.1"
        }
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
