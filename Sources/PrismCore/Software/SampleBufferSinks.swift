import Foundation
import AVFoundation
import CoreMedia
import os

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
    func requestSamples(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
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
    func observeFailure(on queue: DispatchQueue, handler: @escaping @Sendable () -> Void)
    func stopObservingFailure()
}

extension SampleBufferSink {
    var queuedRenderer: AVQueuedSampleBufferRendering? { nil }
    func observeFailure(on queue: DispatchQueue, handler: @escaping @Sendable () -> Void) { }
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
///
/// The SDK marks `AVSampleBufferDisplayLayer` main-actor isolated (it is a
/// `CALayer`), so `init` — the one place that reads `sampleBufferRenderer` — is
/// `@MainActor`. Everything after it runs on the pipeline's queues and touches
/// only the renderer, which the SDK documents as safe to feed from a
/// background thread, and on iOS 16 the layer's non-isolated
/// `AVQueuedSampleBufferRendering` face, which is what that OS had instead.
final class DisplayLayerVideoSink: VideoSampleSink {

    let layer: AVSampleBufferDisplayLayer
    /// The object samples are enqueued to, and the one handed to the
    /// synchronizer.
    let renderer: AVQueuedSampleBufferRendering

    @MainActor
    init(layer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer()) {
        self.layer = layer
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, visionOS 1.0, *) {
            self.renderer = layer.sampleBufferRenderer
        } else {
            self.renderer = layer
        }
    }

    var isReadyForMoreSamples: Bool { renderer.isReadyForMoreMediaData }
    var queuedRenderer: AVQueuedSampleBufferRendering? { renderer }

    /// What `stopObservingFailure` has to undo: a KVO observation and/or a
    /// notification token, plus the switch that silences deliveries already
    /// queued.
    private var failureObservers: [AnyObject] = []
    private var failureDeliveryActive: OSAllocatedUnfairLock<Bool>?

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)
    }

    func requestSamples(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func stopRequestingSamples() {
        renderer.stopRequestingMediaData()
    }

    func flush(removingDisplayedImage: Bool) {
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, visionOS 1.0, *),
           let videoRenderer = renderer as? AVSampleBufferVideoRenderer {
            videoRenderer.flush(removingDisplayedImage: removingDisplayedImage, completionHandler: nil)
            return
        }
        // iOS 16: the queued samples go synchronously, through the layer's
        // non-isolated rendering face, so nothing enqueued after this call is
        // lost. Removing the picture is a main-actor call on the layer; only
        // teardown asks for it and the pipeline is single-use afterwards, so
        // landing it a main-queue turn later cannot wipe a later frame.
        renderer.flush()
        if removingDisplayedImage {
            Task { @MainActor [layer = self.layer] in layer.flushAndRemoveImage() }
        }
    }

    /// Two signals. `status == .failed` is the renderer giving up (its `error`
    /// says why — logged by the pipeline's host, not acted on differently
    /// here, because the remedy is the same). `requiresFlushToResumeDecoding`
    /// is the softer one: the decode session was lost (backgrounding, a
    /// display change) and nothing draws again until flushed — the classic
    /// "came back to a black player".
    ///
    /// iOS 17+: `status` by typed KVO on the renderer, the flag by the
    /// renderer's notification (the SDK documents it as not KVO-observable).
    /// iOS 16: the layer's notification, read back on the main actor because
    /// the layer's properties are isolated there; the SDK flips `status` to
    /// failed together with the flag, so the lost-session case is covered.
    ///
    /// Every delivery hops to `queue` and re-checks the switch there, and
    /// `stopObservingFailure` flips it — the pipeline calls both on `queue`, so
    /// once it returns no handler runs, not even one a notification already
    /// queued. Without that a teardown racing a background-time status change
    /// fires the handler for a pipeline that is already gone.
    func observeFailure(on queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        stopObservingFailure()
        let active = OSAllocatedUnfairLock(initialState: true)
        let fire: @Sendable () -> Void = {
            queue.async { if active.withLock({ $0 }) { handler() } }
        }
        failureDeliveryActive = active
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, visionOS 1.0, *),
           let videoRenderer = renderer as? AVSampleBufferVideoRenderer {
            let status = videoRenderer.observe(\.status, options: [.new]) { renderer, _ in
                guard renderer.status == .failed else { return }
                fire()
            }
            let flush = NotificationCenter.default.addObserver(
                forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                object: videoRenderer, queue: nil
            ) { notification in
                guard (notification.object as? AVSampleBufferVideoRenderer)?.requiresFlushToResumeDecoding == true
                else { return }
                fire()
            }
            failureObservers = [status, flush]
        } else {
            let layer = self.layer
            let flush = NotificationCenter.default.addObserver(
                forName: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange,
                object: layer, queue: nil
            ) { _ in
                Task { @MainActor in
                    guard layer.requiresFlushToResumeDecoding || layer.status == .failed else { return }
                    fire()
                }
            }
            failureObservers = [flush]
        }
    }

    func stopObservingFailure() {
        failureDeliveryActive?.withLock { $0 = false }
        failureDeliveryActive = nil
        for observer in failureObservers {
            if let observation = observer as? NSKeyValueObservation {
                observation.invalidate()
            } else {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        failureObservers.removeAll()
    }

    deinit { stopObservingFailure() }
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

    func requestSamples(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
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
    func observeFailure(on queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
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
