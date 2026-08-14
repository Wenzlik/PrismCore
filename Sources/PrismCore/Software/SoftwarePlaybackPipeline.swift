import Foundation
import AVFoundation
import CoreMedia
import Libavcodec
import Libavformat
import Libavutil

/// The software decode path (roadmap phase 7): demux with libavformat, decode
/// with libavcodec, render with `AVSampleBufferDisplayLayer` +
/// `AVSampleBufferAudioRenderer` under an `AVSampleBufferRenderSynchronizer`.
///
/// This is where sources go that AVPlayer's HLS-fMP4 pipeline cannot carry at
/// all — VP9/VP8, MPEG-2, MPEG-4 ASP, VC-1, interlaced H.264. Unlike the rest
/// of PrismCore, it is a *player*, not a service: there is no AVPlayer to hand a
/// URL to, so this type owns the transport and the clock.
///
/// ```swift
/// let pipeline = SoftwarePlaybackPipeline()
/// try pipeline.load(url: webmURL)          // synchronous; call off the main thread
/// hostView.layer.addSublayer(pipeline.displayLayer!)
/// pipeline.play()
/// ```
///
/// ## Pacing, and why audio is not gated on video
///
/// Both renderers publish `isReadyForMoreMediaData` and both call back through
/// `requestMediaDataWhenReady`. The obvious loop — one cursor, paced on the
/// *video* renderer's readiness — is a classic pipeline trap: as soon
/// as video stops draining (a backgrounded app, a display layer off screen, a
/// decode that briefly outruns the queue) the gate never reopens, and audio
/// starves behind it even though its own renderer is begging for data. That is
/// audible as a dropout, and it is a coupling bug, not a throughput problem.
///
/// So the loop reads while *either* stream still wants data, decodes into two
/// small pending queues, and each renderer drains its own queue on its own
/// callback. Video being full therefore cannot stop audio from being read,
/// decoded and enqueued; the cost is that chasing audio past a full video queue
/// lets the video queue grow by roughly the container's interleave distance,
/// which a hard cap bounds (see `Pacing`). A pathological interleave stops reads
/// instead of growing memory — the honest failure. An independent
/// audio look-ahead cursor is the refinement this shape leaves room for.
///
/// ## Audio track switching
///
/// `selectAudioTrack(streamIndex:)` swaps the audio decoder mid-playback,
/// leaving the clock and the video renderer untouched (issue #35). The new
/// decoder is built *before* the old one is torn down — a track whose decoder
/// can't open leaves the current track playing rather than leaving silence —
/// and the demuxer is then rewound to the clock's present so the new track
/// starts where the listener is, not where the read cursor had run ahead to.
/// The rewind re-reads video the renderer already holds; those frames are
/// dropped by timestamp instead of re-enqueued, which is what keeps the video
/// path a bystander. On a source that refuses the rewind (no index), the new
/// track joins at the read position instead — a gap of the queue's look-ahead,
/// which beats refusing the switch.
///
/// ## Not here yet
///
/// Integration with `PrismCoreSession` and the loopback (deliberately out of
/// scope for this skeleton), deinterlacing for interlaced H.264, subtitle
/// rendering, subtitle track selection (nothing renders them here yet — see
/// `sourceInfo` for what exists to select), and an exact end-of-playout signal (`.ended`
/// fires when the last decoded buffer has been *enqueued*, not when the speaker
/// has finished it; a host that needs the latter should observe the
/// synchronizer's boundary time).
public final class SoftwarePlaybackPipeline: @unchecked Sendable {

    // MARK: - Public surface

    public enum State: String, Sendable, Equatable {
        case idle
        case loading
        case paused
        case playing
        /// Every decoded buffer has been handed to the renderers.
        case ended
        case failed
    }

    public enum Failure: Error, CustomStringConvertible {
        case alreadyLoaded
        case notLoaded
        /// The container has no stream this path can decode.
        case noDecodableStream

        public var description: String {
            switch self {
            case .alreadyLoaded: return "pipeline is single-use — make a new one per load"
            case .notLoaded: return "load(url:) has not run"
            case .noDecodableStream: return "no decodable video or audio stream in the source"
            }
        }
    }

