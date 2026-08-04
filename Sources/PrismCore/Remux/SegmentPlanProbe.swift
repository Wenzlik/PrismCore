import Foundation
import Libavformat
import Libavutil

/// Opens a source just long enough to build its `SegmentPlan` — the planning
/// half of a demand-driven session's startup (the producer opens its own
/// context; a plan probe must not share or move it).
enum SegmentPlanProbe {

    static func plan(
        url: URL,
        httpHeaders: [String: String] = [:],
        targetSeconds: Int
    ) -> SegmentPlan? {
        var input: UnsafeMutablePointer<AVFormatContext>?

        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        if !httpHeaders.isEmpty {
            let blob = httpHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
            av_dict_set(&options, "headers", blob, 0)
        }

        let spec = url.isFileURL ? url.path : url.absoluteString
        guard avformat_open_input(&input, spec, nil, &options) >= 0, let input else { return nil }
        defer {
            var closing: UnsafeMutablePointer<AVFormatContext>? = input
            avformat_close_input(&closing)
        }
        guard avformat_find_stream_info(input, nil) >= 0 else { return nil }

        let videoIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0 else { return nil }

        return SegmentPlan.build(
            input: input,
            videoStreamIndex: videoIndex,
            targetSeconds: targetSeconds
        )
    }
}
