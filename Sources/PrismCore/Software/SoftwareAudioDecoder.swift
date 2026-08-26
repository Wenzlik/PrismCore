import Foundation
import CoreMedia
import CoreAudioTypes
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// One audio elementary stream, decoded with libavcodec into LPCM
/// `CMSampleBuffer`s for `AVSampleBufferAudioRenderer`.
///
/// On the native path audio is stream-copied (or re-encoded by `AudioBridge`)
/// because AVPlayer owns the decode and a bitstream can reach HDMI intact. Here
/// there is no AVPlayer: the renderer takes PCM, so PrismCore decodes. The
/// consequence is the one the README already states for this phase — no Atmos
/// passthrough on the software path, by construction. It is the right trade for
/// VP9/MPEG-2/VC-1 sources, which essentially never carry object audio.
///
/// Output is **interleaved Float32** at the source's sample rate. Float because
/// every FFmpeg decoder can resample to it losslessly and CoreAudio treats it
/// as native; interleaved because one `CMBlockBuffer` per buffer is then one
/// contiguous allocation instead of a per-channel scatter. The rate is *not*
/// converted: resampling costs quality and CPU for nothing, since the renderer
/// resamples to the device rate anyway.
///
/// Timestamps come from `AudioClock`, not from packet PTS — see that type for
/// the clicking this avoids.
///
/// Channel layout is tagged, not guessed: mono, stereo and 5.1 map exactly onto
/// CoreAudio tags, and anything wider is downmixed by libswresample to 5.1.
/// A wrong channel map is worse than an honest downmix (surround content with
/// dialogue in the wrong speaker), and a complete FFmpeg → CoreAudio order map
/// is a follow-up this skeleton doesn't need.
final class SoftwareAudioDecoder {

    enum Failure: Error, CustomStringConvertible {
        case decoderUnavailable(String)
        case allocationFailed(String)
        case formatDescriptionFailed(OSStatus)
        case blockBufferCreationFailed(OSStatus)
        case sampleBufferCreationFailed(OSStatus)

        var description: String {
            switch self {
            case .decoderUnavailable(let name):
                return "FFmpeg build has no decoder for \(name)"
            case .allocationFailed(let what):
                return "\(what) allocation failed"
            case .formatDescriptionFailed(let status):
                return "CMAudioFormatDescriptionCreate failed (\(status))"
            case .blockBufferCreationFailed(let status):
                return "CMBlockBufferCreateWithMemoryBlock failed (\(status))"
            case .sampleBufferCreationFailed(let status):
                return "CMSampleBufferCreate failed (\(status))"
            }
        }
    }

    typealias Emit = (CMSampleBuffer) throws -> Void

    /// The PCM shape the renderer is fed.
    struct OutputFormat: Equatable {
        let sampleRate: Int32
        let channelCount: Int32
        /// Interleaved Float32.
        var bytesPerFrame: Int32 { 4 * channelCount }
    }

    // MARK: - State

    private let codecName: String
    private let sourceTimeBase: AVRational
    private(set) var outputFormat: OutputFormat

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var decodedFrame: UnsafeMutablePointer<AVFrame>?

    /// Output channel layout, owned here (it has heap storage for custom orders).
    private var outputLayout = AVChannelLayout()

    /// The resampler's currently configured *input* side. Re-derived from every
    /// decoded frame rather than trusted from `codecpar`, for the same reason
    /// `AudioBridge` does it: several decoders report `AV_SAMPLE_FMT_NONE` until
    /// a frame exists, and reading planes as the wrong format is loud noise.
    private var resamplerInputFormat = AV_SAMPLE_FMT_NONE
    private var resamplerInputRate: Int32 = 0
    private var resamplerInputLayout = AVChannelLayout()

    private var clock: AudioClock
    private var formatDescription: CMAudioFormatDescription?

    /// The clock's state, for diagnostics and tests.
    var clockState: AudioClock { clock }

    var routeDescription: String {
        "\(codecName) → LPCM f32 \(outputFormat.channelCount)ch @ \(outputFormat.sampleRate) Hz"
    }

    // MARK: - Lifecycle

    init(codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        let codecID = codecpar.pointee.codec_id
        self.codecName = avcodec_get_name(codecID).map { String(cString: $0) } ?? "unknown"
        self.sourceTimeBase = timeBase

        guard let decoder = avcodec_find_decoder(codecID) else {
            throw Failure.decoderUnavailable(codecName)
        }
        let sampleRate = codecpar.pointee.sample_rate > 0 ? codecpar.pointee.sample_rate : 48_000
        self.outputFormat = OutputFormat(sampleRate: sampleRate, channelCount: 2)
        self.clock = AudioClock(sampleRate: sampleRate)

        guard let context = avcodec_alloc_context3(decoder) else {
            throw Failure.allocationFailed("audio decoder context")
        }
        codecContext = context
        try FFmpegError.check(
            avcodec_parameters_to_context(context, codecpar),
            "avcodec_parameters_to_context(audio)"
        )
        context.pointee.pkt_timebase = timeBase
        try FFmpegError.check(avcodec_open2(context, decoder, nil), "avcodec_open2(audio decoder)")

        try configureOutputLayout(sourceChannels: codecpar.pointee.ch_layout.nb_channels)
        outputFormat = OutputFormat(sampleRate: sampleRate, channelCount: outputLayout.nb_channels)
        clock = AudioClock(sampleRate: sampleRate)

        guard let frame = av_frame_alloc() else {
            throw Failure.allocationFailed("audio decoder frame")
        }
        decodedFrame = frame
    }