    /// Queue depths, in decoded buffers.
    ///
    /// Small on purpose: these queues exist to decouple the two renderers'
    /// drain schedules, not to buffer playback (the renderers do that
    /// themselves, and a deep queue here only delays a seek's flush).
    struct Pacing {
        /// ~0.25 s at 24 fps.
        var videoDepth = 6
        /// ~0.5–0.7 s of audio, depending on the codec's frame size. Deeper than
        /// video because audio dropouts are far more noticeable than a late
        /// frame, so this is the queue that should be able to ride out a stall.
        var audioDepth = 24
        /// Multiple of the depth at which reads stop even though the other
        /// stream still wants data. Bounds the "chasing audio past a full video
        /// queue" case above.
        var hardCapMultiplier = 4
    }

    /// Called on the feed queue whenever `state` changes. Set before `load`.
    public var onStateChange: (@Sendable (State) -> Void)?

    public var state: State {
        stateLock.withLock { storedState }
    }

    /// Master-clock time, i.e. the presentation time being rendered. On the
    /// source's own axis (the pipeline never rebases timestamps to zero).
    public var currentTime: CMTime {
        timeline.currentTime
    }

    /// Whole-source duration in seconds, `nil` until `load` — and for sources
    /// whose container honestly doesn't know (live ingests). A host's seek bar
    /// wants this once, not a stream to observe: it cannot change mid-file.
    public var durationSeconds: Double? {
        stateLock.withLock { storedDurationSeconds }
    }

    /// The pipeline's own output level, `0…1`. Scales the audio renderer, not
    /// the device — a host's volume drag has no honest system-level lever, so
    /// this is the same contract AVPlayer's `volume` offers.
    public var volume: Float {
        get { (audioSink as? AudioRendererSink)?.renderer.volume ?? 1 }
        set { (audioSink as? AudioRendererSink)?.renderer.volume = max(0, min(1, newValue)) }
    }

    /// The layer to put in the host's view hierarchy. `nil` when the pipeline
    /// was built with injected sinks (tests).
    public var displayLayer: AVSampleBufferDisplayLayer? {
        (videoSink as? DisplayLayerVideoSink)?.layer
    }

    /// What each decoder ended up doing, for diagnostics: which route the video
    /// took (VideoToolbox zero-copy vs CPU) and the audio's output format.
    public var routeDescription: String {
        [videoDecoder?.routeDescription, audioDecoder?.routeDescription]
            .compactMap { $0 }
            .joined(separator: "; ")
    }

    /// The probe's description of the loaded source — the same facts
    /// `SourceProbe` reports for routing (tracks with language/title/channels,
    /// chapters, subtitle streams), read off this pipeline's own context at
    /// `load`. `nil` before `load`.
    ///
    /// This is the enumeration half of track selection: a host transport lists
    /// `sourceInfo.audioTracks` (or `selectableAudioTracks`, already filtered
    /// to what this build can decode) and drives `selectAudioTrack` with the
    /// entry's `streamIndex`.
    public var sourceInfo: SourceInfo? {
        stateLock.withLock { storedSourceInfo }
    }

    /// The audio tracks `selectAudioTrack(streamIndex:)` will accept: every
    /// audio stream this build has a decoder for, in stream order. A track in
    /// `sourceInfo.audioTracks` but not here exists in the container and cannot
    /// be played by this build — worth showing disabled, not hiding.
    public var selectableAudioTracks: [AudioTrackInfo] {
        stateLock.withLock { storedSelectableAudioTracks }
    }

    /// The source stream index of the audio track currently feeding the
    /// renderer — the selection a host's audio menu marks. `nil` when the
    /// source has no decodable audio (or before `load`).
    public var selectedAudioStreamIndex: Int? {
        stateLock.withLock {
            storedSelectedAudioStreamIndex >= 0 ? Int(storedSelectedAudioStreamIndex) : nil
        }
    }

    // MARK: - Collaborators

    private let videoSink: VideoSampleSink
    private let audioSink: AudioSampleSink
    private let timeline: RenderTimeline
    private let pacing: Pacing
    private let allowHardwareDecode: Bool

    /// Everything below — the demuxer, the decoders, the pending queues — is
    /// touched only on this serial queue, which is also the queue both renderers
    /// call back on. That is the whole concurrency story: no locks around
    /// libav* state, because there is only ever one thread in it.
    private let feedQueue = DispatchQueue(label: "cz.aether.prismcore.software.feed", qos: .userInitiated)

