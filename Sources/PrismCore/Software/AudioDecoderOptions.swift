import Foundation
import Libavcodec
import Libavutil

/// Decoder settings every audio decode in the engine shares, applied between
/// `avcodec_alloc_context3` and `avcodec_open2`.
enum AudioDecoderOptions {

    /// Turn off the dynamic range compression FFmpeg's AC-3 / E-AC-3 decoders
    /// apply by default (`drc_scale` 1 obeys the bitstream's `dynrng` words).
    ///
    /// Why: the same track stream-copied plays through AVFoundation at full
    /// dynamics, so a software-path, Dialogue Boost or cached-clip decode came
    /// out squashed and about 2 dB quieter in dialogue than the passthrough it
    /// sits next to — audible on every switch between the two.
    ///
    /// No-op for any other codec. A failure is logged, never thrown: a
    /// compressed decode is still a decode, and refusing to play over it would
    /// be the worse outcome.
    static func apply(to context: UnsafeMutablePointer<AVCodecContext>) {
        let codecID = context.pointee.codec_id
        guard codecID == AV_CODEC_ID_AC3 || codecID == AV_CODEC_ID_EAC3 else { return }
        // `drc_scale` is a private option, so it lives on `priv_data`, which
        // `avcodec_alloc_context3(decoder)` allocates — nil means the context
        // was allocated without a codec and has nowhere to put it.
        let result: Int32
        if let options = context.pointee.priv_data {
            result = av_opt_set_double(options, "drc_scale", 0, 0)
        } else {
            result = swift_AVERROR(EINVAL)
        }
        if result < 0 {
            let name = avcodec_get_name(codecID).map { String(cString: $0) } ?? "unknown"
            PrismCoreLog.notice("\(name) decoder keeps its dynamic range compression: "
                + FFmpegError(code: result, operation: "av_opt_set_double(drc_scale)").message)
        }
    }
}
