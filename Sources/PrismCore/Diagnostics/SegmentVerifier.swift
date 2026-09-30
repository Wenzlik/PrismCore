import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Decodes every served fMP4 segment on its own — init segment plus that one
/// fragment, nothing before it — and reports what would not decode.
///
/// An HLS client may start at any segment (a seek, a variant switch, a
/// resume), so each one has to stand alone: begin on a keyframe, reference
/// nothing in the previous fragment, and carry packets its codec accepts. The
/// player is the only other judge of that, and on a device its verdict arrives
/// as a stall or an opaque `-12xxx` with no segment named. This names the
/// segment.
///
/// "Independently" is deliberate on two axes. The bytes are fetched over the
/// served URLs, the way a player gets them, not read off the work directory;
/// and they are demuxed and decoded by a fresh libavformat/libavcodec pair
/// that shares no state with the producer that wrote them. A check that
/// reused the producer's contexts would inherit exactly the bugs it is meant
/// to catch.
///
/// `package` so `prismcore-cli segverify` and the test target run the same
/// checks.
package enum SegmentVerifier {

    package enum Severity: String, Sendable {
        /// The segment cannot be played from a cold start.
        case error
        /// Plays, but disagrees with what the playlist told the client.
        case warning
    }

    package struct Finding: Sendable, CustomStringConvertible {
        package let severity: Severity
        /// Playlist-relative URI of the segment (or the playlist itself).
        package let location: String
        package let problem: String

        package var description: String { "\(severity.rawValue): \(location): \(problem)" }
    }

    /// What decoding one init + fragment pair found.
    package struct SegmentCheck: Sendable {
        package var packets = 0
        package var videoFrames = 0
        package var audioFrames = 0
        /// Streams that were demuxed but not decoded, because this FFmpeg
        /// build has no decoder for them. Reported, never a failure: an absent
        /// decoder says nothing about the bytes.
        package var undecodedCodecs: [String] = []
        /// Summed packet duration of the timing stream (the first video
        /// stream, else the first audio stream), in seconds.
        package var mediaDuration: Double?
        package var problems: [(Severity, String)] = []

        package var hasErrors: Bool { problems.contains { $0.0 == .error } }
    }

    package struct PlaylistReport: Sendable {
        package let uri: String
        package var segmentsChecked = 0
        package var videoFrames = 0
        package var audioFrames = 0
        /// Why the playlist was not decoded at all (a subtitle rendition).
        package var skipped: String?
    }

    package struct Report: Sendable {
        package var playlists: [PlaylistReport] = []
        package var findings: [Finding] = []
        package var hasErrors: Bool { findings.contains { $0.severity == .error } }
    }

    /// A media playlist's init segment and fragments, in order.
    package struct MediaPlaylist: Sendable, Equatable {
        package struct Segment: Sendable, Equatable {
            package let uri: String
            /// `#EXTINF`'s value.
            package let duration: Double?
        }
        package let initURI: String?
        package let segments: [Segment]
        package let isEnded: Bool
    }

    package static func parseMediaPlaylist(_ text: String) -> MediaPlaylist {
        var initURI: String?
        var segments: [MediaPlaylist.Segment] = []
        var pendingDuration: Double?
        var ended = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MAP:"),
               let start = line.range(of: "URI=\"") {
                let rest = line[start.upperBound...]
                if let end = rest.firstIndex(of: "\"") { initURI = String(rest[..<end]) }
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first
                pendingDuration = value.flatMap { Double($0) }
            } else if line == "#EXT-X-ENDLIST" {
                ended = true
            } else if !line.isEmpty, !line.hasPrefix("#") {
                segments.append(.init(uri: line, duration: pendingDuration))
                pendingDuration = nil
            }
        }
        return MediaPlaylist(initURI: initURI, segments: segments, isEnded: ended)
    }

    // MARK: - Over HTTP

    /// Verify every segment of the HLS presentation at `playlist` (a master
    /// or a media playlist).
    ///
    /// A playlist still being produced — the unplanned shape, which grows
    /// until `#EXT-X-ENDLIST` — is re-fetched until it ends; `stallTimeout`
    /// bounds the wait for a segment that never appears.
    ///
    /// - Parameters:
    ///   - limit: stop after this many segments per playlist (a film is a
    ///     thousand of them; the first few catch most splice bugs).
    ///   - progress: called once per checked segment, for a live line.
    package static func verify(
        playlist: URL,
        limit: Int? = nil,
        stallTimeout: Duration = .seconds(60),
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Report {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // A demand fetch of a not-yet-produced segment waits for the producer
        // to get there, which on a remote source is a network read away.
        configuration.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var report = Report()
        let top = try await fetchText(playlist, session)
        let mediaURLs: [URL]
        if top.contains("#EXT-X-STREAM-INF") {
            let base = playlist.deletingLastPathComponent()
            mediaURLs = PrismCoreSession.playlistURIs(inMaster: top).map {
                URL(string: $0, relativeTo: base)?.absoluteURL ?? base.appendingPathComponent($0)
            }
        } else {
            mediaURLs = [playlist]
        }

        for mediaURL in mediaURLs {
            let name = relativeName(mediaURL, to: playlist)
            var playlistReport = PlaylistReport(uri: name)
            var checked = 0
            var lastGrowth = ContinuousClock.now
            var initData: Data?
            while true {
                let media = parseMediaPlaylist(try await fetchText(mediaURL, session))
                if media.initURI == nil, media.segments.contains(where: { $0.uri.hasSuffix(".vtt") }) {
                    playlistReport.skipped = "subtitle rendition (WebVTT is text, not decoded)"
                    break
                }
                guard let initURI = media.initURI else {
                    report.findings.append(Finding(
                        severity: .error, location: name,
                        problem: "no #EXT-X-MAP: an fMP4 media playlist needs an init segment"
                    ))
                    break
                }
                if initData == nil {
                    initData = try await fetchData(resolve(initURI, against: mediaURL), session)
                }
                let reachedLimit = { limit.map { checked >= $0 } ?? false }
                while checked < media.segments.count, !reachedLimit() {
                    let segment = media.segments[checked]
                    checked += 1
                    lastGrowth = .now
                    let data: Data
                    do {
                        data = try await fetchData(resolve(segment.uri, against: mediaURL), session)
                    } catch {
                        // Cancellation is the caller stopping, not a finding.
                        try Task.checkCancellation()
                        if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                        // A segment the playlist promises and the server will
                        // not deliver is the most direct failure there is —
                        // recorded against that segment, and the walk goes
                        // on so one bad tail does not hide the rest.
                        playlistReport.segmentsChecked += 1
                        report.findings.append(Finding(
                            severity: .error, location: "\(name) → \(segment.uri)",
                            problem: "listed but not served: \(Self.describe(error))"
                        ))
                        progress?("\(name) \(segment.uri): FAIL (not served)")
                        continue
                    }
                    let check = verify(
                        initSegment: initData!, mediaSegment: data, expectedDuration: segment.duration
                    )
                    playlistReport.segmentsChecked += 1
                    playlistReport.videoFrames += check.videoFrames
                    playlistReport.audioFrames += check.audioFrames
                    for (severity, problem) in check.problems {
                        report.findings.append(Finding(
                            severity: severity, location: "\(name) → \(segment.uri)", problem: problem
                        ))
                    }
                    progress?("\(name) \(segment.uri): "
                        + (check.hasErrors ? "FAIL" : "ok")
                        + " (\(check.packets) pkt, \(check.videoFrames) video / \(check.audioFrames) audio frames)")
                }
                if reachedLimit() || media.isEnded && checked >= media.segments.count { break }
                if ContinuousClock.now - lastGrowth > stallTimeout {
                    report.findings.append(Finding(
                        severity: .error, location: name,
                        problem: "no new segment for \(stallTimeout) and no #EXT-X-ENDLIST — "
                            + "the producer stalled or died after \(checked) segment(s)"
                    ))
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            report.playlists.append(playlistReport)
        }
        return report
    }

    // MARK: - One segment

    /// Demux and decode `initSegment + mediaSegment` as a standalone fMP4.
    package static func verify(
        initSegment: Data, mediaSegment: Data, expectedDuration: Double? = nil
    ) -> SegmentCheck {
        var check = SegmentCheck()
        // A file rather than a custom AVIO: the mov demuxer seeks around the
        // moof/mdat pair, and a file is the seekable input it is best tested
        // against — the check should not add a reader of its own to suspect.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-segverify-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try (initSegment + mediaSegment).write(to: file)
        } catch {
            check.problems.append((.error, "could not stage the segment for decoding: \(error)"))
            return check
        }

        var context: UnsafeMutablePointer<AVFormatContext>?
        let opened = avformat_open_input(&context, file.path, nil, nil)
        guard opened >= 0, let input = context else {
            check.problems.append((.error, "init + segment does not demux as fMP4: "
                + FFmpegError(code: opened, operation: "avformat_open_input").message))
            return check
        }
        defer { avformat_close_input(&context) }
        let info = avformat_find_stream_info(input, nil)
        if info < 0 {
            check.problems.append((.error, "stream analysis failed: "
                + FFmpegError(code: info, operation: "avformat_find_stream_info").message))
            return check
        }

        var decoders: [Int32: StreamDecoder] = [:]
        defer { decoders.values.forEach { $0.close() } }
        var firstVideo: Int32?
        var firstAudio: Int32?
        for index in 0..<Int32(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[Int(index)],
                  let parameters = stream.pointee.codecpar
            else { continue }
            let type = parameters.pointee.codec_type
            guard type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO else { continue }
            if type == AVMEDIA_TYPE_VIDEO { firstVideo = firstVideo ?? index }
            else { firstAudio = firstAudio ?? index }
            switch StreamDecoder.make(stream: stream) {
            case .success(let decoder): decoders[index] = decoder
            case .failure(let reason):
                if case .noDecoder(let codec) = reason {
                    check.undecodedCodecs.append(codec)
                } else {
                    check.problems.append((.error, "stream \(index): \(reason)"))
                }
            }
        }
        let timingStream = firstVideo ?? firstAudio
        if decoders.isEmpty && check.undecodedCodecs.isEmpty {
            check.problems.append((.error, "no audio or video stream in init + segment"))
            return check
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return check }
        var seenFirstVideoPacket = false
        var videoPackets = 0
        var timingTicks: Int64 = 0
        var timingBase: AVRational?
        // Pictures that follow the opening keyframe in decode order but
        // precede it in presentation order: an open GOP's leading pictures.
        var openingKeyframePTS: Int64?
        var leadingPictures = 0

        while true {
            let read = av_read_frame(input, packet)
            if read == swift_AVERROR_EOF() { break }
            if read < 0 {
                check.problems.append((.error, "demux failed after \(check.packets) packet(s): "
                    + FFmpegError(code: read, operation: "av_read_frame").message))
                break
            }
            defer { av_packet_unref(packet) }
            check.packets += 1
            let index = packet.pointee.stream_index
            if index == timingStream, let stream = input.pointee.streams[Int(index)] {
                timingTicks += packet.pointee.duration
                timingBase = stream.pointee.time_base
            }
            guard let decoder = decoders[index] else { continue }
            if decoder.isVideo {
                videoPackets += 1
                if !seenFirstVideoPacket {
                    seenFirstVideoPacket = true
                    // The property a cold start depends on first: a fragment
                    // that opens on a non-key frame decodes garbage (or
                    // nothing) until the next keyframe, which may be the next
                    // segment.
                    if packet.pointee.flags & AV_PKT_FLAG_KEY == 0 {
                        check.problems.append((.error,
                            "first video packet is not a keyframe — the segment cannot start playback"))
                    } else if packet.pointee.pts != swift_AV_NOPTS_VALUE() {
                        openingKeyframePTS = packet.pointee.pts
                    }
                } else if let openingKeyframePTS, packet.pointee.pts != swift_AV_NOPTS_VALUE(),
                          packet.pointee.pts < openingKeyframePTS {
                    leadingPictures += 1
                }
            }
            decoder.decode(packet)
        }
        for decoder in decoders.values { decoder.decode(nil) }

        for (index, decoder) in decoders.sorted(by: { $0.key < $1.key }) {
            if decoder.isVideo { check.videoFrames += decoder.frames } else { check.audioFrames += decoder.frames }
            if let first = decoder.errors.first {
                check.problems.append((.error, "stream \(index) (\(decoder.codecName)): "
                    + "\(decoder.errors.count) decode error(s), first: \(first)"))
            }
            if decoder.corruptFrames > 0 {
                check.problems.append((.error, "stream \(index) (\(decoder.codecName)): "
                    + "\(decoder.corruptFrames) frame(s) decoded flagged corrupt — "
                    + "likely a reference into the previous segment"))
            }
            if decoder.isVideo, decoder.errors.isEmpty, decoder.frames < videoPackets {
                // Every video packet the remux writes is a picture; one that
                // produced no frame was dropped by the decoder, which is what a
                // missing reference looks like when it is not loud.
                let missing = videoPackets - decoder.frames
                if missing <= leadingPictures {
                    // An open GOP: the segment opens on a CRA/non-IDR I-frame
                    // whose leading pictures reference the previous GOP, and a
                    // decoder starting here skips them (HEVC RASL). Stream
                    // copy cannot change the source's GOP structure, and a
                    // cold start loses only those frames — worth knowing, not
                    // a segment that fails to play.
                    check.problems.append((.warning, "stream \(index) (\(decoder.codecName)): "
                        + "\(missing) leading picture(s) after the opening keyframe reference the "
                        + "previous segment (open GOP in the source); a cold start here skips them"))
                } else {
                    check.problems.append((.error, "stream \(index) (\(decoder.codecName)): "
                        + "\(videoPackets) packet(s) produced only \(decoder.frames) frame(s)"))
                }
            }
        }
        if check.packets == 0 {
            check.problems.append((.error, "segment carries no packets"))
        } else if videoPackets == 0, decoders.values.contains(where: \.isVideo) {
            check.problems.append((.error, "init declares video but the segment carries none"))
        }

        if let timingBase, timingTicks > 0 {
            let seconds = Double(timingTicks) * av_q2d(timingBase)
            check.mediaDuration = seconds
            // A client plans its buffer and its seek targets on #EXTINF, so a
            // segment much longer or shorter than declared plays but lands
            // seeks in the wrong place. Loose on purpose: fMP4 packet
            // durations round, and audio frames never tile a boundary exactly.
            if let expectedDuration, abs(seconds - expectedDuration) > max(0.5, expectedDuration * 0.1) {
                check.problems.append((.warning, String(
                    format: "media lasts %.3fs but #EXTINF says %.3fs", seconds, expectedDuration
                )))
            }
        }
        return check
    }

    // MARK: - Helpers

    private static func fetchData(_ url: URL, _ session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchFailure(url: url, status: http.statusCode)
        }
        return data
    }

    private static func fetchText(_ url: URL, _ session: URLSession) async throws -> String {
        String(decoding: try await fetchData(url, session), as: UTF8.self)
    }

    /// A URLError's one-line reason rather than its whole userInfo dump.
    private static func describe(_ error: any Error) -> String {
        if let failure = error as? FetchFailure { return failure.description }
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription) (URLError \(urlError.code.rawValue))"
        }
        return "\(error)"
    }

    private static func resolve(_ uri: String, against playlist: URL) -> URL {
        URL(string: uri, relativeTo: playlist)?.absoluteURL
            ?? playlist.deletingLastPathComponent().appendingPathComponent(uri)
    }

    private static func relativeName(_ url: URL, to top: URL) -> String {
        let base = top.deletingLastPathComponent().absoluteString
        let full = url.absoluteString
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
    }

    package struct FetchFailure: Error, CustomStringConvertible {
        package let url: URL
        package let status: Int
        package var description: String { "GET \(url.absoluteString) answered HTTP \(status)" }
    }
}