    private let stateLock = NSLock()
    private var storedState: State = .idle
    private var storedDurationSeconds: Double?
    private var storedSourceInfo: SourceInfo?
    private var storedSelectableAudioTracks: [AudioTrackInfo] = []
    /// Mirror of `audioStreamIndex` (feed-queue state) for cross-thread reads.
    private var storedSelectedAudioStreamIndex: Int32 = -1

    // MARK: - Feed-queue state

    private var input: UnsafeMutablePointer<AVFormatContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var videoDecoder: SoftwareVideoDecoder?
    private var audioDecoder: SoftwareAudioDecoder?
    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1

    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []

    private var reachedEOF = false
    private var stopped = false
    /// The newest video PTS handed to the sink — where the renderer's picture
    /// horizon is. A track switch rewinds the demuxer to the clock's present,
    /// so the video decoder re-emits frames the renderer already holds; this
    /// is the watermark that identifies them.
    private var lastEnqueuedVideoPTS: CMTime = .invalid
    /// Set by a track switch: drop re-decoded video up to and including this
    /// PTS (the renderer already has it), cleared once a frame passes it.
    private var discardVideoUpTo: CMTime = .invalid
    /// Set by a track switch: drop audio that ends at or before this time —
    /// the rewind lands on a keyframe *before* the clock's present, and audio
    /// from that gap would either be dropped late by the renderer (playing) or
    /// worse, played as a stale burst (paused). Cleared once a buffer crosses it.
    private var discardAudioBefore: CMTime = .invalid
    /// False until the master clock has been parked on the first decoded
    /// buffer's timestamp. Cleared by a seek, which re-anchors on the first
    /// buffer after it.
    private var clockAnchored = false
    private var anchorTime: CMTime = .zero

    // MARK: - Init

    /// The shipping configuration: a real display layer, audio renderer and
    /// synchronizer.
    public convenience init(allowHardwareDecode: Bool = true) {
        let video = DisplayLayerVideoSink()
        let audio = AudioRendererSink()
        self.init(
            videoSink: video,
            audioSink: audio,
            timeline: SynchronizerTimeline(),
            allowHardwareDecode: allowHardwareDecode
        )
    }

    /// Injected seam — the constructor tests use. See `SampleBufferSinks.swift`
    /// for why the boundary sits here.
    init(
        videoSink: VideoSampleSink,
        audioSink: AudioSampleSink,
        timeline: RenderTimeline,
        pacing: Pacing = Pacing(),
        allowHardwareDecode: Bool = true
    ) {
        self.videoSink = videoSink
        self.audioSink = audioSink
        self.timeline = timeline
        self.pacing = pacing
        self.allowHardwareDecode = allowHardwareDecode
    }

    deinit {
        // Best effort: a pipeline dropped without stop() still must not leak an
        // AVFormatContext. Safe to run here because deinit means nothing else
        // holds a reference, so no feed-queue work can be in flight.
        teardown()
    }

    // MARK: - Transport

    /// Open the source, pick streams, build decoders, and decode enough to park
    /// the master clock on the first frame. Synchronous — call it off the main
    /// thread, like `HLSRemuxer.run()`.
    public func load(url: URL, httpHeaders: [String: String] = [:]) throws {
        try feedQueue.sync {
            guard input == nil, !stopped else { throw Failure.alreadyLoaded }
            setState(.loading)
            do {
                try openInput(url: url, httpHeaders: httpHeaders)
                try makeDecoders()
                // Prime: fill the queues and park the clock, so the host sees a
                // first frame on the layer before it ever calls play().
                pump()
                startRequestingSamples()
                setState(.paused)
            } catch {
                teardown()
                setState(.failed)
                throw error
            }
        }
    }

    public func play() {
        feedQueue.async { [self] in
            guard input != nil, !stopped else { return }
            // Resuming from `.ended` would need a seek first; a host that wants
            // replay calls seek(to: .zero) then play().
            guard storedStateIsResumable else { return }
            timeline.setRate(1, time: clockAnchored ? timeline.currentTime : anchorTime)
            setState(.playing)
            pump()
        }
    }

    public func pause() {
        feedQueue.async { [self] in
            guard input != nil, !stopped, state == .playing else { return }
            timeline.setRate(0, time: timeline.currentTime)
            setState(.paused)
        }
    }

