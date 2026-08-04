import Foundation
import CoreMedia
import CoreVideo
import Libavcodec
import Libavformat
import Libavutil

/// One video elementary stream, decoded with libavcodec into `CMSampleBuffer`s
/// carrying `CVPixelBuffer`s — the input `AVSampleBufferDisplayLayer` takes.
///
/// This is phase 7's reason to exist: VP9/VP8, MPEG-2, MPEG-4 ASP, VC-1 and
/// interlaced H.264 cannot ride AVPlayer's HLS-fMP4 pipeline (AVPlayer parses
/// `vp09` in a CODECS attribute and simply stops fetching; the legacy codecs
/// aren't in Apple's HLS authoring spec at all), so PrismCore has to render
/// them itself.
///
/// **Where the pixels come from, in order of preference:**
///
/// 1. **VideoToolbox hwaccel — zero copy.** MPVKit's FFmpeg is built with the
///    `videotoolbox` hwaccel for vp9/mpeg2video/mpeg4/h264/hevc (see
///    `SoftwareDecoderAvailability`). Selecting `AV_PIX_FMT_VIDEOTOOLBOX` in
///    `get_format` makes VideoToolbox do the decode and hand back frames whose
///    `data[3]` *is* a `CVPixelBuffer` — NV12 (or P010 for 10-bit) allocated by
///    VideoToolbox, IOSurface-backed, ready for the layer. We retain it and
///    touch no pixels. Note what this means for the phase's own name: VP9 on
///    this path is hardware-decoded, it is only *routed* as "software" because
///    AVPlayer won't take the container.
/// 2. **CPU decode + `PixelBufferTransfer`.** For codecs with no hwaccel (VC-1,
///    VP8, AV1 via libdav1d) or when hardware open/decode fails, libavcodec
///    decodes to planar YUV and one conversion copy per frame lands it in a
///    pooled `CVPixelBuffer`. See that type for why the copy is unavoidable
///    there and what the zero-copy variant would cost.
///
/// The hardware attempt is *provisional*: `avcodec_open2` succeeding proves
/// nothing about a particular clip (VideoToolbox rejects unsupported profiles,
/// odd dimensions, and some 4:2:2 sources only when the first frame arrives).
/// So a hardware failure inside the decode loop reopens the codec on the CPU
/// path and replays from the next keyframe rather than failing the session —
/// falling back is the whole point of having two paths.
///
/// Timestamps are the stream's own, rescaled to `CMTime` on the stream time
/// base: the pipeline's synchronizer is the master clock and both renderers
/// must be on one timeline, so a zero-based video axis is not an option.
final class SoftwareVideoDecoder {

    enum Failure: Error, CustomStringConvertible {
        case decoderUnavailable(String)
        case allocationFailed(String)
        case formatDescriptionFailed(OSStatus)
        case sampleBufferCreationFailed(OSStatus)

        var description: String {
            switch self {
            case .decoderUnavailable(let name):
                return "FFmpeg build has no decoder for \(name)"
            case .allocationFailed(let what):
                return "\(what) allocation failed"
            case .formatDescriptionFailed(let status):
                return "CMVideoFormatDescriptionCreateForImageBuffer failed (\(status))"
            case .sampleBufferCreationFailed(let status):
                return "CMSampleBufferCreateReadyWithImageBuffer failed (\(status))"
            }
        }
    }

    /// How the frames reaching `emit` were produced. Diagnostics, and the
    /// answer to "is this clip actually costing us CPU".
    enum PixelRoute: String, Equatable {
        /// VideoToolbox allocated the `CVPixelBuffer`; no pixel was copied.
        case videoToolboxZeroCopy
        /// libavcodec decoded on the CPU; one conversion copy per frame.
        case softwareCopy
    }

    typealias Emit = (CMSampleBuffer) throws -> Void

    /// Carries the desired hardware pixel format into the C `get_format`
    /// callback (which cannot capture) and the decision back out.
    ///
    /// Reference-typed and owned by the decoder: the callback reads it through
    /// `AVCodecContext.opaque`, which FFmpeg reserves for exactly this and
    /// never touches itself.
    private final class FormatSelection {
        let hardwareFormat: AVPixelFormat

