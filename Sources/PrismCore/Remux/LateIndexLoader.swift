import Foundation
import Libavformat
import Libavutil

/// A second, patient index load for a session that went sequential only
/// because its first one ran out of time.
///
/// `SegmentPlan.indexLoadBudget` (3 s) keeps a slow tail from holding startup
/// hostage, and the price is paid by exactly the sources that have an index:
/// behind a range proxy that fetches each window whole before writing a byte,
/// one tail request alone was measured at 10.5 s in the field, so a Matroska
/// with its Cues at the end plays its whole first play without a plan. The
/// keyframe harvest fixes that for the NEXT play, but only at EOF. This
/// reads the same Cues again, after startup, with time to spare, and stores
/// them the moment they are in — so the next session (or a successor the host
/// makes on `.segmentPlanAvailable`) plans from the cache.
///
/// Its own open, its own guard, its own thread: the producer's context is
/// mid-stream and must not be moved, and the read path only sees a callback
/// installed before `avformat_open_input` (issue #39) — so the guard is in the
/// context before the open, armed for the whole job, and `cancel()` reaches
/// it from any thread. A `ProducerThread`, not the cooperative pool: the job
/// blocks in reads for up to `budget` (#44).
///
/// Never stored unless the open proves it read the **same version** as the
/// producer's: the two identities must be equal (`KeyframeIndexCache.Identity`
/// — URL, size, duration, strong `ETag` and the URL that served it). A file
/// replaced between the two opens yields different digests and nothing is
/// written. And the map must pass what a map stored by the producer passes:
/// `keyframePlan`'s witnesses and `indexCoversThroughEnd` — a scan the budget
/// cut short leaves a head prefix that the witnesses alone would accept.
///
/// What it costs the producer is kept to what it must: it starts only after
/// the first video segment (startup is untouched), its reader takes the
/// origin only while nothing else is in flight (`yieldsToPlayback`), it skips
/// the analysis reads of `avformat_find_stream_info`, and it nudges only a
/// container whose framing names its index — anywhere else the nudge is a
/// scan of the whole file.
final class LateIndexLoader: @unchecked Sendable {

    /// The whole job's wall-clock bound — open, header and the index nudge.
    /// Twenty times the startup budget: nobody waits on this, so it only has
    /// to be short enough that an index-less source (whose nudge is a linear
    /// scan) does not keep a reader going for the length of the film.
    static let budget: Duration = .seconds(60)

    struct Target {
        let sourceURL: URL
        let httpHeaders: [String: String]
        let videoStreamIndex: Int32
        let timeBase: AVRational
        let segmentSeconds: Int
        let firstSegmentSeconds: Int
        /// `Identity.key` of the producer's open — the version the map must
        /// come from.
        let identity: String
    }

    private let target: Target
    private let cache: KeyframeIndexCache
    private let budget: Duration
    private let interruptGuard = ReadInterruptGuard()
    private let onStored: @Sendable (Int) -> Void
    private(set) var thread: ProducerThread?

    /// - Parameter onStored: called on the loader's thread with the planned
    ///   segment count, once the map is in the cache — and only then.
    init(target: Target, cache: KeyframeIndexCache, budget: Duration = LateIndexLoader.budget,
         onStored: @escaping @Sendable (Int) -> Void) {
        self.target = target
        self.cache = cache
        self.budget = budget
        self.onStored = onStored
    }

    func start() {
        thread = ProducerThread(name: "cz.zmrhal.prismcore.late-index") { [self] in
            guard let (keyframes, segments) = load(), !interruptGuard.shouldInterrupt else { return }
            // Announce only what landed: a write the cache swallowed would
            // send the host to a successor that misses and stays sequential.
            guard cache.store(.init(
                identity: target.identity,
                timeBaseNum: target.timeBase.num,
                timeBaseDen: target.timeBase.den,
                keyframePTS: keyframes
            )) else { return }
            onStored(segments)
        }
    }

