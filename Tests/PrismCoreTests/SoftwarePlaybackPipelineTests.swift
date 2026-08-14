import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import PrismCore

// MARK: - Test doubles

/// A renderer stand-in that behaves like one: it holds a bounded queue, stops
/// being ready when that queue is full, and only wants more once something has
/// played out (`playOut()`).
///
/// The bounded queue is not decoration. The pipeline's feed loop has exactly one
/// brake — `isReadyForMoreMediaData` — because that is the contract
/// `AVQueuedSampleBufferRendering` offers; a fake that is *always* ready makes
/// the loop read a whole file at load, which is a property of the fake, not of
/// the pipeline. Modelling the back-pressure is what makes the pacing assertions
/// mean anything.
class RecordingSink {
    /// Buffers the renderer is holding, i.e. not yet "played".
    private(set) var queued: [CMSampleBuffer] = []
    /// Everything ever enqueued, flushes included — the assertion surface.
    private(set) var enqueued: [CMSampleBuffer] = []
    private(set) var didStopRequesting = false
    /// Simulates a renderer that has stopped draining entirely (backgrounded
    /// app, off-screen layer).
    var isBlocked = false
    let capacity: Int
    /// The pull callback the pipeline installed; invoked the way a real renderer
    /// would once its queue drains.
    var requestBlock: (() -> Void)?

    init(capacity: Int) {
        self.capacity = capacity
    }

    var isReadyForMoreSamples: Bool { !isBlocked && queued.count < capacity }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queued.append(sampleBuffer)
        enqueued.append(sampleBuffer)
    }

    func requestSamples(on queue: DispatchQueue, using block: @escaping () -> Void) {
        requestBlock = block
    }

    func stopRequestingSamples() {
        didStopRequesting = true
        requestBlock = nil
    }

    /// Play out everything held and ask for more — one renderer callback.
    func playOut() {
        queued.removeAll()
        requestBlock?()
    }

    func discardQueue() {
        queued.removeAll()
        enqueued.removeAll()
    }
}

final class RecordingVideoSink: RecordingSink, VideoSampleSink {
    /// One entry per flush, carrying `removingDisplayedImage`.
    private(set) var flushes: [Bool] = []

    init() {
        // ~1/3 s at 24 fps: a plausible display-layer queue.
        super.init(capacity: 8)
    }

    func flush(removingDisplayedImage: Bool) {
        flushes.append(removingDisplayedImage)
        // A real renderer discards its queue on flush; matching that is what
        // makes "what arrived after the seek" a meaningful assertion.
        discardQueue()
    }
}

final class RecordingAudioSink: RecordingSink, AudioSampleSink {
    private(set) var flushCount = 0

    init() {
        super.init(capacity: 32)
    }

    func flush() {
        flushCount += 1
        discardQueue()
    }
}

/// A clock that only remembers what it was told. Enough to assert the anchoring
/// and rate discipline; a clock that actually advanced would make every
/// assertion timing-dependent.
final class RecordingTimeline: RenderTimeline {
    private(set) var storedTime: CMTime = .zero
    private(set) var storedRate: Float = 0
    private(set) var rateChanges: [(rate: Float, time: CMTime)] = []
    private(set) var attachedRenderers = 0

    var currentTime: CMTime { storedTime }
    var rate: Float { storedRate }

    func setRate(_ rate: Float, time: CMTime) {
        storedRate = rate
        storedTime = time
        rateChanges.append((rate, time))
    }

    func attach(_ sink: SampleBufferSink) {
        attachedRenderers += 1
    }

    func detach(_ sink: SampleBufferSink) {
        attachedRenderers -= 1
    }
}

// MARK: - Tests

