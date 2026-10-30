import Foundation
import Libavformat
import Libavcodec
import Libavutil
#if canImport(Libdovi)
import Libdovi
#endif

/// What a Dolby Vision source's own RPU says about the profile its container
/// record claims — asked only when the file contradicts itself.
///
/// A Profile 5 record over a VUI that declares BT.2020 **YCbCr** with a PQ or
/// HLG transfer is a container at odds with its bitstream: IPT-PQc2 has no VUI
/// code point, so a genuine Profile 5 leaves both fields unspecified. Served as
/// the record asks — `dvh1`, `dvcC` profile 5, `dvh1.05.LL` — the Dolby Vision
/// decoder reads that YCbCr as IPT, and the picture is wrong on *every* display
/// and with every manifest: the signalling is correct for the record, the
/// record is not correct for the picture. Nothing in the sample entry or the
/// playlist can repair that, which is why getting the profile right is the fix.
///
/// The RPU settles which half is lying without a heuristic: a Profile 5 RPU
/// cannot carry a residual or an NLQ, so an RPU libdovi reads as 7 or 8 was
/// authored for that profile, and the record was relabelled. The correction
/// then costs no new packaging — a 7 takes the existing P7 → 8.1 conversion,
/// an 8 the 8.1 / 8.4 route, both with a record rewritten to match.
///
/// The gate is what keeps this free: only the contradicted pairing reads a
/// packet. A genuine Profile 5 (VUI unspecified) never does, and an RPU that
/// reads 5, cannot be read, or names anything else leaves the record standing.
enum DolbyVisionRecordAudit {

    /// Video packets to walk looking for the first RPU. Every Dolby Vision
    /// access unit carries one, so the first packet normally answers; the
    /// budget only covers a demuxer that hands over a non-picture packet first.
    static let videoPacketBudget = 8

    /// `unspec62`: the NAL type Dolby Vision carries its RPU in.
    private static let nalTypeRPU: UInt8 = 62

    /// Whether this record contradicts the VUI it rides over — the only case
    /// the RPU is read for. HEVC only: an AV1 Profile 10.0 carries its RPU in
    /// a metadata OBU, which the NAL walk cannot reach.
    static func recordIsContradicted(
        _ record: DolbyVisionConfiguration?,
        codecName: String,
        colorTransferName: String?,
        colorSpaceName: String?
    ) -> Bool {
        guard codecName == "hevc", let record, record.isSingleLayerDVOnly else { return false }
        return DolbyVisionPreference.vuiDeclaresYCbCrHDRBase(
            colorTransferName: colorTransferName, colorSpaceName: colorSpaceName
        )
    }

    /// The record the session should believe, or `nil` to leave the source's
    /// standing.
    ///
    /// Only a 7 or an 8 out of a Profile 5 record is a correction; both have a
    /// route already. The compatibility id is the one the base layer the VUI
    /// declares implies — 6 (Blu-ray HDR10) for a 7, 4 for an HLG 8, 1 for a
    /// PQ 8 — because the relabelled record's own 0 describes no base at all.
    static func correctedRecord(
        _ record: DolbyVisionConfiguration,
        rpuProfile: UInt8?,
        colorTransferName: String?
    ) -> DolbyVisionConfiguration? {
        guard record.isSingleLayerDVOnly, let rpuProfile, rpuProfile == 7 || rpuProfile == 8 else { return nil }
        let compatibility: UInt8 = rpuProfile == 7 ? 6 : (colorTransferName == "arib-std-b67" ? 4 : 1)
        return DolbyVisionConfiguration(
            versionMajor: record.versionMajor,
            versionMinor: record.versionMinor,
            profile: rpuProfile,
            level: record.level,
            rpuPresent: true,
            // A relabelled 7 still carries its `unspec63` enhancement layer,
            // and the conversion is what drops it.
            enhancementLayerPresent: rpuProfile == 7,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: compatibility
        )
    }

    /// The range a corrected record's base layer is served as — what the
    /// probe would have said had the record been right (it reads every
    /// Profile 5 as PQ from the profile alone).
    static func dynamicRange(of corrected: DolbyVisionConfiguration) -> DynamicRange {
        corrected.baseLayerSignalCompatibilityID == 4 ? .hlg : .pq
    }

