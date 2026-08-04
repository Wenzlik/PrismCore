import Foundation

/// Presentation timestamps for the software path's audio buffers, counted in
/// output samples.
///
/// The naive answer — stamp each `CMSampleBuffer` with the source packet's own
/// PTS — produces a continuous crackle out of `AVSampleBufferAudioRenderer`.
/// Container timestamps are quantized (Matroska's default timebase is 1 ms),
/// and a decoded frame's length is almost never an integer number of those
/// ticks: 1024 AAC samples are 23.2199 ms at 44.1 kHz, 1536 AC-3 samples are
/// 34.83 ms. So consecutive buffers arrive with a sub-millisecond gap or
/// overlap at *every* boundary, the renderer reconciles a discontinuity at
/// each one, and you hear ~30 clicks a second.
///
/// The fix is to stop trusting per-buffer timestamps and keep a running sample
/// count instead: buffer N+1 starts exactly where buffer N ended, so the
/// renderer sees one continuous stream. The count is *anchored* on the source
/// (the first buffer's own PTS, not zero) so audio shares the video's timeline
/// — a pipeline that starts mid-file must not put audio a whole start-offset
/// away from video.
///
/// Two rules keep the running count honest:
///
/// - **Re-anchor across real discontinuities.** When a buffer's source PTS
///   lands further than `tolerance` from where the count predicted it (a seek,
///   an edit, a genuinely missing chunk of audio), the count jumps to it.
///   Anything smaller is container quantization and is deliberately absorbed.
///   Papering over a real gap instead would make every later buffer late by the
///   gap's length — drift you can hear against the picture.
/// - **No phantom samples.** The count advances only when a buffer was really
///   handed to the renderer (`commit()`), so a buffer dropped under
///   back-pressure doesn't push the timeline forward past audio nobody heard.
///
/// Pure by construction — no libav*, no CoreMedia — because this arithmetic is
/// where the bugs are audible and the tests must be able to reach it.
struct AudioClock: Equatable {

    /// Output sample rate; one tick of this clock is one sample.
    let sampleRate: Int32
    /// How far a source PTS may sit from the predicted position before it
    /// counts as a real discontinuity, in samples. 100 ms: far larger than any
    /// container's quantization, far smaller than a seek or a missing block.
    let tolerance: Int64

    /// Sample index the next emitted buffer will be stamped with.
    private(set) var nextSample: Int64 = 0
    /// Whether any source timestamp has been seen since the last `reset()`.
    private(set) var isAnchored = false

    /// Where the next buffer's source PTS is expected, if the stream is
    /// continuous. `nil` disables the gap check for one buffer (no timestamp
    /// to compare against, or a `reset()` in between).
    private var expectedSourceSample: Int64?

    /// Staged by `timestamp(forSourceSample:sampleCount:)`, applied by
    /// `commit()`. Held rather than applied immediately so a buffer that never
    /// reaches the renderer leaves no trace.
    private struct Staged: Equatable {
        let advance: Int64
        let expectedSourceSample: Int64?
    }
    private var pending: Staged?

    init(sampleRate: Int32, tolerance: Int64? = nil) {
        let rate = max(1, sampleRate)
        self.sampleRate = rate
        self.tolerance = tolerance ?? Int64(rate) / 10
    }

    /// The PTS (in samples) for a buffer of `sampleCount` samples whose source
    /// timestamp is `sourceSample` — also in output samples, so the caller does
    /// the rescale from the stream's time base.
    ///
    /// Call once per buffer, then `commit()` if it was enqueued.
    mutating func timestamp(forSourceSample sourceSample: Int64?, sampleCount: Int) -> Int64 {
        let count = Int64(max(0, sampleCount))

        guard let sourceSample else {
            // No timestamp: the running count is all we have. Clear the
            // prediction so the next timestamped buffer isn't judged against a
            // stale one and mistaken for a gap.
            pending = Staged(advance: count, expectedSourceSample: nil)
            if !isAnchored {
                // Nothing to anchor on yet; start at zero and let the first
                // timestamped buffer re-anchor.
                isAnchored = true
            }
            return nextSample
        }

        let isDiscontinuous = expectedSourceSample.map { abs(sourceSample - $0) > tolerance } ?? true
        if !isAnchored || isDiscontinuous {
            nextSample = sourceSample
            isAnchored = true
        }
        pending = Staged(advance: count, expectedSourceSample: sourceSample + count)
        return nextSample
    }

    /// Accept the last `timestamp(...)`: the buffer reached the renderer, so
    /// its samples are now part of the timeline.
    mutating func commit() {
        guard let pending else { return }
        nextSample += pending.advance
        expectedSourceSample = pending.expectedSourceSample
        self.pending = nil
    }

    /// Drop the anchor. Called on flush (seek, stop, track change): the next
    /// buffer re-anchors on its own source PTS instead of continuing a count
    /// that belongs to the timeline we just left.
    mutating func reset() {
        nextSample = 0
        isAnchored = false
        expectedSourceSample = nil
        pending = nil
    }
}
