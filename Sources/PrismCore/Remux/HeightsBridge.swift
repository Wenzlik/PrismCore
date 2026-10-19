import AVFAudio
import AudioToolbox
import Foundation
import Libavcodec
import Libavformat
import Libavutil
#if canImport(TrueHDObjects)
import TrueHDObjects
#endif

/// What an audio rendition's encoder is to `AudioRenditionWriter`: FFmpeg's decode → resample →
/// encode chain (`AudioBridge`), or the heights renderer (`HeightsBridge`).
protocol RenditionEncoder: AnyObject {
    var onProgress: ((AudioBridgeProgress) -> Void)? { get set }
    /// Time base of the packets `feed`/`flush` emit.
    var timeBase: AVRational { get }
    var outputCodecName: String? { get }
    var outputChannelCount: Int? { get }
    /// Spent by `flush`; the caller rebuilds rather than resets.
    var isDrained: Bool { get }
    func configure(outputStream: UnsafeMutablePointer<AVStream>) throws
    func feed(_ packet: UnsafeMutablePointer<AVPacket>, emit: AudioBridge.Emit) throws
    func flush(emit: AudioBridge.Emit) throws
    func reset() throws
    func close()
}

extension AudioBridge: RenditionEncoder {}

/// TrueHD Atmos with its heights: 7.1.4 derived from the stream's own 7.1 presentation by the
/// Rust `TrueHDObjects` library (truehdd's decoder; each 7.1 channel split per frequency bin
/// between ear level and the heights by where the objects' energy lies), encoded to Apple
/// Positional Audio with `AVAudioConverter`, muxed as an `apac` track.
///
/// ## Why APAC
///
/// It is the only codec the platform both encodes (OS 26) and plays with more than eight
/// channels: FLAC and ALAC stop at 7.1, multichannel PCM over HDMI at 8 channels, and E-AC-3 JOC
/// needs an encoder no Apple SDK has. The trade is that APAC is lossy where the lossless bridge
/// was not — which is why this is opt-in (`ObjectAudioRendering.heights`).
///
/// ## Encoder settings, all measured on macOS 26.5 (M2)
///
/// - **No DRC** (`dynamicRangeControlConfiguration = .none`). Every other configuration holds
///   audio back before its first packet: 1.51 s (`.capture` and the default), 10 s (`.music`,
///   `.voice`), 20 s (`.movie`). This rendition is cut on the video's boundaries the moment the
///   video reaches them, so a lookahead would leave every segment short by that much, and the
///   first segment after a seek emptier still. Apple's APAC note asks for DRC metadata; meeting
///   that needs cuts deferred until the encoder catches up, which is not built.
/// - **Every packet is independently decodable** with these settings: decoding from any packet
///   gives the same samples as decoding from the first (bit-identical over 400 packets, from
///   packets 10, 37, 75, 150, 151), and the encoder flags each one so. Each segment therefore
///   starts on a packet the decoder can enter at, as Apple's HLS rules require, without
///   aligning segments to a sync-packet grid.
/// - **Priming**: the encoder's first 2048 frames are delay. Packets are stamped the way
///   AVAssetWriter stamps its own APAC fragments — the first at the source time minus 2048
///   frames — so the first source sample plays at its own time; the muxer's edit list trims
///   the head as it does for AAC's priming.
/// - **256 kbps per channel** (3.07 Mbit/s for 7.1.4). CPU: about
///   14× real time per core for the encoder on an M2 (synthetic 7.1.4).
///
/// ## Timing
///
/// The renderer's output is contiguous from the first sample of the first access unit it is
/// given — concealed and fallback audio keep their length, and the split's own 32 ms delay is
/// hidden inside the library — so the
/// clock is one anchor, the PTS of the first fed packet, plus a sample count. Decoding has to
/// start at a major sync, so after a start or a seek packets are skipped until one (at most 128
/// access units, 107 ms). A jump in the source's timestamps re-anchors like a seek.
///
/// ## Failure never interrupts playback
///
/// The rendition's codec is promised in the master before the first packet, so nothing after
/// that may change it. A stream the split has nothing to go by for (no objects, ISF, several
/// beds, …) plays its own channel presentation, routed into 7.1.4 with silent heights, and reports
/// `ObjectAudioDelivery.notPreserved`. A stream the decoder cannot decode at all plays as
/// silence up to each packet's end on the source clock and says so in the log. An encoder
/// failure restarts the encoder at the next major sync. Nothing here throws but the muxer.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class HeightsBridge: RenditionEncoder {

    static let channelCount = HeightsBridgeConstants.channelCount
    static let sampleRate = HeightsBridgeConstants.sampleRate
    static let framesPerPacket = 1024
    static let bitRate = channelCount * 256_000

    var onProgress: ((AudioBridgeProgress) -> Void)?
    /// What the renderer is delivering, whenever that changes: `.renderedHeights` once objects
    /// play, `.notPreserved` after a fallback. The message says why, for the log.
    var onObjectAudio: ((ObjectAudioDelivery, String?) -> Void)?
    private(set) var progress = AudioBridgeProgress()

    /// The `dapa` box the `apac` sample entry carries: the encoder's magic cookie as it is.
    let magicCookie: Data

    private let sourceTimeBase: AVRational
    private let encoder: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let staging: AVAudioPCMBuffer
    private let compressed: AVAudioCompressedBuffer
    private let priming: Int64
    private var packet: UnsafeMutablePointer<AVPacket>?

    #if canImport(TrueHDObjects)
    private var session: OpaquePointer?
    #endif
    /// Interleaved 7.1.4 waiting for a whole encoder packet.
    private var pending: [Float] = []
    /// The source time (1/48 000) of rendered sample 0 of this epoch; nil until a major sync.
    private var anchor: Int64?
    /// Samples handed to the encoder this epoch, and packets stamped.
    private var samplesIn: Int64 = 0
    private var packetsOut: Int64 = 0
    /// Where the next source packet is expected to start, for spotting a jump.
    private var expectedPTS: Int64?
    /// Set once the decoder has failed for good: the rest plays as silence.
    private var decoderFailure: String?
    private var reported: ObjectAudioDelivery?
    private var drained = false

    /// Whether this OS has the 7.1.4 APAC encoder (asked once: building a converter is cheap,
    /// but the answer cannot change).
    static let encoderExists: Bool = (try? makeEncoder()) != nil

    /// The configured encoder and its PCM input format.
    private static func makeEncoder() throws -> (AVAudioConverter, AVAudioFormat) {
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Atmos_7_1_4) else {
            throw Failure.encoderUnavailable
        }
        let pcm = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), interleaved: true, channelLayout: layout
        )
        var tag = AudioChannelLayout()
        tag.mChannelLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAPAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: channelCount,
            AVChannelLayoutKey: Data(bytes: &tag, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        guard let apac = AVAudioFormat(settings: settings), let encoder = AVAudioConverter(from: pcm, to: apac) else {
            throw Failure.encoderUnavailable
        }
        encoder.bitRate = bitRate
        // Film mastered offline, which is what a TrueHD track is.
        encoder.contentSource = .appleAV_Spatial_Offline
        encoder.dynamicRangeControlConfiguration = .none
        return (encoder, pcm)
    }

    enum Failure: Error, CustomStringConvertible {
        case notLinked
        case sourceUnsupported(String)
        case encoderUnavailable

        var description: String {
            switch self {
            case .notLinked: return "this build has no TrueHDObjects library"
            case .sourceUnsupported(let why): return "heights need 48 kHz TrueHD: \(why)"
            case .encoderUnavailable: return "this OS has no 7.1.4 APAC encoder"
            }
        }
    }

    init(codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        guard ObjectAudioRendering.rendererIsLinked else { throw Failure.notLinked }
        guard codecpar.pointee.codec_id == AV_CODEC_ID_TRUEHD else {
            throw Failure.sourceUnsupported("not TrueHD")
        }
        // A stream that has not reported its rate yet is let through: Atmos TrueHD is 48 kHz,
        // and the renderer refuses any other rate on the first access unit.
        guard [0, Self.sampleRate].contains(codecpar.pointee.sample_rate) else {
            throw Failure.sourceUnsupported("\(codecpar.pointee.sample_rate) Hz")
        }
        sourceTimeBase = timeBase
        let (encoder, pcmFormat) = try Self.makeEncoder()
        self.pcmFormat = pcmFormat
        guard let cookie = encoder.magicCookie, !cookie.isEmpty,
              let staging = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(Self.framesPerPacket))
        else { throw Failure.encoderUnavailable }
        self.encoder = encoder
        self.staging = staging
        magicCookie = cookie
        priming = Int64(encoder.primeInfo.leadingFrames)
        compressed = AVAudioCompressedBuffer(
            format: encoder.outputFormat, packetCapacity: 16,
            maximumPacketSize: max(encoder.maximumOutputPacketSize, 1)
        )
        packet = av_packet_alloc()
        progress.encoderFrameSamples = Self.framesPerPacket
    }

    deinit { close() }

    func close() {
        closeSession()
        av_packet_free(&packet)
    }

    var isDrained: Bool { drained }
    var timeBase: AVRational { AVRational(num: 1, den: Self.sampleRate) }
    var outputCodecName: String? { "apac" }
    var outputChannelCount: Int? { Self.channelCount }

    /// movenc has no Apple Positional Audio (libavformat's `apac` id is an unrelated codec), so
    /// the muxer is handed an ALAC stream — whose sample entry it builds from these parameters
    /// alone and whose packets it never parses — and the init segment's entry is replaced with
    /// the real one (`APACSampleEntry`). Fragments name no codec and need nothing.
    func configure(outputStream: UnsafeMutablePointer<AVStream>) throws {
        try APACSampleEntry.configureStandIn(outputStream: outputStream)
    }

    // MARK: - Feeding

    func feed(_ source: UnsafeMutablePointer<AVPacket>, emit: AudioBridge.Emit) throws {
        guard !drained, let data = source.pointee.data, source.pointee.size > 0 else { return }
        progress.inputPackets += 1
        defer { onProgress?(progress) }
        let raw = source.pointee.pts != swift_AV_NOPTS_VALUE() ? source.pointee.pts : source.pointee.dts
        let pts: Int64? = raw != swift_AV_NOPTS_VALUE() ? av_rescale_q(raw, sourceTimeBase, timeBase) : nil
        let duration: Int64? = source.pointee.duration > 0
            ? av_rescale_q(source.pointee.duration, sourceTimeBase, timeBase) : nil

        // A jump in the source's own timeline (a splice, a gap) is a seek as far as the
        // renderer is concerned: its output would otherwise keep counting from the old anchor.
        // The old epoch's audio is finished first, so nothing it rendered is lost; a forward
        // jump past 0.1 s cannot overlap the new epoch's priming, and the muxer's sanitizer
        // orders a backward one.
        if let pts, let expected = expectedPTS, abs(pts - expected) > Int64(Self.sampleRate) / 10 {
            if decoderFailure == nil { decode(UnsafeBufferPointer(start: nil, count: 0), end: true) }
            try encodePending(final: true, emit: emit)
            restartEpoch()
        }
        let bytes = UnsafeBufferPointer(start: data, count: Int(source.pointee.size))
        if anchor == nil {
            guard let pts, TrueHDMajorSync.startsWithMajorSync(bytes) else { return }
            anchor = pts
        }
        expectedPTS = pts.map { $0 + (duration ?? 0) }

        if decoderFailure == nil {
            decode(bytes, end: false)
        }
        if decoderFailure != nil {
            // The decoder has given up; the rest of the timeline plays as silence — up to where
            // this packet ENDS on the source's own clock, not by its duration on top of whatever
            // the failing call already rendered (or lost: the limiter's last 2 ms, audio held
            // for metadata), so everything after stays on the source grid.
            padToSourceGrid(packetEnd: pts.map { $0 + (duration ?? 0) })
        }
        try encodePending(final: false, emit: emit)
    }

    /// Where the next rendered sample sits on the source clock: what the encoder has taken,
    /// plus what waits for a whole packet. Internal for the tests that pin the grid.
    var renderedPosition: Int64? {
        anchor.map { $0 + samplesIn + Int64(pending.count / Self.channelCount) }
    }

    private func padToSourceGrid(packetEnd: Int64?) {
        guard let packetEnd, let position = renderedPosition, packetEnd > position else { return }
        pending.append(contentsOf: repeatElement(0, count: Int(packetEnd - position) * Self.channelCount))
    }

    func flush(emit: AudioBridge.Emit) throws {
        guard !drained else { return }
        defer { onProgress?(progress) }
        if anchor != nil, decoderFailure == nil {
            decode(UnsafeBufferPointer(start: nil, count: 0), end: true)
        }
        try encodePending(final: true, emit: emit)
        drained = true
        // No `producedNoAudio` here, unlike `AudioBridge`: this bridge skips packets on purpose
        // until a major sync, so a re-anchor into the last ~107 ms of a stream (no restart left)
        // ends with input and no output. That is an empty last segment, not a failure — thrown,
        // it ended the producer, and the video with it.
    }

    /// A demand-driven seek: everything buffered belongs to the old position.
    func reset() throws {
        progress = AudioBridgeProgress()
        progress.encoderFrameSamples = Self.framesPerPacket
        onProgress?(progress)
        restartEpoch()
        drained = false
    }

    private func restartEpoch() {
        closeSession()
        encoder.reset()
        pending.removeAll(keepingCapacity: true)
        anchor = nil
        expectedPTS = nil
        samplesIn = 0
        packetsOut = 0
        // A fresh position is a fresh chance: a decoder that failed on damaged bytes may well
        // decode the stream from its next major sync.
        decoderFailure = nil
    }

    // MARK: - Decoding (TrueHDObjects)

    private func decode(_ bytes: UnsafeBufferPointer<UInt8>, end: Bool) {
        #if canImport(TrueHDObjects)
        if session == nil {
            session = truehd_objects_open()
        }
        guard let session else {
            fail("the renderer could not allocate a session")
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = truehd_objects_push(session, bytes.baseAddress, bytes.count, end ? 1 : 0, { context, pcm, frames in
            guard let context, let pcm else { return 0 }
            let bridge = Unmanaged<HeightsBridge>.fromOpaque(context).takeUnretainedValue()
            bridge.pending.append(contentsOf: UnsafeBufferPointer(start: pcm, count: Int(frames) * HeightsBridge.channelCount))
            bridge.progress.decodedFrames += 1
            return 0
        }, context)
        if status != 0 {
            fail(message(session))
            return
        }
        switch truehd_objects_mode(session) {
        case UInt32(TRUEHD_OBJECTS_RENDERED): report(.renderedHeights, nil)
        case UInt32(TRUEHD_OBJECTS_BED): report(.notPreserved, message(session))
        default: break
        }
        #else
        fail(Failure.notLinked.description)
        #endif
    }

    private func fail(_ why: String) {
        decoderFailure = why
        PrismCoreLog.notice("heights renderer stopped (\(why)); the rest of this epoch plays as silence")
        report(.notPreserved, why)
    }

    private func report(_ delivery: ObjectAudioDelivery, _ why: String?) {
        guard reported != delivery else { return }
        reported = delivery
        if delivery == .notPreserved, let why {
            PrismCoreLog.notice("heights renderer fell back to the channel bed: \(why)")
        }
        onObjectAudio?(delivery, why)
    }

    #if canImport(TrueHDObjects)
    private func message(_ session: OpaquePointer) -> String {
        let capacity = truehd_objects_message(session, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(capacity, 1))
        _ = truehd_objects_message(session, &buffer, buffer.count)
        return String(cString: buffer)
    }
    #endif

    private func closeSession() {
        #if canImport(TrueHDObjects)
        if let session {
            truehd_objects_close(session)
            self.session = nil
        }
        #endif
    }

    // MARK: - Encoding

    /// Whole packets of PCM into the encoder; at the end the remainder too, padded with silence
    /// to the packet length (at most 21 ms, after the last real sample).
    private func encodePending(final: Bool, emit: AudioBridge.Emit) throws {
        let packetSamples = Self.framesPerPacket * Self.channelCount
        if final, !pending.isEmpty, pending.count % packetSamples != 0 {
            pending.append(contentsOf: repeatElement(0, count: packetSamples - pending.count % packetSamples))
        }
        var offset = 0
        while pending.count - offset >= packetSamples {
            pending.withUnsafeBufferPointer { all in
                staging.floatChannelData![0].update(from: all.baseAddress! + offset, count: packetSamples)
            }
            staging.frameLength = AVAudioFrameCount(Self.framesPerPacket)
            offset += packetSamples
            samplesIn += Int64(Self.framesPerPacket)
            progress.resampledSamples += Self.framesPerPacket
            guard try convert(staging, endOfStream: false, emit: emit) else { return restartAfterEncoderFailure() }
        }
        pending.removeFirst(offset)
        if final, anchor != nil {
            guard try convert(nil, endOfStream: true, emit: emit) else { return restartAfterEncoderFailure() }
        }
    }

    /// The encoder refused a buffer. Its state is unknown, so it starts over like after a seek
    /// (the next major sync re-anchors); the gap plays as nothing. Never thrown: the rendition
    /// shares a producer with the video.
    private func restartAfterEncoderFailure() {
        PrismCoreLog.notice("APAC encoder failed; restarting at the next major sync")
        restartEpoch()
    }

    /// `false` when the encoder failed. Only `emit` (the muxer) throws.
    private func convert(_ input: AVAudioPCMBuffer?, endOfStream: Bool, emit: AudioBridge.Emit) throws -> Bool {
        var supplied = input == nil
        while true {
            compressed.packetCount = 0
            compressed.byteLength = 0
            var error: NSError?
            let status = encoder.convert(to: compressed, error: &error) { _, inputStatus in
                if !supplied, let input {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                PrismCoreLog.notice("APAC encode: \(error.map { "\($0)" } ?? "status error")")
                return false
            }
            try emitPackets(emit)
            if status != .haveData || compressed.packetCount == 0 { break }
        }
        return true
    }

    private func emitPackets(_ emit: AudioBridge.Emit) throws {
        guard let packet, let anchor, let descriptions = compressed.packetDescriptions else { return }
        for index in 0..<Int(compressed.packetCount) {
            let description = descriptions[index]
            try FFmpegError.check(av_new_packet(packet, Int32(description.mDataByteSize)), "av_new_packet(apac)")
            defer { av_packet_unref(packet) }
            packet.pointee.data.update(
                from: (compressed.data + Int(description.mStartOffset)).assumingMemoryBound(to: UInt8.self),
                count: Int(description.mDataByteSize)
            )
            // As AVAssetWriter stamps its APAC fragments: the first packet sits `priming`
            // frames before the source time, which is where the first source sample lands.
            let pts = anchor - priming + packetsOut * Int64(Self.framesPerPacket)
            packet.pointee.pts = pts
            packet.pointee.dts = pts
            packet.pointee.duration = Int64(Self.framesPerPacket)
            // Every packet is an entry point (see the type's notes), so every sample is sync.
            packet.pointee.flags |= AV_PKT_FLAG_KEY
            packet.pointee.pos = -1
            packetsOut += 1
            try emit(packet)
            progress.outputPackets += 1
        }
    }
}

/// The heights rendition's shape, readable on any OS (the master is written before anything
/// else knows whether the encoder will open).
enum HeightsBridgeConstants {
    static let channelCount = 12
    static let sampleRate: Int32 = 48_000
}

extension ObjectAudioRendering {
    /// Whether this build links the `TrueHDObjects` renderer (the XCFramework is optional:
    /// Package.swift adds it only when `Rust/TrueHDObjects/build-xcframework.sh` has built it).
    static var rendererIsLinked: Bool {
        #if canImport(TrueHDObjects)
        return true
        #else
        return false
        #endif
    }
}

/// The `apac` sample entry, and the init-segment rewrite that installs it over the stand-in.
enum APACSampleEntry {

    /// The stand-in stream's parameters (see `HeightsBridge.configure`). Needs no encoder, so
    /// a declared heights rendition can mux on while its encoder is being rebuilt.
    static func configureStandIn(outputStream: UnsafeMutablePointer<AVStream>) throws {
        let par = outputStream.pointee.codecpar!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_ALAC
        par.pointee.codec_tag = 0
        par.pointee.sample_rate = HeightsBridgeConstants.sampleRate
        par.pointee.frame_size = 1024
        par.pointee.bit_rate = Int64(HeightsBridgeConstants.channelCount * 256_000)
        av_channel_layout_uninit(&par.pointee.ch_layout)
        av_channel_layout_default(&par.pointee.ch_layout, Int32(HeightsBridgeConstants.channelCount))
        let cookie = standInCookie
        guard let extradata = av_mallocz(cookie.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else {
            throw AudioBridge.Failure.allocationFailed("stand-in extradata")
        }
        cookie.withUnsafeBytes { extradata.copyMemory(from: $0.baseAddress!, byteCount: cookie.count) }
        av_freep(&par.pointee.extradata)
        par.pointee.extradata = extradata.assumingMemoryBound(to: UInt8.self)
        par.pointee.extradata_size = Int32(cookie.count)
        outputStream.pointee.time_base = AVRational(num: 1, den: HeightsBridgeConstants.sampleRate)
    }

    /// The ALAC magic cookie the stand-in stream carries: an `alac` box with a version word and
    /// a 24-byte ALACSpecificConfig (1024 frames, 16 bits, 2 channels, 48 kHz). movenc copies it
    /// into the entry verbatim; nothing ever decodes it, the whole entry is replaced.
    static let standInCookie: Data = {
        var bytes: [UInt8] = [0, 0, 0, 36] + Array("alac".utf8) + [0, 0, 0, 0]
        bytes += [0, 0, 4, 0]                  // frameLength 1024
        bytes += [0, 16, 40, 10, 14, 2]        // compatibleVersion, bitDepth, pb, mb, kb, numChannels
        bytes += [0, 255]                      // maxRun
        bytes += [0, 0, 0, 0, 0, 0, 0, 0]      // maxFrameBytes, avgBitRate
        bytes += [0, 0, 0xBB, 0x80]            // sampleRate 48 000
        return Data(bytes)
    }()

    /// `apac` AudioSampleEntry payload as AVAssetWriter writes it for HLS fMP4 (macOS 26.5,
    /// dumped from its own output): version 0, `channelcount` 2 and `samplesize` 16 whatever
    /// the real layout — which the configuration carries — then the encoder's cookie, which is
    /// already the complete `dapa` box.
    static func payload(magicCookie: Data, sampleRate: Int32) -> Data {
        var body = Data(count: 6)                      // reserved
        body.append(contentsOf: [0, 1])                // data_reference_index
        body.append(Data(count: 8))                    // version, revision, vendor
        body.append(contentsOf: [0, 2, 0, 16])         // channelcount, samplesize
        body.append(Data(count: 4))                    // pre_defined, reserved
        let rate = UInt32(sampleRate) << 16            // 16.16; 48 kHz fits a v0 entry
        body.append(contentsOf: [UInt8(rate >> 24), UInt8(rate >> 16 & 0xFF), UInt8(rate >> 8 & 0xFF), UInt8(rate & 0xFF)])
        body.append(magicCookie)
        return body
    }

    /// `initSegment` with its stand-in `alac` entry replaced by the `apac` one, or nil when
    /// there is no such entry (the caller then serves the init unchanged, and the failure shows
    /// as a load error on the audio rather than as corrupt bytes).
    static func patch(initSegment: Data, magicCookie: Data, sampleRate: Int32) -> Data? {
        guard let entry = ISOBMFFPatch.locate("alac", in: initSegment) else { return nil }
        var patched = ISOBMFFPatch.replacePayload(
            at: entry, in: initSegment, with: payload(magicCookie: magicCookie, sampleRate: sampleRate)
        )
        patched.replaceSubrange((entry.boxStart + 4)..<(entry.boxStart + 8), with: Array("apac".utf8))
        return patched
    }

    /// HLS `CODECS`: Apple's APAC note gives channel-based content profile 31 and a level by
    /// channel count (12 → 3); AVPlayer refuses a bare `apac`.
    static func codecsString(channelCount: Int) -> String {
        let tiers = [2, 6, 8, 12, 24, 32, 64]
        let level = tiers.firstIndex { channelCount <= $0 } ?? tiers.count - 1
        return String(format: "apac.31.%02d", level)
    }
}