        init(hardwareFormat: AVPixelFormat) {
            self.hardwareFormat = hardwareFormat
        }
    }

    // MARK: - State

    private let codecID: AVCodecID
    private let codecName: String
    private let timeBase: AVRational
    /// Fallback frame duration for containers that don't stamp one (MPEG-2 in
    /// TS, most VC-1). The display layer tolerates an invalid duration, but the
    /// synchronizer's stall detection reads better with a real one.
    private let nominalFrameDuration: CMTime
    private let allowHardware: Bool

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var hardwareDeviceContext: UnsafeMutablePointer<AVBufferRef>?
    private var formatSelection: FormatSelection?
    private var frame: UnsafeMutablePointer<AVFrame>?

    private var transfer: PixelBufferTransfer?
    private var formatDescription: CMVideoFormatDescription?

    /// Kept so a hardware failure can rebuild the context in software mode.
    /// Optional only because `avcodec_parameters_free` takes a double pointer.
    private var codecParameters: UnsafeMutablePointer<AVCodecParameters>?

    private(set) var route: PixelRoute = .softwareCopy
    /// Latched once the hardware attempt has been abandoned, so a
    /// re-open never tries it again for this stream.
    private var hardwareAbandoned = false

    /// Human-readable route, e.g. `"vp9 → videotoolbox (zero-copy)"`.
    var routeDescription: String {
        switch route {
        case .videoToolboxZeroCopy: return "\(codecName) → videotoolbox (zero-copy)"
        case .softwareCopy: return "\(codecName) → libavcodec (CPU, one conversion copy per frame)"
        }
    }

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - codecpar: the source stream's parameters. Copied, so the caller may
    ///     close the demuxer's stream while this decoder lives.
    ///   - timeBase: the stream time base; packet and frame timestamps arrive
    ///     in it and `CMTime`s are produced on it.
    ///   - averageFrameRate: `AVStream.avg_frame_rate`, used only for the
    ///     fallback frame duration.
    ///   - allowHardware: false forces the CPU path (tests, and a host that
    ///     wants deterministic pixel output).
    init(
        codecpar: UnsafePointer<AVCodecParameters>,
        timeBase: AVRational,
        averageFrameRate: AVRational = AVRational(num: 0, den: 1),
        allowHardware: Bool = true
    ) throws {
        self.codecID = codecpar.pointee.codec_id
        self.codecName = avcodec_get_name(codecID).map { String(cString: $0) } ?? "unknown"
        self.timeBase = timeBase
        self.allowHardware = allowHardware
        if averageFrameRate.num > 0, averageFrameRate.den > 0 {
            self.nominalFrameDuration = CMTime(
                value: CMTimeValue(averageFrameRate.den),
                timescale: CMTimeScale(averageFrameRate.num)
            )
        } else {
            self.nominalFrameDuration = .invalid
        }

        guard let parameters = avcodec_parameters_alloc() else {
            throw Failure.allocationFailed("codec parameters")
        }
        self.codecParameters = parameters
        try FFmpegError.check(
            avcodec_parameters_copy(parameters, codecpar),
            "avcodec_parameters_copy(video decoder)"
        )

        guard let frame = av_frame_alloc() else {
            avcodec_parameters_free(&self.codecParameters)
            throw Failure.allocationFailed("decoder frame")
        }
        self.frame = frame

        try openContext(hardware: allowHardware)
    }

    deinit {
        close()
    }

    func close() {
        av_frame_free(&frame)
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if hardwareDeviceContext != nil {
            av_buffer_unref(&hardwareDeviceContext)
        }
        avcodec_parameters_free(&codecParameters)
        transfer = nil
        formatDescription = nil
    }

