import Foundation

/// Reads whether a Dolby TrueHD stream carries **Atmos** — the 16-channel
/// object presentation — out of its major sync.
///
/// ## Why this has to exist
///
/// The bridge cannot keep the objects: FFmpeg's TrueHD decoder stops at the
/// third substream (the 7.1 presentation) and nothing public re-encodes objects
/// (see the README's *Dolby Atmos from TrueHD*). What a host can still do is
/// tell the viewer so — and for that the engine has to know the source had
/// them. `AVCodecParameters.profile` (`AV_PROFILE_TRUEHD_ATMOS`) is the same
/// kind of claim the E-AC-3 JOC flag is: filled in only if
/// `avformat_find_stream_info` happened to decode a frame inside its read cap,
/// silent otherwise. The major sync is a few bytes at the front of every
/// restart access unit and says it outright.
///
/// ## Layout (MLP / TrueHD, as `libavcodec/mlp_parse.c` reads it)
///
/// An access unit opens with 4 bytes: a check nibble plus a 12-bit length in
/// 16-bit words, then the input timing. A restart unit follows that with the
/// major sync: `F8 72 6F BA` (TrueHD; `BB` is legacy MLP, which has no object
/// presentation), 4 bytes of format info, the `B7 52` signature, and — 16
/// bytes into the sync — `num_substreams` in the high nibble, then the
/// `substream_info` byte. Atmos is four substreams with the top bit of
/// `substream_info` set: the fourth substream is the 16-channel presentation.
///
/// Best-effort by design, like `EAC3Syncframe`: anything truncated or
/// unexpected is "no answer", and the header checksum is not verified — a
/// false read could only mislabel a track, never touch the audio.
enum TrueHDMajorSync {

    /// `true` / `false` when an access unit in `bytes` carries a TrueHD major
    /// sync (Atmos or not), `nil` when none does — most units are not restart
    /// units, so `nil` means "ask the next packet", not "no Atmos".
    ///
    /// - Parameter bytes: one demuxed packet; access units are expected to
    ///   start at offset zero, which is how libavformat's parser delivers them.
    static func carriesObjectAudio(in bytes: UnsafeBufferPointer<UInt8>) -> Bool? {
        var offset = 0
        while offset + 4 <= bytes.count {
            let words = (Int(bytes[offset] & 0x0F) << 8) | Int(bytes[offset + 1])
            // A zero length cannot advance; the unit is malformed, stop.
            guard words > 0 else { return nil }
            if let answer = majorSync(at: offset + 4, of: bytes) { return answer }
            offset += words * 2
        }
        return nil
    }

    /// Whether the packet's FIRST access unit is a restart unit — the only place a decoder can
    /// start, and so where the heights renderer anchors its clock after a start or a seek.
    static func startsWithMajorSync(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        majorSync(at: 4, of: bytes) != nil
    }

    static func carriesObjectAudio(in bytes: [UInt8]) -> Bool? {
        bytes.withUnsafeBufferPointer { carriesObjectAudio(in: $0) }
    }

    private static func majorSync(at offset: Int, of bytes: UnsafeBufferPointer<UInt8>) -> Bool? {
        guard offset + 18 <= bytes.count,
              bytes[offset] == 0xF8, bytes[offset + 1] == 0x72, bytes[offset + 2] == 0x6F,
              bytes[offset + 8] == 0xB7, bytes[offset + 9] == 0x52
        else { return nil }
        switch bytes[offset + 3] {
        case 0xBA:
            let substreams = bytes[offset + 16] >> 4
            return substreams == 4 && bytes[offset + 17] & 0x80 != 0
        case 0xBB:
            return false
        default:
            return nil
        }
    }
}