    /// Keyframe-accurate seek: libavformat lands on the keyframe at or before
    /// `time`, the decoders are flushed, and the clock re-anchors on the first
    /// buffer that comes out — so playback resumes at that keyframe rather than
    /// exactly at `time`. Frame-accurate seeking means decoding and discarding
    /// up to the target, which belongs with phase 5's segment plan, not here.
    public func seek(to time: CMTime) {
        feedQueue.async { [self] in
            guard let input, !stopped else { return }
            let wasPlaying = state == .playing

            // Stop the clock first: refilling under a running clock means every
            // buffer we enqueue lands in the clock's past and is dropped.
            timeline.setRate(0, time: timeline.currentTime)

            let target = max(0, Int64(CMTimeGetSeconds(time) * Double(AV_TIME_BASE)))
            // Stream index -1 + AV_TIME_BASE units: let libavformat pick the
            // reference stream (its own index is usually the video one) instead
            // of us rescaling onto a guess.
            let seekResult = av_seek_frame(input, -1, target, AVSEEK_FLAG_BACKWARD)
            if seekResult < 0 {
                // A source with no index (raw MPEG-2 TS) can refuse; leaving the
                // demuxer where it is beats tearing the session down.
                setState(wasPlaying ? .playing : .paused)
                if wasPlaying { timeline.setRate(1, time: timeline.currentTime) }
                return
            }

            videoDecoder?.flushBuffers()
            audioDecoder?.flushBuffers()
            pendingVideo.removeAll()
            pendingAudio.removeAll()
            // Hold the last frame instead of blanking: the post-seek keyframe can
            // be half a second of decode away on exactly the codecs this path
            // serves, and a black flash reads as a bug.
            videoSink.flush(removingDisplayedImage: false)
            audioSink.flush()
            reachedEOF = false
            clockAnchored = false
            // The renderer's queue is gone with the flush, and any in-flight
            // track-switch discard is moot — the seek moved the target.
            lastEnqueuedVideoPTS = .invalid
            discardVideoUpTo = .invalid
            discardAudioBefore = .invalid

            pump()
            setState(wasPlaying ? .playing : .paused)
            if wasPlaying {
                timeline.setRate(1, time: anchorTime)
            }
        }
    }

    /// Switch the audio to another of the source's tracks, mid-playback,
    /// without touching the clock or the video renderer (issue #35).
    ///
    /// `streamIndex` is the source stream index, i.e.
    /// `AudioTrackInfo.streamIndex` from `selectableAudioTracks`. Selecting the
    /// already-playing track is a no-op that still reports success. The switch
    /// is refused (`completion(false)`) when the pipeline isn't in a playable
    /// state, the index isn't a selectable audio stream, or the new track's
    /// decoder fails to open — in every refusal the current track keeps
    /// playing, because the old decoder is only torn down *after* the new one
    /// stands.
    ///
    /// The audible gap is the seek + decode-to-playhead time, tens of
    /// milliseconds on a local source; the clock never stops, so A/V sync and
    /// the picture are unaffected. Works identically while paused — the new
    /// track is primed at the paused position and plays on `play()`.
    ///
    /// - Parameter completion: called on the feed queue with whether the
    ///   switch happened. Optional — fire-and-forget is fine for a menu tap;
    ///   read `selectedAudioStreamIndex` for the settled answer.
    public func selectAudioTrack(
        streamIndex: Int,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        feedQueue.async { [self] in
            guard let input, !stopped, storedStateIsResumable else {
                completion?(false)
                return
            }
            guard Int32(streamIndex) != audioStreamIndex else {
                completion?(true)
                return
            }
            guard streamIndex >= 0, streamIndex < Int(input.pointee.nb_streams),
                  let stream = input.pointee.streams[streamIndex],
                  stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
            else {
                completion?(false)
                return
            }

            // New decoder first: a track whose decoder can't open must leave
            // the current track playing, not playback silent.
            let newDecoder: SoftwareAudioDecoder
            do {
                newDecoder = try SoftwareAudioDecoder(
                    codecpar: stream.pointee.codecpar,
                    timeBase: stream.pointee.time_base
                )
            } catch {
                completion?(false)
                return
            }

            // Rewind the demuxer to the clock's present so the new track picks
            // up where the listener is, not where the read cursor had run
            // ahead to. `.invalid` clock (never anchored) means nothing has
            // played yet — the read position IS the present, skip the seek.
            let now = timeline.currentTime
            var rewound = false
            if now.isValid {
                let target = max(0, Int64(CMTimeGetSeconds(now) * Double(AV_TIME_BASE)))
                rewound = av_seek_frame(input, -1, target, AVSEEK_FLAG_BACKWARD) >= 0
                // A source with no index can refuse — the new track then joins
                // at the read position, a gap of the queue's look-ahead. Worse
                // than seamless, better than refusing the switch.
            }

            let hadAudio = audioDecoder != nil
            audioDecoder?.close()
            audioDecoder = newDecoder
            audioStreamIndex = Int32(streamIndex)
            stateLock.withLock { storedSelectedAudioStreamIndex = Int32(streamIndex) }
            pendingAudio.removeAll()
            audioSink.flush()

            if rewound {
                // The rewind re-reads video the renderer already holds: flush
                // the decoder (its reference chain broke with the seek) and
                // drop re-decoded frames up to the renderer's horizon, so the
                // video path never notices the switch happened.
                videoDecoder?.flushBuffers()
                pendingVideo.removeAll()
                discardVideoUpTo = lastEnqueuedVideoPTS
                // The rewind lands on a keyframe before the present; audio
                // from that gap is late (playing) or a stale burst on resume
                // (paused) — drop it here rather than trusting the renderer.
                discardAudioBefore = now
                reachedEOF = false
            }

            if !hadAudio {
                // The source loaded without a working audio decoder (the best
                // stream's codec is missing from this build) — the sink was
                // never attached, so the switch is also the audio bring-up.
                timeline.attach(audioSink)
                audioSink.requestSamples(on: feedQueue) { [weak self] in
                    self?.pump()
                }
            }

            pump()
            completion?(true)
        }
    }

