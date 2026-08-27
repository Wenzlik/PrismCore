import Foundation
import AVFoundation
import CoreMedia

/// The seam between "decode" and "render".
///
/// Nothing headless can prove a frame reached a display or a speaker, so the
/// pipeline is written against these three protocols and the AVFoundation
/// objects sit behind them. Tests drive the whole demux → decode → stamp →
/// enqueue chain with fakes and assert on what *would* have been rendered,
/// including the back-pressure behaviour, which is otherwise only observable on
/// a device with a real clock.
protocol SampleBufferSink: AnyObject {
    /// The renderer's own back-pressure signal. Enqueuing while this is false
    /// is how a software path turns into an unbounded memory leak.
    var isReadyForMoreSamples: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    /// Ask to be called back whenever the renderer wants data. Each sink pulls
    /// on its own schedule — that independence is what keeps audio fed while
    /// video is full (see `SoftwarePlaybackPipeline`).
    func requestSamples(on queue: DispatchQueue, using block: @escaping () -> Void)
    func stopRequestingSamples()
    /// The AVFoundation object a `AVSampleBufferRenderSynchronizer` has to be
    /// given so this sink's control timebase is driven by the master clock.
    /// `nil` for test doubles, which have no timebase to drive — the seam admits
    /// what it is instead of pretending the timeline can attach anything.
    var queuedRenderer: AVQueuedSampleBufferRendering? { get }
    /// Call `handler` on `queue` whenever the renderer reports it can no
    /// longer render what it holds (`status == .failed`, or the display
    /// layer's `requiresFlushToResumeDecoding`). The pipeline answers by
    /// flushing and re-priming; without the observation a renderer that lost
    /// its decode session in the background stays black for the rest of the
    /// film, with `isReadyForMoreMediaData` cheerfully true.
    func observeFailure(on queue: DispatchQueue, handler: @escaping () -> Void)
    func stopObservingFailure()
}

extension SampleBufferSink {
    var queuedRenderer: AVQueuedSampleBufferRendering? { nil }
    func observeFailure(on queue: DispatchQueue, handler: @escaping () -> Void) { }
    func stopObservingFailure() { }
}

protocol VideoSampleSink: SampleBufferSink {
    /// - Parameter removingDisplayedImage: false keeps the last frame on screen.
    ///   A seek passes false so the picture holds until the post-seek keyframe
    ///   decodes, instead of flashing black — which matters most on exactly the
    ///   codecs this path exists for (an MPEG-2 keyframe can be half a second
    ///   away). Teardown passes true.
    func flush(removingDisplayedImage: Bool)
}

protocol AudioSampleSink: SampleBufferSink {
    func flush()
}

/// The master clock. `AVSampleBufferRenderSynchronizer` drives both renderers'
/// control timebases, which is what makes A/V sync a property of the system
/// rather than something the feed loop has to maintain.
protocol RenderTimeline: AnyObject {
    var currentTime: CMTime { get }
    var rate: Float { get }
    func setRate(_ rate: Float, time: CMTime)
    /// Put a sink under this clock. Attached at load time rather than at init,
    /// because a renderer that is never fed (a video-only source's audio
    /// renderer) has no business holding a timebase.
    func attach(_ sink: SampleBufferSink)
    func detach(_ sink: SampleBufferSink)
    /// Call `handler` on `queue` once the clock reaches `time` while running.
    /// Returns a token for `cancelBoundaryObserver`, or `nil` when the
    /// timeline cannot observe (a test double with a clock that never moves).
    func observeBoundary(_ time: CMTime, on queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> Any?
    func cancelBoundaryObserver(_ token: Any)
}

// MARK: - AVFoundation implementations

/// `AVSampleBufferDisplayLayer` behind `VideoSampleSink`.
///
/// The `#available` split is load-bearing rather than cosmetic: from iOS 17 /
/// tvOS 17 / macOS 14 the enqueue surface moved to
/// `layer.sampleBufferRenderer` and the layer's own methods are deprecated, but
/// PrismCore's floor is iOS 16. The renderer object is resolved *once* and used
/// for everything, because the synchronizer must be given the same object the
/// samples go to — attaching the layer while enqueuing to its
/// `sampleBufferRenderer` leaves the samples on a timebase nothing drives.
final class DisplayLayerVideoSink: VideoSampleSink {

    let layer: AVSampleBufferDisplayLayer
    /// The object samples are enqueued to, and the one handed to the
    /// synchronizer.
    let renderer: AVQueuedSampleBufferRendering

    /// Resolved alongside `renderer`, because the flush API moved with it. A
    /// stored closure rather than a branch at every call site: the availability
    /// decision belongs to `init`, not to seek.
    private let flushHandler: (Bool) -> Void

