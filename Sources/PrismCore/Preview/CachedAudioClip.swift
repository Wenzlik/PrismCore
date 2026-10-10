import Foundation
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

/// Audio the session has already produced, decoded to mono PCM — what
/// `PrismCoreSession.cachedAudio(from:duration:renditionName:)` returns.
public struct CachedAudioClip: Sendable, Equatable {
    /// The first sample's time on the source axis (`residentRanges`'s), with
    /// the audio offset in force applied: the clip is what is heard there.
    public let startSeconds: Double
    /// Always 48 000.
    public let sampleRate: Double
    /// Mono Float32: the non-LFE channels averaged, the LFE dropped.
    public let samples: [Float]

    public init(startSeconds: Double, sampleRate: Double, samples: [Float]) {
        self.startSeconds = startSeconds
        self.sampleRate = sampleRate
        self.samples = samples
    }

    /// The longest clip one call returns.
    public static let maximumDuration: Double = 30
}

/// Decodes a run of produced fMP4 files with a decoder of its own. Nothing
/// here touches the producer, the demand seam or the served bytes: the input
/// is descriptors `ResidentSegmentStore.openAudioRun` opened, and the output
/// is a value.
enum CachedAudioDecoder {
    static let sampleRate = 48_000
    /// How far the decoded audio may fall short of the range at either end
    /// and still count as covering it — about one AC-3 frame. The first
    /// audio of a title (or of a rendition's first fragment) can start a
    /// frame after the video's boundary; refusing that would make the head
    /// of every title look non-resident.
    static let edgeTolerance = 0.05