/// Everything up to the enqueue boundary: demux → decode → stamp → back-pressure
/// → enqueue, plus the transport's effect on the master clock. The renderers
/// themselves are the one thing a headless test cannot exercise, so they are the
/// one thing replaced.
@Suite("Software playback pipeline", .serialized)
struct SoftwarePlaybackPipelineTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func makePipeline(
        pacing: SoftwarePlaybackPipeline.Pacing = SoftwarePlaybackPipeline.Pacing()
    ) -> (SoftwarePlaybackPipeline, RecordingVideoSink, RecordingAudioSink, RecordingTimeline) {
        let video = RecordingVideoSink()
        let audio = RecordingAudioSink()
        let timeline = RecordingTimeline()
        let pipeline = SoftwarePlaybackPipeline(
            videoSink: video,
            audioSink: audio,
            timeline: timeline,
            pacing: pacing,
            // CPU decode so the test asserts one deterministic path; the
            // hardware route is covered in SoftwareDecodeTests.
            allowHardwareDecode: false
        )
        return (pipeline, video, audio, timeline)
    }

    @Test("Loading a VP9 source primes the display sink and parks the clock on the first frame")
    func loadPrimesVideo() throws {
        let (pipeline, video, audio, timeline) = makePipeline()
        try pipeline.load(url: try fixture("vp9.webm"))
        defer { pipeline.stop() }

        #expect(pipeline.state == .paused)
        #expect(!video.enqueued.isEmpty, "the host must have a frame to show before play()")
        #expect(audio.enqueued.isEmpty, "the fixture has no audio track")

        // Only the video renderer joined the synchronizer: an audio renderer
        // that will never be fed has no business holding a timebase.
        #expect(timeline.attachedRenderers == 1)

        // Clock parked (rate 0) on the first frame's own timestamp — the source
        // axis, not zero-based.
        #expect(timeline.rate == 0)
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(video.enqueued[0])
        #expect(timeline.currentTime == firstPTS)
        print("software pipeline route: \(pipeline.routeDescription)")

        // What a host's seek bar reads once: the fixture is a couple of
        // seconds, and the container knows it.
        let duration = try #require(pipeline.durationSeconds)
        #expect(duration > 0.5 && duration < 60)
    }

    /// The coupling bug this pipeline is shaped to avoid: with one cursor paced
    /// on the video renderer, a video renderer that stops draining stops the
    /// whole loop and audio starves behind it.
    @Test("A video renderer that never drains does not starve audio")
    func audioIsNotGatedOnVideo() throws {
        let (pipeline, video, audio, _) = makePipeline()
        video.isBlocked = true
        try pipeline.load(url: try fixture("h264_aac.mkv"))
        defer { pipeline.stop() }

        #expect(video.enqueued.isEmpty, "a renderer that isn't ready must not be enqueued to")
        #expect(!audio.enqueued.isEmpty, "audio must keep flowing while video is blocked")
    }

    @Test("Both streams are decoded and enqueued when both renderers drain")
    func feedsBothStreams() throws {
        let (pipeline, video, audio, timeline) = makePipeline()
        try pipeline.load(url: try fixture("h264_aac.mkv"))
        defer { pipeline.stop() }

        #expect(!video.enqueued.isEmpty)
        #expect(!audio.enqueued.isEmpty)
        #expect(timeline.attachedRenderers == 2)

        // Video anchors the clock even though audio usually leads the
        // interleave: anchoring on an audio buffer that precedes the first frame
        // would put that frame in the clock's past.
        let firstVideoPTS = CMSampleBufferGetPresentationTimeStamp(video.enqueued[0])
        #expect(timeline.currentTime == firstVideoPTS)
    }

    @Test("play() starts the master clock, pause() stops it where it was")
    func transportDrivesTheClock() throws {
        let (pipeline, _, _, timeline) = makePipeline()
        try pipeline.load(url: try fixture("vp9.webm"))
        defer { pipeline.stop() }

        pipeline.play()
        pipeline.waitForFeedQueue()
        #expect(pipeline.state == .playing)
        #expect(timeline.rate == 1)

        pipeline.pause()
        pipeline.waitForFeedQueue()
        #expect(pipeline.state == .paused)
        #expect(timeline.rate == 0)
    }

    @Test("A duration the container never stated is learned by EOF at the latest")
    func lateDurationIsLearned() throws {
        // A Matroska written to a pipe carries no duration element, and
        // libavformat does not estimate one for it — `ffprobe` answers N/A
        // even on a local file. Before #58 this pipeline answered nil for the
        // whole session; a host's seek bar had no timeline and nothing to
        // wait for.
        let (pipeline, video, audio, _) = makePipeline()
        try pipeline.load(url: try fixture("h264_aac_noduration.mkv"))
        defer { pipeline.stop() }
        #expect(pipeline.durationSeconds == nil, "the fixture must not know its duration at load")

        pipeline.play()
        pipeline.waitForFeedQueue()
        var pulls = 0
        while pipeline.state != .ended, pulls < 1_000 {
            video.playOut()
            audio.playOut()
            pulls += 1
        }
        #expect(pipeline.state == .ended)

        // 2 s of content: the furthest packet end is the duration of record.
        let learned = try #require(pipeline.durationSeconds)
        #expect(learned > 1.5 && learned < 2.5, "learned \(learned)s for a 2 s source")
    }

    @Test("Draining to EOF delivers every frame in order and ends")
    func drainsToEndOfStream() throws {
        let (pipeline, video, audio, _) = makePipeline()
        try pipeline.load(url: try fixture("vp9.webm"))
        defer { pipeline.stop() }
        pipeline.play()
        pipeline.waitForFeedQueue()

        // Stand in for the renderer's own pull: keep asking until the pipeline
        // says it has nothing left.
        var pulls = 0
        while pipeline.state != .ended, pulls < 1_000 {
            video.playOut()
            audio.playOut()
            pulls += 1
        }
        #expect(pipeline.state == .ended)

        // 4 s at 24 fps. Asserted as a range because the decoder's tail depends
        // on the encoder's lag, not on anything we control.
        #expect(video.enqueued.count >= 90, "got \(video.enqueued.count) frames")
        #expect(audio.enqueued.isEmpty)

        var previous: CMTime?
        for frame in video.enqueued {
            let pts = CMSampleBufferGetPresentationTimeStamp(frame)
            if let previous { #expect(pts > previous) }
            previous = pts
        }
    }

    @Test("Seek flushes both renderers, holds the displayed image, and re-anchors the clock")
    func seekFlushesAndReanchors() throws {
        let (pipeline, video, audio, timeline) = makePipeline()
        try pipeline.load(url: try fixture("h264_aac.mkv"))
        defer { pipeline.stop() }
        #expect(video.flushes.isEmpty)

        pipeline.seek(to: CMTime(seconds: 4, preferredTimescale: 600))
        pipeline.waitForFeedQueue()

        // Exactly one flush, and it kept the last frame on screen: a black flash
        // through a seek reads as a bug, and the post-seek keyframe can be
        // hundreds of milliseconds of decode away on this path's codecs.
        #expect(video.flushes == [false])
        #expect(audio.flushCount == 1)

        // Refilled, and the clock re-anchored on the first buffer of the new run
        // rather than on the requested time (keyframe-accurate seek).
        #expect(!video.enqueued.isEmpty)
        #expect(timeline.rate == 0, "a seek from paused stays paused")
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(video.enqueued[0])
        #expect(timeline.currentTime == firstPTS)
    }

    @Test("A seek while playing resumes at rate 1")
    func seekWhilePlayingResumes() throws {
        let (pipeline, _, _, timeline) = makePipeline()
        try pipeline.load(url: try fixture("h264_aac.mkv"))
        defer { pipeline.stop() }
        pipeline.play()
        pipeline.waitForFeedQueue()

        pipeline.seek(to: CMTime(seconds: 2, preferredTimescale: 600))
        pipeline.waitForFeedQueue()

        #expect(pipeline.state == .playing)
        #expect(timeline.rate == 1)
    }

    @Test("stop() stops the pulls, clears the picture, and detaches the renderers")
    func stopTearsDown() throws {
        let (pipeline, video, audio, timeline) = makePipeline()
        try pipeline.load(url: try fixture("h264_aac.mkv"))
        pipeline.stop()

        #expect(pipeline.state == .idle)
        #expect(video.didStopRequesting)
        #expect(audio.didStopRequesting)
        // Teardown is the one flush that *does* clear the visible frame.
        #expect(video.flushes.last == true)
        #expect(timeline.attachedRenderers == 0)
        #expect(timeline.rate == 0)
    }

    @Test("Loading twice is refused — a pipeline is single-use")
    func loadIsSingleUse() throws {
        let (pipeline, _, _, _) = makePipeline()
        try pipeline.load(url: try fixture("vp9.webm"))
        defer { pipeline.stop() }
        #expect(throws: SoftwarePlaybackPipeline.Failure.self) {
            try pipeline.load(url: try self.fixture("vp9.webm"))
        }
    }

    @Test("A missing source fails the load and leaves the pipeline in .failed")
    func missingSourceFails() throws {
        let (pipeline, _, _, _) = makePipeline()
        #expect(throws: (any Error).self) {
            try pipeline.load(url: URL(fileURLWithPath: "/definitely/not/here.webm"))
        }
        #expect(pipeline.state == .failed)
    }
}