    /// Aborts the open or the nudge wherever it is. Safe from any thread,
    /// before or after `start()`.
    func cancel() { interruptGuard.cancel() }

    /// The sorted keyframe map and the plan's segment count, or `nil` for
    /// anything short of a whole, trusted index of the producer's version.
    private func load() -> ([Int64], Int)? {
        var options = SourceOpenTuning.makeOptions(httpHeaders: target.httpHeaders)
        defer { av_dict_free(&options) }
        var context = interruptGuard.makeContext()
        guard let allocated = context else { return nil }
        // Coordinated HTTP only: it is the one remote transport that yields a
        // version proof, so it is the only one the remuxer starts this for.
        do {
            try interruptGuard.installHTTPInput(
                on: allocated, url: target.sourceURL, headers: target.httpHeaders,
                yieldsToPlayback: true
            )
        } catch {
            avformat_free_context(allocated)
            return nil
        }
        interruptGuard.arm(budget: budget)
        defer {
            avformat_close_input(&context)
            interruptGuard.disarm()
        }
        // No `avformat_find_stream_info`: this context never feeds a muxer
        // (the reason the producer's must have it), and its sampling is up to
        // 4 MB of reads competing with the producer for the origin. The
        // header gives streams, time base and the container's duration; a
        // demuxer that only learns those by sampling yields a different
        // identity or time base below, and the map is simply not stored.
        guard avformat_open_input(&context, target.sourceURL.absoluteString, nil, &options) >= 0,
              let input = context,
              let identity = KeyframeIndexCache.Identity(
                  opened: input, sourceURL: target.sourceURL, interruptGuard: interruptGuard
              ), identity.key == target.identity,
              target.videoStreamIndex < input.pointee.nb_streams,
              let stream = input.pointee.streams[Int(target.videoStreamIndex)],
              stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
              stream.pointee.time_base.num == target.timeBase.num,
              stream.pointee.time_base.den == target.timeBase.den,
              input.pointee.duration > 0
        else { return nil }

        // Only where the container's framing names its index (a Matroska
        // SeekHead pointing at the Cues): there the nudge is a jump and a
        // read. Anywhere else it degenerates into a linear scan of the whole
        // file — a second full read beside the producer's, through the same
        // origin, for a map the harvest collects for free. The walk reads
        // header bytes this open already fetched. `unknown` is not evidence
        // of no index (AGENTS.md), and nothing here claims it is: it only
        // decides that a scan is not worth its bandwidth.
        let layout = SourceStructureReader.read(
            input: input, formatName: String(cString: input.pointee.iformat.pointee.name),
            videoStreamIndex: nil, export: .layout, interruptGuard: nil
        )
        guard layout.indexLocation == .head || layout.indexLocation == .tail else { return nil }

        let durationSeconds = Double(input.pointee.duration) / Double(AV_TIME_BASE)
        let tick = av_q2d(stream.pointee.time_base)
        _ = av_seek_frame(
            input, target.videoStreamIndex,
            SegmentPlan.indexLoadTarget(of: stream, durationSeconds: durationSeconds),
            AVSEEK_FLAG_BACKWARD
        )
        // A budget that ran out mid-scan leaves a prefix; the clock, not the
        // seek's return code, says so (an aborted read can return cleanly).
        guard !interruptGuard.shouldInterrupt else { return nil }
        let keyframes = SegmentPlan.indexedKeyframes(of: stream).sorted()
        guard let last = keyframes.last,
              SegmentPlan.indexCoversThroughEnd(
                  lastKeyframePTS: last, tickSeconds: tick,
                  durationSeconds: durationSeconds, targetSeconds: target.segmentSeconds
              ),
              let entries = SegmentPlan.keyframePlan(
                  keyframes: keyframes, durationSeconds: durationSeconds, tickSeconds: tick,
                  targetSeconds: target.segmentSeconds, firstSegmentSeconds: target.firstSegmentSeconds
              )
        else { return nil }
        return (keyframes, entries.count)
    }
}