    deinit {
        close()
    }

    func close() {
        av_frame_free(&decodedFrame)
        if resampler != nil {
            swr_free(&resampler)
        }
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        av_channel_layout_uninit(&outputLayout)
        av_channel_layout_uninit(&resamplerInputLayout)
        formatDescription = nil
    }

    /// mono / stereo pass through; everything else lands on 5.1.
    private func configureOutputLayout(sourceChannels: Int32) throws {
        av_channel_layout_uninit(&outputLayout)
        switch sourceChannels {
        case ..<2:
            av_channel_layout_default(&outputLayout, 1)
        case 2:
            av_channel_layout_default(&outputLayout, 2)
        default:
            // `av_channel_layout_default(…, 6)` is FFmpeg's 5.1 (FL FR FC LFE
            // BL BR), which is exactly CoreAudio's MPEG_5_1_A order — the one
            // fact that makes the tagging below correct rather than hopeful.
            av_channel_layout_default(&outputLayout, 6)
        }
    }

    // MARK: - Decoding

    /// Feed one packet, or `nil` to drain at EOF.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?, emit: Emit) throws {
        guard let context = codecContext else { return }
        let sendResult = avcodec_send_packet(context, packet)
        if sendResult < 0, sendResult != swift_AVERROR(EAGAIN), sendResult != swift_AVERROR_EOF() {
            throw FFmpegError(code: sendResult, operation: "avcodec_send_packet(audio)")
        }
        try drain(emit: emit)
        if sendResult == swift_AVERROR(EAGAIN) {
            try FFmpegError.check(
                avcodec_send_packet(context, packet),
                "avcodec_send_packet(audio, retry)"
            )
            try drain(emit: emit)
        }
    }

    /// Seek/stop: drop decoder state *and* the clock anchor, so the next buffer
    /// re-anchors on the new timeline instead of continuing the old count.
    func flushBuffers() {
        if let context = codecContext {
            avcodec_flush_buffers(context)
        }
        if resampler != nil {
            // Drop the resampler's delay line too: its contents belong to the
            // timeline we just left.
            swr_free(&resampler)
            resamplerInputFormat = AV_SAMPLE_FMT_NONE
            resamplerInputRate = 0
            av_channel_layout_uninit(&resamplerInputLayout)
        }
        clock.reset()
    }

    private func drain(emit: Emit) throws {
        guard let context = codecContext, let frame = decodedFrame else { return }
        while true {
            let result = avcodec_receive_frame(context, frame)
            if result == swift_AVERROR(EAGAIN) || result == swift_AVERROR_EOF() { return }
            try FFmpegError.check(result, "avcodec_receive_frame(audio)")
            defer { av_frame_unref(frame) }

            try reconfigureResamplerIfNeeded(for: frame)
            if let sampleBuffer = try makeSampleBuffer(from: frame) {
                try emit(sampleBuffer)
                // The buffer reached the renderer (emit throws if it didn't), so
                // and only so does the clock move — see AudioClock.
                clock.commit()
            }
        }
    }

    private func reconfigureResamplerIfNeeded(for frame: UnsafeMutablePointer<AVFrame>) throws {
        let frameFormat = AVSampleFormat(rawValue: frame.pointee.format)
        let matches = resampler != nil
            && frameFormat == resamplerInputFormat
            && frame.pointee.sample_rate == resamplerInputRate
            && av_channel_layout_compare(&frame.pointee.ch_layout, &resamplerInputLayout) == 0
        if matches { return }

        if resampler != nil {
            swr_free(&resampler)
        }
        var context: OpaquePointer?
        try FFmpegError.check(
            swr_alloc_set_opts2(
                &context,
                &outputLayout,
                AV_SAMPLE_FMT_FLT,
                outputFormat.sampleRate,
                &frame.pointee.ch_layout,
                frameFormat,
                frame.pointee.sample_rate,
                0,
                nil
            ),
            "swr_alloc_set_opts2(audio out)"
        )
        guard let context else { throw Failure.allocationFailed("resampler") }
        try FFmpegError.check(swr_init(context), "swr_init(audio out)")
        resampler = context

        resamplerInputFormat = frameFormat
        resamplerInputRate = frame.pointee.sample_rate
        av_channel_layout_uninit(&resamplerInputLayout)
        try FFmpegError.check(
            av_channel_layout_copy(&resamplerInputLayout, &frame.pointee.ch_layout),
            "av_channel_layout_copy(resampler input)"
        )
    }

    // MARK: - Frame → CMSampleBuffer

    private func makeSampleBuffer(from frame: UnsafeMutablePointer<AVFrame>) throws -> CMSampleBuffer? {
        guard let resampler else { return nil }

        let capacity = Int32(swr_get_out_samples(resampler, frame.pointee.nb_samples))
        guard capacity > 0 else { return nil }

        // The resampler writes straight into the block buffer's memory: one
        // allocation per buffer instead of a scratch conversion plus a malloc
        // plus a copy — this ran ~40 times a second, per channel set, on the
        // audio thread's budget. CoreMedia owns the allocation from the start,
        // so a buffer the renderer drops leaks nothing.
        let capacityBytes = Int(capacity) * Int(outputFormat.bytesPerFrame)
        var storage: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: capacityBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: capacityBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &storage
        )
        guard allocStatus == noErr, let storage else {
            throw Failure.blockBufferCreationFailed(allocStatus)
        }
        var payloadLength = 0
        var payload: UnsafeMutablePointer<CChar>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            storage, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &payloadLength, dataPointerOut: &payload
        )
        guard pointerStatus == noErr, let payload, payloadLength >= capacityBytes else {
            throw Failure.blockBufferCreationFailed(pointerStatus)
        }

        // One output plane (interleaved); the rest of the array stays nil, which
        // is what libswresample expects for a packed format.
        var outputPlanes: [UnsafeMutablePointer<UInt8>?] = [
            UnsafeMutableRawPointer(payload).assumingMemoryBound(to: UInt8.self), nil, nil, nil, nil, nil, nil, nil,
        ]
        let inputPlanes = UnsafeMutableRawPointer(frame.pointee.extended_data)?
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let produced = swr_convert(
            resampler, &outputPlanes, capacity, inputPlanes, frame.pointee.nb_samples
        )
        try FFmpegError.check(produced, "swr_convert(audio out)")
        guard produced > 0 else { return nil }

        let byteCount = Int(produced) * Int(outputFormat.bytesPerFrame)
        // `swr_get_out_samples` is an upper bound; the sample buffer must see
        // exactly the produced range. A reference buffer over the prefix is a
        // window onto the same memory, not another copy.
        var blockBuffer: CMBlockBuffer? = storage
        if byteCount < capacityBytes {
            var window: CMBlockBuffer?
            let windowStatus = CMBlockBufferCreateWithBufferReference(
                allocator: kCFAllocatorDefault,
                referenceBuffer: storage,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &window
            )
            guard windowStatus == noErr, let window else {
                throw Failure.blockBufferCreationFailed(windowStatus)
            }
            blockBuffer = window
        }
        guard let blockBuffer else { return nil }

        let description = try audioFormatDescription()

        // Source PTS in output samples: the clock reasons in samples so it never
        // has to divide by a time base.
        let rawPTS = frame.pointee.pts != swift_AV_NOPTS_VALUE()
            ? frame.pointee.pts
            : frame.pointee.best_effort_timestamp
        let sourceSample: Int64? = rawPTS != swift_AV_NOPTS_VALUE()
            ? av_rescale_q(rawPTS, sourceTimeBase, AVRational(num: 1, den: outputFormat.sampleRate))
            : nil
        let startSample = clock.timestamp(forSourceSample: sourceSample, sampleCount: Int(produced))

        var timing = CMSampleTimingInfo(
            // LPCM timing is per *sample*: one duration of 1/rate, and
            // `numSamples` telling CoreMedia how many of them there are.
            duration: CMTime(value: 1, timescale: CMTimeScale(outputFormat.sampleRate)),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(startSample),
                timescale: CMTimeScale(outputFormat.sampleRate)
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = Int(outputFormat.bytesPerFrame)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: CMItemCount(produced),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw Failure.sampleBufferCreationFailed(status)
        }
        return sampleBuffer
    }

    /// Built once: the LPCM description plus the channel layout tag, which is
    /// what lets the renderer route 5.1 to 5.1 instead of folding it down.
    private func audioFormatDescription() throws -> CMAudioFormatDescription {
        if let formatDescription { return formatDescription }

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Float64(outputFormat.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(outputFormat.bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(outputFormat.bytesPerFrame),
            mChannelsPerFrame: UInt32(outputFormat.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = Self.channelLayoutTag(for: outputFormat.channelCount)
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        layout.mNumberChannelDescriptions = 0

        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw Failure.formatDescriptionFailed(status)
        }
        formatDescription = description
        return description
    }

    /// Only the layouts `configureOutputLayout` can produce, so there is no
    /// "unknown layout" case to guess at.
    private static func channelLayoutTag(for channels: Int32) -> AudioChannelLayoutTag {
        switch channels {
        case 1: return kAudioChannelLayoutTag_Mono
        case 2: return kAudioChannelLayoutTag_Stereo
        // L R C LFE Ls Rs — FFmpeg's 5.1 order, channel for channel.
        default: return kAudioChannelLayoutTag_MPEG_5_1_A
        }
    }
}
