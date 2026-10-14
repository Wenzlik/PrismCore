import Testing
import Foundation
import Libavformat
import Libavcodec
import Libavutil
@testable import PrismCore

/// Where a player puts a re-anchored segment.
///
/// AVPlayer fetches each `EXT-X-MAP` once and reads every later segment's
/// `tfdt` through THAT init's edit list. The head muxer zero-bases its tfdt and
/// writes an edit list that undoes it (media_time = the B-frame delay, or the
/// priming of audio whose first packet sits before zero); a re-anchored muxer
/// is a new movenc whose tfdt has to land on the same timeline, or everything
/// it produces after a seek is presented off by the difference — on 3.5.3, an
/// open-GOP keyframe 83 ms late and AAC 21 ms early.
///
/// Fixtures (`generate_reanchor.sh`): 60 s, three B-frames, a keyframe every
/// 2 s, a click on every whole second. Closed GOP + AAC (copied, primed),
/// and open GOP + Opus (bridged). 60 s is past the producer's 30 s lead, so
/// the late segment below only exists once a fetch re-anchors production.
@Suite("Re-anchor timeline", .serialized)
struct ReanchorTimelineTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test(
        "A re-anchored segment plays where the plan put it, through the init the player already holds",
        arguments: ["reanchor_closedgop_aac.mkv", "reanchor_opengop_opus.mkv"]
    )
    func reanchoredSegmentsKeepTheTimeline(name: String) async throws {
        // Until a segment is demanded the producer never parks, so it is held
        // short of the late segment until segment 1 has been fetched; after
        // that the 30 s lead parks it well before 50 s on its own.
        let media = try Data(contentsOf: try fixture(name))
        let hold = HeldMedia(bytes: [UInt8](media), holdAt: media.count / 2)
        let session = try PrismCoreSession(url: URL(string: "prismcore-test://\(name)")!, input: hold.make)
        let master = try await session.start()
        defer { hold.release(); Task { await session.stop() } }
        let base = master.deletingLastPathComponent()
        let work = await session.workDirectory
        func fetch(_ path: String) async throws -> Data {
            let (data, response) = try await URLSession.uncached.data(from: base.appendingPathComponent(path))
            try #require((response as? HTTPURLResponse)?.statusCode == 200, "\(path)")
            return data
        }

        let variant = try String(contentsOf: work.appendingPathComponent("index.m3u8"), encoding: .utf8)
        let durations = variant.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") }
        try #require(durations.count > 6, "\(variant)")

        // What AVPlayer caches: the inits as they are before any seek.
        let videoInit = try await fetch("init.mp4")
        let audioInit = try await fetch("audio0/init.mp4")

        let late = durations.count - 2
        let lateFile = work.appendingPathComponent(String(format: "seg%05d.m4s", late))
        // Segment 1 comes from the head muxer; the late one from a re-anchor.
        for index in [1, late] {
            if index == late {
                try #require(!FileManager.default.fileExists(atPath: lateFile.path), "no re-anchor to measure")
            }
            let planned = durations.prefix(index).reduce(0, +)
            let video = try await fetch(String(format: "seg%05d.m4s", index))
            let audio = try await fetch(String(format: "audio0/seg%05d.m4s", index))
            hold.release()

            // The segment opens on the plan's keyframe, and that keyframe is
            // the first sample in decode order: tfdt + its composition offset,
            // read through the cached init's edit list, is its presentation.
            let timing = try Self.keyframeTiming(initSegment: videoInit, media: video)
            #expect(abs(timing.seconds - planned) < 0.002,
                    "\(name) seg\(index): keyframe presents at \(timing.seconds) s, planned \(planned) s (\(timing.detail))")

            // The audio is judged by ear: every click lands on its second.
            let clicks = try Self.clickOnsets(initSegment: audioInit, media: audio)
            #expect(clicks.count >= 3, "\(name) seg\(index): clicks \(clicks)")
            for click in clicks {
                #expect(abs(click - click.rounded()) < 0.005,
                        "\(name) seg\(index): click at \(click) s, \(Int(((click - click.rounded()) * 1000).rounded())) ms off its second")
            }
        }

        // A re-anchored muxer mints its own moov; the ones the player holds
        // must not be replaced under it.
        #expect(try await fetch("init.mp4") == videoInit)
        #expect(try await fetch("audio0/init.mp4") == audioInit)
    }

    /// The re-anchor that comes before any init exists — a producer recovery
    /// during startup, a lazy rendition armed at the head — mints the init
    /// itself, and keeps the edit list that places a keyframe whose DTS is
    /// below zero (the B-frame delay at the head).
    @Test("A restart that mints the first init places its keyframe, head included", arguments: [0.0, 20.0])
    func restartWithoutServedInitPlacesItsKeyframe(at seconds: Double) throws {
        let url = try fixture("reanchor_opengop_opus.mkv")
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let videoIndex = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        try #require(videoIndex >= 0)
        let sourceTimeBase = context.pointee.streams[Int(videoIndex)]!.pointee.time_base
        let target = Int64(seconds / av_q2d(sourceTimeBase))
        try FFmpegError.check(av_seek_frame(context, videoIndex, target, AVSEEK_FLAG_BACKWARD), "av_seek_frame")

        let writer = FMP4SegmentWriter()
        _ = try writer.open(input: context, plan: [.init(inputIndex: videoIndex)], restart: true)
        let output = try #require(writer.context)
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var keyframes = 0
        while av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == videoIndex else { continue }
            if pkt.pointee.flags & AV_PKT_FLAG_KEY != 0 {
                keyframes += 1
                if keyframes == 2 { break }
            }
            av_packet_rescale_ts(pkt, sourceTimeBase, output.pointee.streams[0]!.pointee.time_base)
            pkt.pointee.stream_index = 0
            pkt.pointee.pos = -1
            try writer.write(pkt)
        }
        let (initSegment, media) = try writer.cutSegment()
        let timing = try Self.keyframeTiming(initSegment: try #require(initSegment), media: media)
        #expect(abs(timing.seconds - seconds) < 0.002, "keyframe presents at \(timing.seconds) s (\(timing.detail))")
        _ = try writer.finish()
    }

    // MARK: - Reading the boxes

    private struct Box { let type: String; let body: Range<Int> }

    private static func boxes(_ bytes: [UInt8], in range: Range<Int>, path: [String]) -> [Box] {
        var found: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size = Int(u32(bytes, offset))
            guard size >= 8 else { break }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let body = (offset + 8)..<min(offset + size, range.upperBound)
            if type == path[0] {
                found += path.count == 1 ? [Box(type: type, body: body)] : boxes(bytes, in: body, path: Array(path.dropFirst()))
            }
            offset += size
        }
        return found
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        UInt64(u32(bytes, at)) << 32 | UInt64(u32(bytes, at + 4))
    }

    /// An `mvhd`'s or `mdhd`'s timescale, after the creation and modification
    /// times (64-bit in a version 1 box).
    private static func timescale(_ bytes: [UInt8], _ box: Box) -> Double {
        Double(u32(bytes, box.body.lowerBound + (bytes[box.body.lowerBound] == 1 ? 20 : 12)))
    }

    /// The first sample's presentation, in seconds, as a player computes it:
    /// tfdt + composition offset − the edit's media_time, after any empty edit.
    private static func keyframeTiming(initSegment: Data, media: Data) throws -> (seconds: Double, detail: String) {
        let head = [UInt8](initSegment)
        let movieScale = timescale(head, try #require(boxes(head, in: 0..<head.count, path: ["moov", "mvhd"]).first))
        let trak = try #require(boxes(head, in: 0..<head.count, path: ["moov", "trak"]).first)
        let mediaScale = timescale(head, try #require(boxes(head, in: trak.body, path: ["mdia", "mdhd"]).first))
        var emptyEdit = 0.0, mediaTime: Int64 = 0
        if let elst = boxes(head, in: trak.body, path: ["edts", "elst"]).first {
            let version = head[elst.body.lowerBound]
            var at = elst.body.lowerBound + 8
            for _ in 0..<u32(head, elst.body.lowerBound + 4) {
                let duration = version == 1 ? Int64(bitPattern: u64(head, at)) : Int64(u32(head, at))
                let time = version == 1 ? Int64(bitPattern: u64(head, at + 8)) : Int64(Int32(bitPattern: u32(head, at + 4)))
                at += version == 1 ? 20 : 12
                if time == -1 { emptyEdit += Double(duration) / movieScale } else { mediaTime = time; break }
            }
        }

        let bytes = [UInt8](media)
        let traf = try #require(boxes(bytes, in: 0..<bytes.count, path: ["moof", "traf"]).first)
        let tfdt = try #require(boxes(bytes, in: traf.body, path: ["tfdt"]).first)
        let decodeTime = bytes[tfdt.body.lowerBound] == 1
            ? Int64(bitPattern: u64(bytes, tfdt.body.lowerBound + 4))
            : Int64(u32(bytes, tfdt.body.lowerBound + 4))
        let trun = try #require(boxes(bytes, in: traf.body, path: ["trun"]).first)
        let flags = u32(bytes, trun.body.lowerBound) & 0xFFFFFF
        var at = trun.body.lowerBound + 8
        if flags & 0x1 != 0 { at += 4 }
        if flags & 0x4 != 0 { at += 4 }
        if flags & 0x100 != 0 { at += 4 }
        if flags & 0x200 != 0 { at += 4 }
        if flags & 0x400 != 0 { at += 4 }
        let offset = flags & 0x800 != 0 ? Int64(Int32(bitPattern: u32(bytes, at))) : 0
        let seconds = Double(decodeTime + offset - mediaTime) / mediaScale + emptyEdit
        return (seconds, "tfdt \(decodeTime), cts \(offset), media_time \(mediaTime), empty \(emptyEdit) s, timescale \(Int(mediaScale))")
    }

    // MARK: - Listening

    /// Decodes init + one fragment as one file — libavformat applies the init's
    /// edit list to the fragment's tfdt as a player does — and returns when
    /// each click starts.
    static func clickOnsets(initSegment: Data, media: Data) throws -> [Double] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreReanchor-\(UUID().uuidString).mp4")
        try (initSegment + media).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, file.path, nil, nil), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let context = try #require(input)
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let stream = try #require(context.pointee.streams[0])
        let decoder = try #require(avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id))
        var codec = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&codec) }
        let decoding = try #require(codec)
        try FFmpegError.check(avcodec_parameters_to_context(decoding, stream.pointee.codecpar), "parameters_to_context")
        decoding.pointee.pkt_timebase = stream.pointee.time_base
        try FFmpegError.check(avcodec_open2(decoding, decoder, nil), "avcodec_open2")

        var packet = av_packet_alloc(), frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        let pkt = try #require(packet), decoded = try #require(frame)
        let timeBase = av_q2d(stream.pointee.time_base)
        var onsets: [Double] = []
        var firstSample: Double?
        var lastLoud = -Double.infinity
        func drain() {
            while avcodec_receive_frame(decoding, decoded) >= 0 {
                defer { av_frame_unref(decoded) }
                let pts = decoded.pointee.best_effort_timestamp
                guard pts != swift_AV_NOPTS_VALUE(), decoded.pointee.format == AV_SAMPLE_FMT_FLTP.rawValue else { continue }
                let start = Double(pts) * timeBase
                if firstSample == nil { firstSample = start }
                let rate = Double(decoded.pointee.sample_rate)
                let samples = UnsafeRawPointer(decoded.pointee.extended_data[0]!).assumingMemoryBound(to: Float.self)
                for index in 0..<Int(decoded.pointee.nb_samples) where abs(samples[index]) > 0.2 {
                    let time = start + Double(index) / rate
                    // A click is 10 ms, a second apart; a mid-stream decoder's
                    // first frame lacks its overlap, so nothing in it counts.
                    if time - lastLoud > 0.5, time - firstSample! > 0.05 { onsets.append(time) }
                    lastLoud = time
                }
            }
        }
        while av_read_frame(context, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == 0 else { continue }
            try FFmpegError.check(avcodec_send_packet(decoding, pkt), "avcodec_send_packet")
            drain()
        }
        avcodec_send_packet(decoding, nil)
        drain()
        return onsets
    }
}