    /// Tear everything down. The pipeline is single-use afterwards.
    public func stop() {
        feedQueue.sync {
            guard !stopped else { return }
            stopped = true
            timeline.setRate(0, time: timeline.currentTime)
            videoSink.stopRequestingSamples()
            audioSink.stopRequestingSamples()
            videoSink.flush(removingDisplayedImage: true)
            audioSink.flush()
            teardown()
            setState(.idle)
        }
    }

    /// Block until the feed queue has run everything already scheduled on it.
    /// Exists for tests, whose assertions would otherwise race the async
    /// transport calls; harmless in production and never called there.
    func waitForFeedQueue() {
        feedQueue.sync { }
    }

    // MARK: - Setup

    /// Same open pattern as `HLSRemuxer` / `SourceProbe`: the caller's headers
    /// ride the demux connection, and dropped HTTP connections reconnect. Kept
    /// local rather than shared for now — a fourth copy (phase 5's producer) is
    /// the point at which one `FFmpegInput` helper earns itself.
    private func openInput(url: URL, httpHeaders: [String: String]) throws {
        var openOptions: OpaquePointer?
        defer { av_dict_free(&openOptions) }
        if !httpHeaders.isEmpty {
            let headerBlob = httpHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
            av_dict_set(&openOptions, "headers", headerBlob, 0)
        }
        av_dict_set(&openOptions, "reconnect", "1", 0)
        av_dict_set(&openOptions, "reconnect_streamed", "1", 0)

        let sourceSpec = url.isFileURL ? url.path : url.absoluteString
        var context: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(
            avformat_open_input(&context, sourceSpec, nil, &openOptions),
            "avformat_open_input"
        )
        input = context
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        if let known = context?.pointee.duration, known != swift_AV_NOPTS_VALUE() {
            stateLock.withLock { storedDurationSeconds = Double(known) / Double(AV_TIME_BASE) }
        }

        // The probe's per-stream description, off this very context — track
        // menus and chapter markers for the host, plus the enumeration half of
        // audio selection. No interlace verification: that read consumes
        // packets, and this context's read position is the playback.
        if let context {
            let info = SourceProbe.describe(input: context)
            let selectable = info.audioTracks.filter { track in
                guard track.streamIndex < Int(context.pointee.nb_streams),
                      let stream = context.pointee.streams[track.streamIndex]
                else { return false }
                return avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id) != nil
            }
            stateLock.withLock {
                storedSourceInfo = info
                storedSelectableAudioTracks = selectable
            }
        }

