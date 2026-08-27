import Foundation
import CoreVideo
import Libavutil
import Libswscale

/// Moves a CPU-decoded `AVFrame` into a `CVPixelBuffer` the display layer can
/// take.
///
/// This is the copy path, and it is a copy on purpose. No libavcodec *software*
/// decoder emits NV12 — they all write planar YUV (`yuv420p` for VP9/VP8/MPEG-2
/// Profile Main, `yuv420p10le` for 10-bit VP9, `yuv422p`/`yuv444p` for the
/// professional odds and ends) — while `AVSampleBufferDisplayLayer` wants a
/// biplanar `CVPixelBuffer`. Something has to interleave chroma, so:
///
/// - **Zero-copy exists, but not here.** It exists one layer up: when the
///   decoder runs through the VideoToolbox hwaccel, VideoToolbox allocates the
///   `CVPixelBuffer` itself and libavcodec hands it back in `frame.data[3]`, so
///   `SoftwareVideoDecoder` retains it and never touches a pixel. That is the
///   preferred route and this type is not involved in it.
/// - **The theoretical third option** is `AVCodecContext.get_buffer2` writing
///   the decoder's planes straight into a locked `CVPixelBuffer` of a *planar*
///   CoreVideo format (`kCVPixelFormatType_420YpCbCr8Planar`), which would be
///   zero-copy on the CPU path too. It needs the decoder's alignment and
///   padding requirements honoured per plane, and it constrains the layer to a
///   planar format; not worth it while the hwaccel covers the codecs that
///   matter. Documented rather than done.
///
/// Destination format follows the source's depth: 8-bit → NV12, deeper → P010
/// (10-bit MSB-aligned, the same layout VideoToolbox produces for HDR HEVC).
/// Truncating a 10-bit VP9 to NV12 to satisfy "request NV12" would throw away
/// the depth this path exists to deliver.
final class PixelBufferTransfer {

    enum Failure: Error, CustomStringConvertible {
        case unsupportedPixelFormat(String)
        case poolCreationFailed(CVReturn)
        case pixelBufferCreationFailed(CVReturn)
        case scalerCreationFailed
        case lockFailed(CVReturn)

        var description: String {
            switch self {
            case .unsupportedPixelFormat(let name):
                return "no CoreVideo destination for pixel format \(name)"
            case .poolCreationFailed(let status):
                return "CVPixelBufferPoolCreate failed (\(status))"
            case .pixelBufferCreationFailed(let status):
                return "CVPixelBufferPoolCreatePixelBuffer failed (\(status))"
            case .scalerCreationFailed:
                return "sws_getContext failed"
            case .lockFailed(let status):
                return "CVPixelBufferLockBaseAddress failed (\(status))"
            }
        }
    }

    /// The CoreVideo format we transfer into, paired with the FFmpeg format
    /// `sws_scale` has to produce for it.
    private struct Destination {
        let coreVideoFormat: OSType
        let ffmpegFormat: AVPixelFormat
    }

    private let width: Int32
    private let height: Int32
    private let sourceFormat: AVPixelFormat
    private let destination: Destination
    private var pool: CVPixelBufferPool?
    private var scaler: UnsafeMutablePointer<SwsContext>?

