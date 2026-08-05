import Foundation
import Libavformat
import Libavutil

/// The upfront map of a VOD source's segments — the piece that turns "play
/// from the head" into "seek anywhere" (phase 5).
///
/// v0 grew an EVENT playlist as it produced, so AVPlayer only knew about
/// segments that already existed and a seek past the produced window had
/// nowhere to go. A plan enumerates EVERY segment before playback: the
/// playlist can be published complete (real VOD, ENDLIST and all), AVPlayer
/// seeks by simply fetching the segment at the target, and the producer's job
/// becomes "make the requested segment exist" instead of "run to EOF".
///
/// Boundaries follow the same shape v0 cut live: segment N ends at the first
/// video keyframe at-or-after `(N+1) × targetSeconds`, so every segment opens
/// decodable on its own. The keyframe positions come from the demuxer's index
/// (Matroska Cues / MP4 `stss`+`stts`, loaded by a bounded seek); an index is
/// only trusted past two witnesses, because index quality varies wildly:
///
/// - **gap**: the largest distance between consecutive keyframes must stay
///   under a cap. A clustered MPEG-TS index can gap by thousands of seconds,
///   and trusting it would plan a single monstrous segment.
/// - **coverage**: the indexed keyframes must span at least one target
///   duration. A remote MKV whose Cues tail read failed leaves only the
///   open-time keyframes, bunched at the head — tiny gaps (witness 1 passes)
///   but nothing reaches even the first boundary.
///
/// An untrusted index degrades to a **uniform plan**: fixed-duration entries
/// whose positions are timestamps, not keyframes. The producer then seeks by
/// time and cuts at whatever keyframe the demuxer lands on — less precise,
/// never wrong (a landed keyframe is still a keyframe).
struct SegmentPlan: Equatable {

    struct Entry: Equatable {
        /// Segment start on the video stream's time base.
        let startPTS: Int64
        /// Planned duration in seconds (the playlist's EXTINF).
        let duration: Double
    }

    enum Basis: Equatable {
        /// Boundaries sit on indexed keyframes — seeks land exactly.
        case keyframeIndex
        /// Uniform stride fallback — boundaries are time targets.
        case uniform
    }

    let entries: [Entry]
    let basis: Basis
    /// The video stream's time base the entries' PTS live on.
    let timeBaseNum: Int32
    let timeBaseDen: Int32

    /// Largest tolerated keyframe gap before the index is declared junk.
    /// Generous: open-GOP 10 s intervals are real; 60 s is not a VOD cadence.
    static let maxTrustedGapSeconds = 60.0

    // MARK: - Building

    /// Build a plan from an OPENED input whose stream info has been read.
    /// `duration` comes from the container; sources that don't know theirs
    /// (live) have no plan — the caller stays on the v0 event path.
    static func build(
        input: UnsafeMutablePointer<AVFormatContext>,
        videoStreamIndex: Int32,
        targetSeconds: Int
    ) -> SegmentPlan? {
        let stream = input.pointee.streams[Int(videoStreamIndex)]!
        let timeBase = stream.pointee.time_base
        let tick = av_q2d(timeBase)

        // Container duration (AV_TIME_BASE) → seconds. No duration, no plan.
        let rawDuration = input.pointee.duration
        guard rawDuration > 0 else { return nil }
        let durationSeconds = Double(rawDuration) / Double(AV_TIME_BASE)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }

        // Nudge the demuxer to load its index (Matroska Cues arrive with a
        // bounded seek; MP4 has stss in the moov already). Seek back to the
        // head afterwards — planning must not move the read position the
        // producer will start from.
        _ = av_seek_frame(input, videoStreamIndex, stream.pointee.duration > 0 ? stream.pointee.duration : Int64(durationSeconds / tick), AVSEEK_FLAG_BACKWARD)
        _ = av_seek_frame(input, videoStreamIndex, 0, AVSEEK_FLAG_BACKWARD)

        var keyframes: [Int64] = []
        let count = avformat_index_get_entries_count(stream)
        keyframes.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(stream, i) else { continue }
            if entry.pointee.flags & Int32(AVINDEX_KEYFRAME) != 0 {
                keyframes.append(entry.pointee.timestamp)
            }
        }

        if let planned = keyframePlan(
            keyframes: keyframes,
            durationSeconds: durationSeconds,
            tickSeconds: tick,
            targetSeconds: targetSeconds
        ) {
            return SegmentPlan(
                entries: planned,
                basis: .keyframeIndex,
                timeBaseNum: timeBase.num,
                timeBaseDen: timeBase.den
            )
        }

        return SegmentPlan(
            entries: uniformPlan(durationSeconds: durationSeconds, tickSeconds: tick, targetSeconds: targetSeconds),
            basis: .uniform,
            timeBaseNum: timeBase.num,
            timeBaseDen: timeBase.den
        )
    }

    /// The keyframe-aligned plan, or nil when the index fails its witnesses.
    /// Pure — unit-tested against synthetic keyframe sets.
    static func keyframePlan(
        keyframes: [Int64],
        durationSeconds: Double,
        tickSeconds: Double,
        targetSeconds: Int
    ) -> [Entry]? {
        guard keyframes.count >= 2 else { return nil }
        let sorted = keyframes.sorted()

        // Witness 1: no gap over the cap.
        var previous = sorted[0]
        for keyframe in sorted.dropFirst() {
            if Double(keyframe - previous) * tickSeconds > maxTrustedGapSeconds { return nil }
            previous = keyframe
        }
        // Witness 2: coverage spans at least one target duration.
        let span = Double(sorted.last! - sorted.first!) * tickSeconds
        guard span >= Double(targetSeconds) else { return nil }

        // Segment N ends at the first keyframe at-or-after (N+1)×target.
        var entries: [Entry] = []
        var startPTS = sorted.first!
        let step = Double(targetSeconds) / tickSeconds
        var boundary = Double(startPTS) + step
        for keyframe in sorted.dropFirst() where Double(keyframe) >= boundary {
            entries.append(Entry(
                startPTS: startPTS,
                duration: Double(keyframe - startPTS) * tickSeconds
            ))
            startPTS = keyframe
            boundary = Double(keyframe) + step
        }
        // The tail: from the last boundary keyframe to the container's end.
        let endPTS = Int64(durationSeconds / tickSeconds)
        let tail = Double(max(endPTS - startPTS, 0)) * tickSeconds
        if tail > 0.01 {
            entries.append(Entry(startPTS: startPTS, duration: tail))
        }
        return entries.isEmpty ? nil : entries
    }

    /// Fixed-stride fallback. Anchored at 0 — a late-starting title is rare
    /// enough that v1 doesn't special-case it (anchoring segment 0 at the
    /// real content start is noted for the hardening pass).
    static func uniformPlan(
        durationSeconds: Double,
        tickSeconds: Double,
        targetSeconds: Int
    ) -> [Entry] {
        var entries: [Entry] = []
        var start = 0.0
        while start < durationSeconds {
            let length = min(Double(targetSeconds), durationSeconds - start)
            entries.append(Entry(
                startPTS: Int64(start / tickSeconds),
                duration: length
            ))
            start += Double(targetSeconds)
        }
        return entries
    }

    // MARK: - Lookup

    /// The segment index whose span contains `pts` (video time base).
    func segmentIndex(containing pts: Int64) -> Int {
        var candidate = 0
        for (index, entry) in entries.enumerated() where entry.startPTS <= pts {
            candidate = index
        }
        return candidate
    }
}