/// One stream's libavcodec decoder, counting what it produced and what it
/// refused.
private final class StreamDecoder {
    enum MakeFailure: Error, CustomStringConvertible {
        case noDecoder(String)
        case openFailed(String)
        var description: String {
            switch self {
            case .noDecoder(let codec): return "no decoder for \(codec) in this build"
            case .openFailed(let message): return "decoder would not open: \(message)"
            }
        }
    }

    let isVideo: Bool
    let codecName: String
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private(set) var frames = 0
    private(set) var corruptFrames = 0
    private(set) var errors: [String] = []

    private init(context: UnsafeMutablePointer<AVCodecContext>, isVideo: Bool, codecName: String) {
        self.context = context
        self.isVideo = isVideo
        self.codecName = codecName
        self.frame = av_frame_alloc()
    }

    static func make(stream: UnsafeMutablePointer<AVStream>) -> Result<StreamDecoder, MakeFailure> {
        let parameters = stream.pointee.codecpar!
        let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            return .failure(.noDecoder(name))
        }
        guard let context = avcodec_alloc_context3(codec) else {
            return .failure(.openFailed("avcodec_alloc_context3 returned nil"))
        }
        var owned: UnsafeMutablePointer<AVCodecContext>? = context
        var result = avcodec_parameters_to_context(context, parameters)
        if result >= 0 {
            // Without it the decoder has no clock for the packets' timestamps
            // (the subtitle lesson in AGENTS.md applies to every decoder).
            context.pointee.pkt_timebase = stream.pointee.time_base
            result = avcodec_open2(context, codec, nil)
        }
        guard result >= 0 else {
            avcodec_free_context(&owned)
            return .failure(.openFailed(FFmpegError(code: result, operation: "avcodec_open2").message))
        }
        return .success(StreamDecoder(
            context: context,
            isVideo: parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
            codecName: name
        ))
    }

    /// Send one packet (or `nil` to flush) and drain every frame it releases.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?) {
        guard let context, let frame else { return }
        let sent = avcodec_send_packet(context, packet)
        if sent < 0, sent != swift_AVERROR(EAGAIN), sent != swift_AVERROR_EOF() {
            errors.append(FFmpegError(code: sent, operation: "avcodec_send_packet").message)
        }
        while true {
            let received = avcodec_receive_frame(context, frame)
            if received == swift_AVERROR(EAGAIN) || received == swift_AVERROR_EOF() { break }
            if received < 0 {
                errors.append(FFmpegError(code: received, operation: "avcodec_receive_frame").message)
                break
            }
            frames += 1
            // `AV_FRAME_FLAG_CORRUPT` is `1 << 0` — a macro Swift cannot
            // import, and the flag a decoder raises for a picture it
            // concealed rather than decoded.
            if frame.pointee.flags & (1 << 0) != 0 || frame.pointee.decode_error_flags != 0 {
                corruptFrames += 1
            }
            av_frame_unref(frame)
        }
    }

    func close() {
        av_frame_free(&frame)
        avcodec_free_context(&context)
    }
}