    /// - Parameters:
    ///   - width/height: the decoder's coded output size.
    ///   - sourceFormat: the decoded frame's pixel format. Fixed for the
    ///     transfer's lifetime — a mid-stream format change makes
    ///     `SoftwareVideoDecoder` build a new transfer rather than mutate this
    ///     one, so the pool never holds buffers of two shapes.
    ///   - fullRange: the frame's colour range, which picks between the video-
    ///     and full-range CoreVideo formats. Getting this wrong is visible as
    ///     washed-out or crushed blacks, and VP9 in WebM is routinely full range.
    init(width: Int32, height: Int32, sourceFormat: AVPixelFormat, fullRange: Bool) throws {
        self.width = max(1, width)
        self.height = max(1, height)
        self.sourceFormat = sourceFormat
        self.destination = try Self.destination(for: sourceFormat, fullRange: fullRange)

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: destination.coreVideoFormat,
            kCVPixelBufferWidthKey: Int(self.width),
            kCVPixelBufferHeightKey: Int(self.height),
            // Without an IOSurface backing, the display layer has to copy the
            // buffer again to get it onto the GPU. Empty dictionary = defaults.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            // A pool without a minimum count still allocates on demand; the
            // floor just keeps a decode-ahead window's worth warm.
            [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        guard poolStatus == kCVReturnSuccess, let pool else {
            throw Failure.poolCreationFailed(poolStatus)
        }
        self.pool = pool

        // `sws_alloc_context` + options rather than `sws_getContext`: the
        // convenience constructor has no way to ask for slice threading, and
        // this conversion runs on the feed queue in series with the decode —
        // at 1080p it is a couple of milliseconds per frame on one core, which
        // is the difference between keeping up and not on the A-series parts
        // this path exists for.
        guard let scaler = sws_alloc_context() else {
            throw Failure.scalerCreationFailed
        }
        self.scaler = scaler
        let options = UnsafeMutableRawPointer(scaler)
        av_opt_set_int(options, "srcw", Int64(self.width), 0)
        av_opt_set_int(options, "srch", Int64(self.height), 0)
        av_opt_set_int(options, "src_format", Int64(sourceFormat.rawValue), 0)
        av_opt_set_int(options, "dstw", Int64(self.width), 0)
        av_opt_set_int(options, "dsth", Int64(self.height), 0)
        av_opt_set_int(options, "dst_format", Int64(destination.ffmpegFormat.rawValue), 0)
        // SWS_POINT, not bilinear: this is a pixel-format conversion at
        // identical dimensions, so there is nothing to interpolate and the
        // cheapest kernel is also the exact one.
        av_opt_set_int(options, "sws_flags", Int64(SWS_POINT.rawValue), 0)
        // Slices are cheap to split and the conversion is embarrassingly
        // parallel; capped so a many-core Mac does not spin up eight threads
        // for a 480p frame that one finishes in the time it takes to wake them.
        av_opt_set_int(options, "threads", Int64(Self.conversionThreads), 0)
        guard sws_init_context(scaler, nil, nil) >= 0 else {
            sws_freeContext(scaler)
            self.scaler = nil
            throw Failure.scalerCreationFailed
        }
    }

    static let conversionThreads = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))

    /// Memory pressure: give back every buffer the pool holds that no frame
    /// references. The pool refills on demand, so the cost is one allocation
    /// per frame until the window is warm again — cheaper than being killed.
    func releaseIdleBuffers() {
        guard let pool else { return }
        CVPixelBufferPoolFlush(pool, [.excessBuffers])
    }

    deinit {
        if let scaler {
            sws_freeContext(scaler)
        }
    }

    /// True when this transfer still matches the frame it is handed — the
    /// decoder's cheap "may I reuse it" check.
    func matches(width: Int32, height: Int32, format: AVPixelFormat) -> Bool {
        self.width == width && self.height == height && sourceFormat == format
    }

    /// Convert one decoded frame. The returned buffer is caller-owned (retained
    /// by the `CMSampleBuffer` it goes into); when that releases, it returns to
    /// the pool.
    func transfer(_ frame: UnsafeMutablePointer<AVFrame>) throws -> CVPixelBuffer {
        guard let pool, let scaler else { throw Failure.scalerCreationFailed }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw Failure.pixelBufferCreationFailed(status)
        }

        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else { throw Failure.lockFailed(lockStatus) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        // swscale takes 4 plane pointers and 4 strides regardless of how many
        // the format uses; the unused tail stays nil/0.
        var destinationPlanes = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
        var destinationStrides = [Int32](repeating: 0, count: 4)
        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        if planeCount == 0 {
            destinationPlanes[0] = CVPixelBufferGetBaseAddress(buffer)?
                .assumingMemoryBound(to: UInt8.self)
            destinationStrides[0] = Int32(CVPixelBufferGetBytesPerRow(buffer))
        } else {
            for plane in 0..<min(planeCount, 4) {
                destinationPlanes[plane] = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)?
                    .assumingMemoryBound(to: UInt8.self)
                destinationStrides[plane] = Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
            }
        }

        // `AVFrame.data` is a fixed-size C tuple; withUnsafeBytes over the
        // whole frame's data/linesize members is how Swift reaches it as an
        // array without transcribing eight tuple members by hand.
        let scaled = withUnsafePointer(to: &frame.pointee.data) { dataTuple in
            withUnsafePointer(to: &frame.pointee.linesize) { linesizeTuple in
                let sourcePlanes = UnsafeRawPointer(dataTuple)
                    .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                let sourceStrides = UnsafeRawPointer(linesizeTuple)
                    .assumingMemoryBound(to: Int32.self)
                return sws_scale(
                    scaler,
                    sourcePlanes, sourceStrides, 0, height,
                    &destinationPlanes, &destinationStrides
                )
            }
        }
        try FFmpegError.check(scaled, "sws_scale")

        Self.attachColorProperties(of: frame, to: buffer)
        return buffer
    }

    // MARK: - Format mapping

    private static func destination(for format: AVPixelFormat, fullRange: Bool) throws -> Destination {
        guard let descriptor = av_pix_fmt_desc_get(format) else {
            throw Failure.unsupportedPixelFormat("\(format.rawValue)")
        }
        let depth = Int(descriptor.pointee.comp.0.depth)
        // Alpha would need a 4:4:4:4 destination and nothing in phase 7's codec
        // set carries it; refuse rather than silently drop the channel.
        let hasAlpha = descriptor.pointee.flags & UInt64(AV_PIX_FMT_FLAG_ALPHA) != 0
        guard !hasAlpha else {
            throw Failure.unsupportedPixelFormat(name(of: format))
        }

        if depth <= 8 {
            return Destination(
                coreVideoFormat: fullRange
                    ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ffmpegFormat: AV_PIX_FMT_NV12
            )
        }
        // P010 is 10 bits in the high bits of a 16-bit word, which is exactly
        // what CoreVideo's 'x420'/'xf20' expect — the same pair VideoToolbox
        // hands out for 10-bit HEVC, so the layer path downstream is identical.
        return Destination(
            coreVideoFormat: fullRange
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            ffmpegFormat: AV_PIX_FMT_P010LE
        )
    }

    private static func name(of format: AVPixelFormat) -> String {
        av_get_pix_fmt_name(format).map { String(cString: $0) } ?? "\(format.rawValue)"
    }

    /// Copy the frame's colour tags onto the pixel buffer.
    ///
    /// The display layer has no other way to know: a `CVPixelBuffer` without
    /// these attachments is rendered against the platform default (Rec. 709),
    /// so a BT.601 DVD rip comes out with shifted skin tones and a BT.2020/PQ
    /// source comes out grey. Unknown tags are left off deliberately — an
    /// absent attachment lets the compositor apply its own default, a wrong one
    /// cannot be argued with.
    private static func attachColorProperties(
        of frame: UnsafeMutablePointer<AVFrame>,
        to buffer: CVPixelBuffer
    ) {
        switch frame.pointee.colorspace {
        case AVCOL_SPC_BT709:
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M:
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL:
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        default:
            break
        }

        switch frame.pointee.color_primaries {
        case AVCOL_PRI_BT709:
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        case AVCOL_PRI_BT470BG:
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_EBU_3213, .shouldPropagate)
        case AVCOL_PRI_SMPTE170M:
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        case AVCOL_PRI_BT2020:
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        default:
            break
        }

        switch frame.pointee.color_trc {
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M:
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        case AVCOL_TRC_SMPTE2084:
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        case AVCOL_TRC_ARIB_STD_B67:
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        default:
            break
        }
    }
}