        guard let allocated = av_packet_alloc() else {
            throw FFmpegError(code: -1, operation: "av_packet_alloc")
        }
        packet = allocated
    }

    private func makeDecoders() throws {
        guard let input else { throw Failure.notLoaded }

        let video = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        if video >= 0, let stream = input.pointee.streams[Int(video)] {
            do {
                // Declared interlaced → run the deinterlacer. Routing only
                // sends *verified* interlaced sources here, so this mostly
                // agrees with the probe; when a host loads the pipeline
                // directly, `bwdif deint=interlaced` still passes progressive
                // frames through untouched, so over-engaging costs the
                // hardware route, never correctness.
                let fieldOrder = stream.pointee.codecpar.pointee.field_order
                let declaredInterlaced = fieldOrder == AV_FIELD_TT
                    || fieldOrder == AV_FIELD_BB
                    || fieldOrder == AV_FIELD_TB
                    || fieldOrder == AV_FIELD_BT
                videoDecoder = try SoftwareVideoDecoder(
                    codecpar: stream.pointee.codecpar,
                    timeBase: stream.pointee.time_base,
                    averageFrameRate: stream.pointee.avg_frame_rate,
                    allowHardware: allowHardwareDecode,
                    deinterlace: declaredInterlaced
                )
                videoStreamIndex = video
                timeline.attach(videoSink)
            } catch {
                // No decoder for this video codec in this build. Audio-only
                // playback of a video file is a poor experience but a better one
                // than a failed load, and `SoftwareDecoderAvailability` is how a
                // router avoids getting here in the first place.
                videoDecoder = nil
                videoStreamIndex = -1
            }
        }

        let audio = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, video, nil, 0)
        if audio >= 0, let stream = input.pointee.streams[Int(audio)] {
            do {
                audioDecoder = try SoftwareAudioDecoder(
                    codecpar: stream.pointee.codecpar,
                    timeBase: stream.pointee.time_base
                )
                audioStreamIndex = audio
                stateLock.withLock { storedSelectedAudioStreamIndex = audio }
                timeline.attach(audioSink)
            } catch {
                audioDecoder = nil
                audioStreamIndex = -1
            }
        }

        guard videoDecoder != nil || audioDecoder != nil else {
            throw Failure.noDecodableStream
        }
    }

    /// Both renderers pull on the same serial queue, so a callback can never run
    /// concurrently with the feed loop — it just re-enters it.
    private func startRequestingSamples() {
        if videoDecoder != nil {
            videoSink.requestSamples(on: feedQueue) { [weak self] in
                self?.pump()
            }
        }
        if audioDecoder != nil {
            audioSink.requestSamples(on: feedQueue) { [weak self] in
                self?.pump()
            }
        }
    }

    // MARK: - The feed loop

    /// One pass of drain-then-read. Always on `feedQueue`.
    private func pump() {
        guard !stopped, input != nil else { return }
        do {
            while !stopped {
                drainPending()

                if reachedEOF {
                    if pendingVideo.isEmpty, pendingAudio.isEmpty, state != .ended {
                        setState(.ended)
                    }
                    return
                }

                let videoWantsMore = videoDecoder != nil && pendingVideo.count < pacing.videoDepth
                let audioWantsMore = audioDecoder != nil && pendingAudio.count < pacing.audioDepth
                guard videoWantsMore || audioWantsMore else { return }

                // The bound on "read for whoever is still hungry": one stream's
                // queue may run ahead of its depth while we chase the other, but
                // not without limit.
                let videoCapped = pendingVideo.count >= pacing.videoDepth * pacing.hardCapMultiplier
                let audioCapped = pendingAudio.count >= pacing.audioDepth * pacing.hardCapMultiplier
                if videoCapped || audioCapped { return }

                try readAndDecodeOnePacket()
            }
        } catch {
            fail(error)
        }
    }

    /// Hand each sink as much as it will take. Per-sink, so a full video
    /// renderer never blocks the audio renderer.
    private func drainPending() {
        while let next = pendingVideo.first, videoSink.isReadyForMoreSamples {
            videoSink.enqueue(next)
            pendingVideo.removeFirst()
            let pts = CMSampleBufferGetPresentationTimeStamp(next)
            if pts.isValid, !lastEnqueuedVideoPTS.isValid || pts > lastEnqueuedVideoPTS {
                lastEnqueuedVideoPTS = pts
            }
        }
        while let next = pendingAudio.first, audioSink.isReadyForMoreSamples {
            audioSink.enqueue(next)
            pendingAudio.removeFirst()
        }
    }

    private func readAndDecodeOnePacket() throws {
        guard let input, let packet else { return }

        let readResult = av_read_frame(input, packet)
        if readResult == swift_AVERROR_EOF() {
            reachedEOF = true
            // Drain the decoders: a frame-threaded decoder holds several frames
            // at EOF, and they are real picture.
            try videoDecoder?.decode(nil, emit: acceptVideo)
            try audioDecoder?.decode(nil, emit: acceptAudio)
            return
        }
        try FFmpegError.check(readResult, "av_read_frame")
        defer { av_packet_unref(packet) }

        switch Int32(packet.pointee.stream_index) {
        case videoStreamIndex:
            try videoDecoder?.decode(packet, emit: acceptVideo)
        case audioStreamIndex:
            try audioDecoder?.decode(packet, emit: acceptAudio)
        default:
            break   // a stream we didn't select (second audio track, subtitles)
        }
    }

    private func acceptVideo(_ sampleBuffer: CMSampleBuffer) throws {
        // A track switch's rewind re-decodes frames the renderer already
        // holds; re-enqueuing them would make the video path a participant in
        // an audio-only operation. Drop up to the watermark, then stand down.
        if discardVideoUpTo.isValid {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid, pts <= discardVideoUpTo { return }
            discardVideoUpTo = .invalid
        }
        anchorClock(on: sampleBuffer)
        pendingVideo.append(sampleBuffer)
    }

    private func acceptAudio(_ sampleBuffer: CMSampleBuffer) throws {
        // The switch's rewind lands on a keyframe before the clock's present;
        // the new track's audio from that gap must not reach the renderer
        // (late while playing, a stale burst on resume while paused).
        if discardAudioBefore.isValid {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            let end = duration.isValid ? pts + duration : pts
            if end.isValid, end <= discardAudioBefore { return }
            discardAudioBefore = .invalid
        }
        // Video anchors the clock when there is video: starting the clock at an
        // audio buffer that precedes the first frame (common — audio leads in
        // most interleaves) would put the first frames in the clock's past.
        if videoDecoder == nil {
            anchorClock(on: sampleBuffer)
        }
        pendingAudio.append(sampleBuffer)
    }

    /// Park the master clock on the first buffer of a run (load, or after a
    /// seek). Rate stays where it is: `play()` starts it, and a seek that was
    /// playing restarts it once the queues are refilled.
    private func anchorClock(on sampleBuffer: CMSampleBuffer) {
        guard !clockAnchored else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid else { return }
        anchorTime = time
        clockAnchored = true
        timeline.setRate(0, time: time)
    }

    private var storedStateIsResumable: Bool {
        switch state {
        case .paused, .playing: return true
        case .idle, .loading, .ended, .failed: return false
        }
    }

    private func fail(_ error: any Error) {
        // A read or decode error ends the session: the renderers keep whatever
        // they were given (so the last second still plays out) and the state
        // tells the host to route elsewhere.
        videoSink.stopRequestingSamples()
        audioSink.stopRequestingSamples()
        timeline.setRate(0, time: timeline.currentTime)
        failureError = error
        setState(.failed)
    }

    /// The terminal error, if any. Polled by a host that saw `.failed`.
    public private(set) var failureError: (any Error)?

    // MARK: - Teardown

    private func teardown() {
        videoDecoder?.close()
        videoDecoder = nil
        audioDecoder?.close()
        audioDecoder = nil
        pendingVideo.removeAll()
        pendingAudio.removeAll()
        timeline.detach(videoSink)
        timeline.detach(audioSink)
        if packet != nil {
            av_packet_free(&packet)
        }
        if input != nil {
            avformat_close_input(&input)
        }
        videoStreamIndex = -1
        audioStreamIndex = -1
        stateLock.withLock { storedSelectedAudioStreamIndex = -1 }
    }

    private func setState(_ newState: State) {
        let changed: Bool = stateLock.withLock {
            guard storedState != newState else { return false }
            storedState = newState
            return true
        }
        guard changed else { return }
        onStateChange?(newState)
    }
}