    private func openContext(hardware: Bool) throws {
        guard let decoder = avcodec_find_decoder(codecID) else {
            throw Failure.decoderUnavailable(codecName)
        }
        guard let context = avcodec_alloc_context3(decoder) else {
            throw Failure.allocationFailed("video decoder context")
        }
        codecContext = context
        try FFmpegError.check(
            avcodec_parameters_to_context(context, codecParameters),
            "avcodec_parameters_to_context(video)"
        )
        context.pointee.pkt_timebase = timeBase
        // Frame threading is what makes CPU VP9/MPEG-2 keep up with real time on
        // a mobile core; 0 = "as many as the machine has".
        context.pointee.thread_count = 0

        var wantsHardware = hardware && !hardwareAbandoned
        if wantsHardware {
            do {
                try attachHardwareDevice(decoder: decoder, context: context)
            } catch {
                // No VideoToolbox device (a simulator, a locked-down sandbox):
                // that is a routing detail, not a failure.
                wantsHardware = false
            }
        }
        route = wantsHardware ? .videoToolboxZeroCopy : .softwareCopy

        try FFmpegError.check(avcodec_open2(context, decoder, nil), "avcodec_open2(video decoder)")
    }

    /// Find the decoder's VideoToolbox config, create the device, and install
    /// the `get_format` callback that actually opts into it — without the
    /// callback libavcodec picks the software format and the device is ignored.
    private func attachHardwareDevice(
        decoder: UnsafePointer<AVCodec>,
        context: UnsafeMutablePointer<AVCodecContext>
    ) throws {
        var hardwareFormat = AV_PIX_FMT_NONE
        var index: Int32 = 0
        while let config = avcodec_get_hw_config(decoder, index) {
            if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
               config.pointee.methods & Int32(AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 {
                hardwareFormat = config.pointee.pix_fmt
                break
            }
            index += 1
        }
        guard hardwareFormat != AV_PIX_FMT_NONE else {
            throw Failure.decoderUnavailable("\(codecName) videotoolbox hwaccel")
        }

        var device: UnsafeMutablePointer<AVBufferRef>?
        try FFmpegError.check(
            av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0),
            "av_hwdevice_ctx_create(videotoolbox)"
        )
        hardwareDeviceContext = device
        context.pointee.hw_device_ctx = av_buffer_ref(device)

        let selection = FormatSelection(hardwareFormat: hardwareFormat)
        formatSelection = selection
        context.pointee.opaque = Unmanaged.passUnretained(selection).toOpaque()
        context.pointee.get_format = { context, formats in
            guard let context, let formats else { return AV_PIX_FMT_NONE }
            guard let opaque = context.pointee.opaque else { return formats[0] }
            let selection = Unmanaged<FormatSelection>.fromOpaque(opaque).takeUnretainedValue()
            var index = 0
            while formats[index] != AV_PIX_FMT_NONE {
                if formats[index] == selection.hardwareFormat {
                    return formats[index]
                }
                index += 1
            }
            // Hardware wasn't offered for this stream after all (a profile the
            // hwaccel declines). The list's head is the decoder's own preferred
            // software format, which the CPU path handles — and `route` corrects
            // itself from the first frame's format, so the diagnostics don't keep
            // claiming a hardware decode that isn't happening.
            return formats[0]
        }
    }

    // MARK: - Decoding