    /// `nil` when the files carry no audio, or the decoded audio does not
    /// reach across `[from, from + duration]`.
    static func decode(_ files: [FileHandle], from: Double, duration: Double) async throws -> CachedAudioClip? {
        let chain = try FileChain(files)
        // The AVIO holds `chain` unretained; this keeps it alive past the
        // close below (defers run last-declared first).
        defer { withExtendedLifetime(chain) {} }
        var opened = avformat_alloc_context()
        defer { avformat_close_input(&opened) }
        guard let allocated = opened else { throw FFmpegError(code: -1, operation: "avformat_alloc_context") }
        try chain.install(on: allocated)
        try FFmpegError.check(avformat_open_input(&opened, nil, av_find_input_format("mp4"), nil), "avformat_open_input(cached audio)")
        guard let context = opened else { return nil }
        // `find_stream_info` is skipped on purpose: these are our own fMP4s,
        // whose `moov` already describes the track completely, and nothing
        // muxes from this context — the decoder's frames are the authority.
        let streamIndex = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard streamIndex >= 0, let stream = context.pointee.streams[Int(streamIndex)] else { return nil }
        for index in 0..<Int(context.pointee.nb_streams) where index != Int(streamIndex) {
            context.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL
        }
        guard let decoder = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id) else {
            throw FFmpegError(code: swift_AVERROR(ENOSYS), operation: "avcodec_find_decoder(cached audio)")
        }
        var codec = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&codec) }
        guard let codec else { throw FFmpegError(code: -1, operation: "avcodec_alloc_context3") }
        try FFmpegError.check(avcodec_parameters_to_context(codec, stream.pointee.codecpar), "avcodec_parameters_to_context")
        codec.pointee.pkt_timebase = stream.pointee.time_base
        try FFmpegError.check(avcodec_open2(codec, decoder, nil), "avcodec_open2(cached audio)")

        let end = from + duration
        var mixer = Mixer()
        defer { mixer.close() }
        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        guard let packet, let frame else { throw FFmpegError(code: -1, operation: "av_packet_alloc") }
        let timeBase = av_q2d(stream.pointee.time_base)

        func drain() throws {
            while true {
                let received = avcodec_receive_frame(codec, frame)
                if received == swift_AVERROR(EAGAIN) || received == swift_AVERROR_EOF() { return }
                try FFmpegError.check(received, "avcodec_receive_frame(cached audio)")
                defer { av_frame_unref(frame) }
                let pts = frame.pointee.best_effort_timestamp
                try mixer.append(frame, seconds: pts == swift_AV_NOPTS_VALUE() ? nil : Double(pts) * timeBase)
            }
        }
        while !mixer.covers(end) && !mixer.brokeContinuity {
            try Task.checkCancellation()
            let read = av_read_frame(context, packet)
            if read == swift_AVERROR_EOF() { break }
            try FFmpegError.check(read, "av_read_frame(cached audio)")
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex else { continue }
            let sent = avcodec_send_packet(codec, packet)
            if sent < 0, sent != swift_AVERROR(EAGAIN) { try FFmpegError.check(sent, "avcodec_send_packet(cached audio)") }
            try drain()
        }
        if !mixer.covers(end) {
            _ = avcodec_send_packet(codec, nil)
            try drain()
        }
        try mixer.flush()

        guard let first = mixer.firstSeconds else { return nil }
        let rate = Double(sampleRate)
        let wanted = Int((duration * rate).rounded())
        let tolerance = Int(edgeTolerance * rate)
        let offset = Int(((from - first) * rate).rounded())
        guard offset >= -tolerance else { return nil }
        let start = max(0, offset)
        let available = mixer.output.count - start
        guard available >= wanted - tolerance, available > 0 else { return nil }
        return CachedAudioClip(
            startSeconds: first + Double(start) / rate,
            sampleRate: rate,
            samples: Array(mixer.output[start..<(start + min(wanted, available))])
        )
    }

    /// Downmix and resample in one `SwrContext`, with an explicit matrix: the
    /// default rematrix folds the LFE and weights the centre for a listener,
    /// and a recogniser wants the programme with every speaker counted once.
    private struct Mixer {
        private(set) var output: [Float] = []
        private(set) var firstSeconds: Double?
        /// A frame arrived well after where the previous one ended — the
        /// fragments are not one continuous programme after all, so the
        /// output stops where the audio stopped being contiguous.
        private(set) var brokeContinuity = false
        private var swr: OpaquePointer?
        private var inputLayout = AVChannelLayout()
        private var inputFormat: Int32 = -1
        private var inputRate: Int32 = 0
        private var inputSeconds = 0.0

        func covers(_ end: Double) -> Bool {
            guard let firstSeconds else { return false }
            return firstSeconds + Double(output.count) / Double(CachedAudioDecoder.sampleRate) >= end
        }

        mutating func append(_ frame: UnsafeMutablePointer<AVFrame>, seconds: Double?) throws {
            guard frame.pointee.nb_samples > 0, frame.pointee.sample_rate > 0 else { return }
            if let firstSeconds {
                let expected = firstSeconds + inputSeconds
                if let seconds, seconds - expected > 0.1 { brokeContinuity = true; return }
            } else {
                guard let seconds else { return }
                firstSeconds = seconds
            }
            try configure(for: frame)
            let planes = UnsafeMutableRawPointer(frame.pointee.extended_data)?
                .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            try convert(planes, count: frame.pointee.nb_samples)
            inputSeconds += Double(frame.pointee.nb_samples) / Double(frame.pointee.sample_rate)
        }

        mutating func flush() throws {
            guard swr != nil else { return }
            try convert(nil, count: 0)
        }

        mutating func close() {
            swr_free(&swr)
            av_channel_layout_uninit(&inputLayout)
        }

        private mutating func convert(_ planes: UnsafeMutablePointer<UnsafePointer<UInt8>?>?, count: Int32) throws {
            guard let swr else { return }
            let capacity = swr_get_out_samples(swr, count)
            guard capacity > 0 else { return }
            var chunk = [Float](repeating: 0, count: Int(capacity))
            let produced = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                var out: UnsafeMutablePointer<UInt8>? = UnsafeMutableRawPointer(buffer.baseAddress!)
                    .assumingMemoryBound(to: UInt8.self)
                return swr_convert(swr, &out, capacity, planes, count)
            }
            try FFmpegError.check(produced, "swr_convert(cached audio)")
            output.append(contentsOf: chunk.prefix(Int(produced)))
        }

        /// Built on the first frame, rebuilt only if a frame arrives in
        /// another shape (a splice of two encodings): the old context's few
        /// buffered samples are the cheaper loss.
        private mutating func configure(for frame: UnsafeMutablePointer<AVFrame>) throws {
            if swr != nil, frame.pointee.format == inputFormat, frame.pointee.sample_rate == inputRate,
               av_channel_layout_compare(&frame.pointee.ch_layout, &inputLayout) == 0 {
                return
            }
            swr_free(&swr)
            var mono = AVChannelLayout()
            av_channel_layout_default(&mono, 1)
            defer { av_channel_layout_uninit(&mono) }
            var context: OpaquePointer?
            try FFmpegError.check(swr_alloc_set_opts2(
                &context, &mono, AV_SAMPLE_FMT_FLT, Int32(CachedAudioDecoder.sampleRate),
                &frame.pointee.ch_layout, AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate,
                0, nil
            ), "swr_alloc_set_opts2(cached audio)")
            guard let context else { throw FFmpegError(code: -1, operation: "swr_alloc_set_opts2(cached audio)") }
            swr = context
            let channels = Int(frame.pointee.ch_layout.nb_channels)
            let lfe = [AV_CHAN_LOW_FREQUENCY, AV_CHAN_LOW_FREQUENCY_2].map {
                Int(av_channel_layout_index_from_channel(&frame.pointee.ch_layout, $0))
            }
            var kept = (0..<channels).filter { !lfe.contains($0) }
            if kept.isEmpty { kept = Array(0..<channels) }
            var matrix = [Double](repeating: 0, count: channels)
            for channel in kept { matrix[channel] = 1 / Double(kept.count) }
            try FFmpegError.check(swr_set_matrix(context, matrix, Int32(channels)), "swr_set_matrix(cached audio)")
            try FFmpegError.check(swr_init(context), "swr_init(cached audio)")
            inputFormat = frame.pointee.format
            inputRate = frame.pointee.sample_rate
            av_channel_layout_uninit(&inputLayout)
            try FFmpegError.check(av_channel_layout_copy(&inputLayout, &frame.pointee.ch_layout), "av_channel_layout_copy")
        }
    }
}