    init(layer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer()) {
        self.layer = layer
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, visionOS 1.0, *) {
            let videoRenderer = layer.sampleBufferRenderer
            self.renderer = videoRenderer
            self.flushHandler = { removingDisplayedImage in
                videoRenderer.flush(removingDisplayedImage: removingDisplayedImage) { }
            }
        } else {
            self.renderer = layer
            self.flushHandler = { removingDisplayedImage in
                if removingDisplayedImage {
                    layer.flushAndRemoveImage()
                } else {
                    layer.flush()
                }
            }
        }
    }

    var isReadyForMoreSamples: Bool { renderer.isReadyForMoreMediaData }
    var queuedRenderer: AVQueuedSampleBufferRendering? { renderer }

    private var observations: [NSKeyValueObservation] = []

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)
    }

    func requestSamples(on queue: DispatchQueue, using block: @escaping () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingSamples() {
        renderer.stopRequestingMediaData()
    }

    func flush(removingDisplayedImage: Bool) {
        flushHandler(removingDisplayedImage)
    }

    /// Two signals, both KVO. `status == .failed` is the renderer giving up
    /// (its `error` says why — logged by the pipeline's host, not acted on
    /// differently here, because the remedy is the same). The layer's
    /// `requiresFlushToResumeDecoding` is the softer one: the decode session
    /// was lost (backgrounding, a display change) and the layer will not draw
    /// again until flushed — the classic "came back to a black player". Both
    /// observed on the LAYER, which reflects its renderer's state on every OS
    /// the package supports, so the availability split above stays in `init`.
    func observeFailure(on queue: DispatchQueue, handler: @escaping () -> Void) {
        stopObservingFailure()
        let statusObservation = layer.observe(\.status, options: [.new]) { layer, _ in
            guard layer.status == .failed else { return }
            queue.async(execute: handler)
        }
        let flushObservation = layer.observe(\.requiresFlushToResumeDecoding, options: [.new]) { layer, _ in
            guard layer.requiresFlushToResumeDecoding else { return }
            queue.async(execute: handler)
        }
        observations = [statusObservation, flushObservation]
    }

    func stopObservingFailure() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }
}

/// `AVSampleBufferAudioRenderer` behind `AudioSampleSink`.
final class AudioRendererSink: AudioSampleSink {

    let renderer: AVSampleBufferAudioRenderer

    init(renderer: AVSampleBufferAudioRenderer = AVSampleBufferAudioRenderer()) {
        self.renderer = renderer
    }

    var isReadyForMoreSamples: Bool { renderer.isReadyForMoreMediaData }
    var queuedRenderer: AVQueuedSampleBufferRendering? { renderer }

    private var statusObservation: NSKeyValueObservation?

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)
    }

    func requestSamples(on queue: DispatchQueue, using block: @escaping () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingSamples() {
        renderer.stopRequestingMediaData()
    }

    func flush() {
        renderer.flush()
    }

    /// The audio renderer's only failure signal is `status == .failed` (a
    /// route it could not follow, a format it stopped accepting); `error`
    /// carries the reason. Same remedy as video: flush and re-feed.
    func observeFailure(on queue: DispatchQueue, handler: @escaping () -> Void) {
        stopObservingFailure()
        statusObservation = renderer.observe(\.status, options: [.new]) { renderer, _ in
            guard renderer.status == .failed else { return }
            queue.async(execute: handler)
        }
    }

    func stopObservingFailure() {
        statusObservation?.invalidate()
        statusObservation = nil
    }
}

/// `AVSampleBufferRenderSynchronizer` behind `RenderTimeline`.
final class SynchronizerTimeline: RenderTimeline {

    let synchronizer: AVSampleBufferRenderSynchronizer

    init(synchronizer: AVSampleBufferRenderSynchronizer = AVSampleBufferRenderSynchronizer()) {
        self.synchronizer = synchronizer
    }

    func attach(_ sink: SampleBufferSink) {
        guard let renderer = sink.queuedRenderer else { return }
        synchronizer.addRenderer(renderer)
    }

    func detach(_ sink: SampleBufferSink) {
        guard let renderer = sink.queuedRenderer else { return }
        synchronizer.removeRenderer(renderer, at: synchronizer.currentTime())
    }

    var currentTime: CMTime { synchronizer.currentTime() }
    var rate: Float { synchronizer.rate }

    func setRate(_ rate: Float, time: CMTime) {
        synchronizer.setRate(rate, time: time)
    }

    func observeBoundary(_ time: CMTime, on queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> Any? {
        synchronizer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: time)], queue: queue, using: handler
        )
    }

    func cancelBoundaryObserver(_ token: Any) {
        synchronizer.removeTimeObserver(token)
    }
}