/// The fixture in memory, with every forward read across `holdAt` waiting for
/// `release()` (or the engine's cancel) — a slow origin, without the timing.
private final class HeldMedia: @unchecked Sendable {
    private let bytes: [UInt8]
    private let holdAt: Int
    private let condition = NSCondition()
    private var released = false

    init(bytes: [UInt8], holdAt: Int) {
        self.bytes = bytes
        self.holdAt = holdAt
    }

    func release() {
        condition.withLock { released = true; condition.broadcast() }
    }

    var make: PrismCoreInputFactory { { [self] in Input(media: self) } }

    private final class Input: CancellablePrismCoreInput, @unchecked Sendable {
        private let media: HeldMedia
        private var position = 0

        init(media: HeldMedia) { self.media = media }

        var length: Int64? { Int64(media.bytes.count) }

        func seek(to offset: Int64) throws { position = Int(offset) }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            let count = min(buffer.count, 64 * 1024, max(0, media.bytes.count - position))
            if position < media.holdAt, position + count > media.holdAt {
                media.condition.withLock { while !media.released { media.condition.wait() } }
            }
            guard count > 0 else { return 0 }
            media.bytes.withUnsafeBytes {
                buffer.baseAddress!.copyMemory(from: $0.baseAddress!.advanced(by: position), byteCount: count)
            }
            position += count
            return count
        }

        func cancelInFlightOperation() { media.release() }
    }
}