/// The opened files read as one seekable stream, by `pread`: positioned
/// reads share no cursor, and a descriptor keeps its bytes after an
/// eviction unlinks the name.
private final class FileChain {
    private static let bufferSize = 32768
    private let files: [FileHandle]
    /// Where each file starts in the chain, plus the total at the end.
    private let starts: [Int64]
    private var position: Int64 = 0
    private var io: UnsafeMutablePointer<AVIOContext>?

    init(_ files: [FileHandle]) throws {
        self.files = files
        var starts: [Int64] = [0]
        for file in files {
            var info = stat()
            guard fstat(file.fileDescriptor, &info) == 0 else { throw FFmpegError(code: swift_AVERROR(EIO), operation: "fstat(cached audio)") }
            starts.append(starts[starts.count - 1] + Int64(info.st_size))
        }
        self.starts = starts
    }

    deinit {
        if let io { av_free(io.pointee.buffer); avio_context_free(&self.io) }
    }

    func install(on context: UnsafeMutablePointer<AVFormatContext>) throws {
        guard let buffer = av_malloc(Self.bufferSize) else { throw FFmpegError(code: -1, operation: "av_malloc") }
        io = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self), Int32(Self.bufferSize), 0,
            Unmanaged.passUnretained(self).toOpaque(),
            { opaque, bytes, count in
                guard let opaque, let bytes else { return swift_AVERROR(EIO) }
                return Unmanaged<FileChain>.fromOpaque(opaque).takeUnretainedValue().read(into: bytes, count: count)
            }, nil,
            { opaque, offset, whence in
                guard let opaque else { return Int64(swift_AVERROR(EIO)) }
                return Unmanaged<FileChain>.fromOpaque(opaque).takeUnretainedValue().seek(offset: offset, whence: whence)
            })
        guard let io else { av_free(buffer); throw FFmpegError(code: -1, operation: "avio_alloc_context") }
        io.pointee.seekable = Int32(AVIO_SEEKABLE_NORMAL)
        context.pointee.pb = io
        context.pointee.flags |= 0x0080 // AVFMT_FLAG_CUSTOM_IO: this owner frees AVIO.
    }

    private var length: Int64 { starts[starts.count - 1] }

    private func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & 0x10000 != 0 { return length } // AVSEEK_SIZE
        let base: Int64
        switch whence & ~0x20000 { // AVSEEK_FORCE is advisory
        case SEEK_SET: base = 0
        case SEEK_CUR: base = position
        case SEEK_END: base = length
        default: return Int64(swift_AVERROR(EINVAL))
        }
        guard base + offset >= 0 else { return Int64(swift_AVERROR(EINVAL)) }
        position = base + offset
        return position
    }

    private func read(into destination: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        guard position < length else { return swift_AVERROR_EOF() }
        // The file holding `position` — the first that ends past it, which
        // also steps over an empty file.
        guard let file = files.indices.first(where: { starts[$0 + 1] > position }) else {
            return swift_AVERROR(EIO)
        }
        let wanted = min(Int64(count), starts[file + 1] - position)
        let got = pread(files[file].fileDescriptor, destination, Int(wanted), off_t(position - starts[file]))
        guard got > 0 else { return got == 0 ? swift_AVERROR_EOF() : swift_AVERROR(EIO) }
        position += Int64(got)
        return Int32(got)
    }
}