    /// Feed one packet, or `nil` to drain at EOF. Emits every frame the decoder
    /// completed, already stamped and wrapped.
    ///
    /// A hardware decode that fails mid-stream is not propagated: the context is
    /// reopened on the CPU path and the caller is expected to keep feeding (from
    /// the next keyframe, which is where a reopened decoder starts producing).
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?, emit: Emit) throws {
        guard let context = codecContext else { return }
        let sendResult = avcodec_send_packet(context, packet)
        if sendResult < 0, sendResult != swift_AVERROR(EAGAIN), sendResult != swift_AVERROR_EOF() {
            if try recoverFromHardwareFailure() { return }
            throw FFmpegError(code: sendResult, operation: "avcodec_send_packet(video)")
        }
        try drain(emit: emit)
        if sendResult == swift_AVERROR(EAGAIN) {
            // The decoder was holding output; the drain cleared it, so the
            // packet can be offered again.
            try FFmpegError.check(
                avcodec_send_packet(context, packet),
                "avcodec_send_packet(video, retry)"
            )
            try drain(emit: emit)
        }
    }

    /// Drop everything buffered — a seek. Cheap and mandatory: without it the
    /// first frames after a seek are the pre-seek ones.
    func flushBuffers() {
        guard let context = codecContext else { return }
        avcodec_flush_buffers(context)
    }

    private func drain(emit: Emit) throws {
        guard let context = codecContext, let frame else { return }
        while true {
            let result = avcodec_receive_frame(context, frame)
            if result == swift_AVERROR(EAGAIN) || result == swift_AVERROR_EOF() { return }
            if result < 0 {
                if try recoverFromHardwareFailure() { return }
                throw FFmpegError(code: result, operation: "avcodec_receive_frame(video)")
            }
            defer { av_frame_unref(frame) }
            let sampleBuffer = try makeSampleBuffer(from: frame)
            try emit(sampleBuffer)
        }
    }

    /// If we were on the hardware route, abandon it and reopen in software.
    /// Returns true when the caller should treat the failing call as handled.
    private func recoverFromHardwareFailure() throws -> Bool {
        guard route == .videoToolboxZeroCopy, !hardwareAbandoned else { return false }
        hardwareAbandoned = true
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if hardwareDeviceContext != nil {
            av_buffer_unref(&hardwareDeviceContext)
        }
        formatSelection = nil
        // The pixel shape changes with the route, so neither the transfer nor
        // the format description survives.
        transfer = nil
        formatDescription = nil
        try openContext(hardware: false)
        return true
    }

    // MARK: - Frame → CMSampleBuffer

    private func makeSampleBuffer(from frame: UnsafeMutablePointer<AVFrame>) throws -> CMSampleBuffer {
        let pixelBuffer = try pixelBuffer(for: frame)

        if formatDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else {
                throw Failure.formatDescriptionFailed(status)
            }
            formatDescription = description
        }

        let rawPTS = frame.pointee.pts != swift_AV_NOPTS_VALUE()
            ? frame.pointee.pts
            : frame.pointee.best_effort_timestamp
        let presentationTime: CMTime = rawPTS != swift_AV_NOPTS_VALUE()
            // Time base straight into the CMTime: value = ticks × num,
            // timescale = den, so the source's exact rational survives instead
            // of going through a Double.
            ? CMTime(
                value: CMTimeValue(rawPTS * Int64(timeBase.num)),
                timescale: CMTimeScale(timeBase.den)
            )
            : .invalid
        let duration: CMTime = frame.pointee.duration > 0
            ? CMTime(
                value: CMTimeValue(frame.pointee.duration * Int64(timeBase.num)),
                timescale: CMTimeScale(timeBase.den)
            )
            : nominalFrameDuration

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            // Decode order is libavcodec's business; the layer only ever needs
            // presentation order, which is what receive_frame already gives us.
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw Failure.sampleBufferCreationFailed(status)
        }
        return sampleBuffer
    }

    /// The zero-copy fork: a VideoToolbox frame already *is* a `CVPixelBuffer`.
    private func pixelBuffer(for frame: UnsafeMutablePointer<AVFrame>) throws -> CVPixelBuffer {
        if AVPixelFormat(rawValue: frame.pointee.format) == AV_PIX_FMT_VIDEOTOOLBOX,
           let raw = frame.pointee.data.3 {
            route = .videoToolboxZeroCopy
            // `data[3]` holds the CVPixelBufferRef itself (not a pointer to it).
            // Unretained: the `CMSampleBuffer` we hand it to takes its own
            // reference, and the frame keeps this one until `av_frame_unref`.
            return Unmanaged<CVPixelBuffer>
                .fromOpaque(UnsafeRawPointer(raw))
                .takeUnretainedValue()
        }

        route = .softwareCopy
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        if transfer?.matches(width: frame.pointee.width, height: frame.pointee.height, format: format) != true {
            transfer = try PixelBufferTransfer(
                width: frame.pointee.width,
                height: frame.pointee.height,
                sourceFormat: format,
                fullRange: frame.pointee.color_range == AVCOL_RANGE_JPEG
            )
            formatDescription = nil
        }
        guard let transfer else { throw Failure.allocationFailed("pixel transfer") }
        return try transfer.transfer(frame)
    }
}