    /// The profile libdovi guesses from the first RPU in one compressed video
    /// packet, or `nil` when the packet carries none it can parse.
    static func rpuProfile(
        inPacket bytes: UnsafeBufferPointer<UInt8>,
        framing: HEVCNALUnits.Framing
    ) -> UInt8? {
        var found: UInt8?
        HEVCNALUnits.scan(bytes, framing: framing, codec: .hevc) { type, payload in
            guard found == nil, type == nalTypeRPU else { return }
            // libdovi wants the whole NAL, header included; the walk hands
            // over the payload after it. `7C 01` is the only header an RPU
            // has (type 62, layer 0, temporal id 1).
            found = guessedProfile(ofRPU: [0x7C, 0x01] + Array(payload))
        }
        return found
    }

    private static func guessedProfile(ofRPU nal: [UInt8]) -> UInt8? {
        #if canImport(Libdovi)
        return nal.withUnsafeBufferPointer { buffer -> UInt8? in
            guard let base = buffer.baseAddress,
                  let rpu = dovi_parse_unspec62_nalu(base, buffer.count)
            else { return nil }
            defer { dovi_rpu_free(rpu) }
            guard let header = dovi_rpu_get_header(rpu) else { return nil }
            defer { dovi_rpu_free_header(header) }
            return header.pointee.guessed_profile
        }
        #else
        // No libdovi, no reading: the record stands, as it did before.
        return nil
        #endif
    }

    /// Wall clock the audit may spend. It runs before the master exists, so a
    /// stalled read must not hold startup: on expiry the blocked read is
    /// aborted through the context's `ReadInterruptGuard` and the record
    /// stands, as for an RPU that could not be read.
    static let timeBudget: Duration = .milliseconds(500)
    /// Bytes of source it may read. The first RPU sits in the first video
    /// packet; this only covers a head interleaved with large audio packets.
    static let byteBudget: Int64 = 4 << 20

    /// Rewind to the head and consume video packets until the first parseable
    /// RPU. The rewind is not optional: the caption and TrueHD scouts run
    /// first and may have read to EOF on a short source, and an audit starting
    /// there would read nothing and leave a relabelled record standing.
    /// **Leaves the read position where it stopped** and the AVIO error clear;
    /// the caller rewinds to the head again, as after every other scout. `nil`
    /// for an input that cannot rewind, a read failure, an exhausted budget,
    /// or no RPU within the packet budget.
    static func scan(
        input: UnsafeMutablePointer<AVFormatContext>,
        video: VideoTrackInfo,
        interruptGuard: ReadInterruptGuard? = nil,
        byteBudget: Int64 = byteBudget,
        timeBudget: Duration = timeBudget
    ) -> UInt8? {
        let streamIndex = Int32(video.streamIndex)
        guard streamIndex >= 0, streamIndex < Int32(input.pointee.nb_streams),
              let stream = input.pointee.streams[Int(streamIndex)],
              let carriage = HEVCNALUnits.carriage(
                  codecID: stream.pointee.codecpar.pointee.codec_id,
                  nalUnitLengthSize: video.nalUnitLengthSize
              ), carriage.codec == .hevc,
              let pb = input.pointee.pb, pb.pointee.seekable != 0,
              let packet = av_packet_alloc()
        else { return nil }
        var packetRef: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetRef) }

        let started = ContinuousClock.now
        // Without a guard nothing can interrupt a read that blocks, so the
        // clock is also checked between reads; production passes the
        // context's own guard. Armed before the seek: over HTTP the rewind is
        // a Range request too.
        interruptGuard?.arm(budget: timeBudget)
        defer {
            interruptGuard?.disarm()
            // An aborted read latches AVERROR_EXIT in the AVIOContext and
            // every later read would return it; the head rewind and the copy
            // loop need it gone (as `TrueHDAtmosScout.scan` does).
            if interruptGuard != nil, pb.pointee.error < 0 { pb.pointee.error = 0 }
        }
        guard av_seek_frame(input, -1, 0, AVSEEK_FLAG_BACKWARD) >= 0 else { return nil }
        avformat_flush(input)
        let startByte = avio_tell(pb)

        let packetCap = videoPacketBudget * HDR10PlusScout.packetsPerVideoPacket
        var videoPackets = 0
        var packets = 0
        while videoPackets < videoPacketBudget, packets < packetCap,
              ContinuousClock.now - started < timeBudget,
              avio_tell(pb) - startByte < byteBudget {
            guard av_read_frame(input, packet) >= 0 else { return nil }
            defer { av_packet_unref(packet) }
            packets += 1
            guard packet.pointee.stream_index == streamIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0
            else { continue }
            videoPackets += 1
            let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
            if let profile = rpuProfile(inPacket: bytes, framing: carriage.framing) {
                return profile
            }
        }
        return nil
    }
}
