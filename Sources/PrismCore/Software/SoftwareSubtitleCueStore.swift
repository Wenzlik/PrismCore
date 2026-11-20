import Foundation
import Libavcodec
import Libavutil

/// Keeps the demuxer's text look-ahead separate from the host's presentation
/// clock. All tracks are cheap to convert, and retaining them lets a paused
/// language switch show the current cue without rewinding either A/V decoder.
// Safety: cues and byteCount are read and written only under `lock`; the limits are immutable.
final class SoftwareSubtitleCueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [TimedTextCue] = []
    private var byteCount = 0
    private let maximumCues: Int
    private let maximumBytes: Int

    init(maximumCues: Int = 1_024, maximumBytes: Int = 1 << 20) {
        self.maximumCues = maximumCues
        self.maximumBytes = maximumBytes
    }

    func ingest(
        _ packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational,
        kind: TextSubtitleConverter.Kind, currentTime: Double,
        playResolution: TextSubtitleConverter.PlayResolution? = nil,
        assHeader: ASSScriptHeader? = nil,
        movText: TextSubtitleConverter.MovTextDescription? = nil
    ) {
        // Reject oversized payloads before copying or parsing: subtitle data
        // must not bypass the decoded video pipeline's memory discipline.
        guard packet.pointee.pts != swift_AV_NOPTS_VALUE(),
              packet.pointee.duration > 0, packet.pointee.size > 0,
              packet.pointee.size <= maximumBytes, let bytes = packet.pointee.data
        else { return }
        let start = Double(packet.pointee.pts) * av_q2d(timeBase)
        let end = start + Double(packet.pointee.duration) * av_q2d(timeBase)
        guard start.isFinite, end.isFinite, end > start,
              !currentTime.isFinite || end > currentTime,
              let converted = TextSubtitleConverter.convert(
                Data(bytes: bytes, count: Int(packet.pointee.size)), kind: kind, playResolution: playResolution,
                assHeader: assHeader, movText: movText
              ) else { return }
        // A WebVTT track's own settings outrank anything read off the payload
        // — the same precedence the remux renditions use.
        let sourcePlacement = kind == .webvtt
            ? SubtitleRenditionSet.webVTTSettings(on: packet)
                .flatMap(TextCuePlacement.sanitizedWebVTTSettings)
                .flatMap(TextCuePlacement.init(webVTTSettings:))
            : nil
        let placement = sourcePlacement ?? converted.placement
        var styled = converted.styled
        if sourcePlacement != nil { styled?.placement = sourcePlacement }
        insert(TimedTextCue(streamIndex: packet.pointee.stream_index,
                            start: start, end: end, text: converted.text, placement: placement, styled: styled),
               currentTime: currentTime)
    }

    func insert(_ cue: TimedTextCue, currentTime: Double) {
        lock.withLock {
            prune(at: currentTime)
            guard !cues.contains(cue) else { return } // Audio switches re-read packets.
            let size = Self.bytes(cue)
            guard cues.count < maximumCues, size <= maximumBytes - byteCount else { return }
            cues.append(cue)
            byteCount += size
        }
    }

    func active(streamIndex: Int, at time: Double) -> [TimedTextCue] {
        lock.withLock {
            guard time.isFinite else { return [] }
            // During a backward seek the host still sees the old clock while
            // the feed queue repopulates cues. Only insertion may prune them.
            return cues.filter { Int($0.streamIndex) == streamIndex && $0.start <= time && time < $0.end }
                .sorted { $0.start < $1.start }
        }
    }

    func reset() {
        lock.withLock {
            cues.removeAll()
            byteCount = 0
        }
    }

    /// The styled runs repeat the words, so they count against the bound too.
    private static func bytes(_ cue: TimedTextCue) -> Int {
        cue.text.utf8.count + (cue.styled?.plainText.utf8.count ?? 0)
    }

    private func prune(at time: Double) {
        guard time.isFinite else { return }
        cues.removeAll { cue in
            guard cue.end <= time else { return false }
            byteCount -= Self.bytes(cue)
            return true
        }
    }
}
