import Foundation
import Libavcodec
import Libavutil

/// What the *linked* FFmpeg can decode on the software path.
///
/// Phase 7 exists for codecs AVPlayer's HLS-fMP4 pipeline refuses, so the first
/// question any routing decision asks is "does this build even have a decoder
/// for it". That answer belongs to the binary, not to a table in our source:
/// PrismCore links MPVKit's FFmpeg, Aether links its own MPVKit fork, and a
/// configure flag either side of that line changes the answer. Hardcoding a
/// codec list is how a router ends up promising a decode that fails at open.
///
/// So this is a runtime read of `avcodec_find_decoder` plus
/// `avcodec_get_hw_config`, over the codec set phase 7 cares about. It is also
/// what the availability test prints, which is the only honest way to document
/// "what MPVKit ships" in a repo that doesn't own the FFmpeg build.
///
/// Hardware note: several of these codecs (VP9, MPEG-2, MPEG-4 ASP, H.264,
/// HEVC) carry a `videotoolbox` hwaccel config in MPVKit's build, so "software
/// path" is a routing name, not a promise about where the decode happens —
/// `SoftwareVideoDecoder` takes the VideoToolbox route when it exists (see its
/// docs) and only falls back to CPU decoding.
public struct SoftwareDecoderAvailability: Sendable, Equatable {

    public enum MediaType: String, Sendable, Equatable {
        case video
        case audio
    }

    public struct Entry: Sendable, Equatable {
        /// FFmpeg's canonical codec name ("vp9", "mpeg2video", "vorbis").
        public let codecName: String
        public let mediaType: MediaType
        /// The decoder `avcodec_find_decoder` picks, or `nil` when this build
        /// has none. Not always the codec name: AV1 resolves to `libdav1d`.
        public let decoderName: String?
        /// Whether that decoder advertises a VideoToolbox hwaccel config, i.e.
        /// whether `SoftwareVideoDecoder` can hand it to the GPU and get
        /// `CVPixelBuffer`s back without a pixel copy.
        public let supportsVideoToolbox: Bool

        public var isAvailable: Bool { decoderName != nil }
    }

    public let entries: [Entry]

    /// The codecs phase 7 is *for* — everything the README lists as unable to
    /// ride the native path — plus the audio those containers carry, since the
    /// software path has to decode its own audio too (there is no stream-copy
    /// to hide behind here).
    private static let videoCodecs: [AVCodecID] = [
        AV_CODEC_ID_VP9, AV_CODEC_ID_VP8,
        AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_MPEG1VIDEO,
        AV_CODEC_ID_MPEG4, AV_CODEC_ID_VC1, AV_CODEC_ID_WMV3,
        AV_CODEC_ID_AV1, AV_CODEC_ID_THEORA,
        // H.264 and HEVC are here because interlaced H.264 routes to this path
        // for deinterlacing, and because a source the native path rejected for
        // an unrelated reason still has to decode somewhere.
        AV_CODEC_ID_H264, AV_CODEC_ID_HEVC,
    ]

    private static let audioCodecs: [AVCodecID] = [
        AV_CODEC_ID_VORBIS, AV_CODEC_ID_OPUS,
        AV_CODEC_ID_MP3, AV_CODEC_ID_MP2,
        AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3,
        AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC,
        AV_CODEC_ID_DTS, AV_CODEC_ID_TRUEHD,
        AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_WMAV2,
    ]

    /// Read the linked FFmpeg. Cheap (a table lookup per codec) and total — it
    /// opens nothing.
    public static func report() -> SoftwareDecoderAvailability {
        var entries: [Entry] = []
        for id in videoCodecs {
            entries.append(makeEntry(id, mediaType: .video))
        }
        for id in audioCodecs {
            entries.append(makeEntry(id, mediaType: .audio))
        }
        return SoftwareDecoderAvailability(entries: entries)
    }

    private static func makeEntry(_ id: AVCodecID, mediaType: MediaType) -> Entry {
        let codecName = avcodec_get_name(id).map { String(cString: $0) } ?? "unknown"
        guard let decoder = avcodec_find_decoder(id) else {
            return Entry(
                codecName: codecName,
                mediaType: mediaType,
                decoderName: nil,
                supportsVideoToolbox: false
            )
        }
        return Entry(
            codecName: codecName,
            mediaType: mediaType,
            decoderName: decoder.pointee.name.map { String(cString: $0) },
            supportsVideoToolbox: hasVideoToolboxConfig(decoder)
        )
    }

    /// Walk the decoder's hwaccel configs looking for VideoToolbox. Presence of
    /// a config means the *build* supports it; whether a given clip's profile
    /// and dimensions are decodable is only knowable at `avcodec_open2` time,
    /// which is why `SoftwareVideoDecoder` keeps a CPU fallback either way.
    private static func hasVideoToolboxConfig(_ decoder: UnsafePointer<AVCodec>) -> Bool {
        var index: Int32 = 0
        while let config = avcodec_get_hw_config(decoder, index) {
            if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
               config.pointee.methods & Int32(AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 {
                return true
            }
            index += 1
        }
        return false
    }

    public func entry(for codecName: String) -> Entry? {
        entries.first { $0.codecName == codecName }
    }

    public func isAvailable(_ codecName: String) -> Bool {
        entry(for: codecName)?.isAvailable ?? false
    }

    /// One line per codec, for logs and for the availability test's output —
    /// the artefact that documents the FFmpeg build we actually got.
    public var summary: String {
        entries.map { entry in
            let decoder = entry.decoderName ?? "MISSING"
            let hardware = entry.supportsVideoToolbox ? " +videotoolbox" : ""
            return "\(entry.mediaType.rawValue) \(entry.codecName): \(decoder)\(hardware)"
        }
        .joined(separator: "\n")
    }
}
