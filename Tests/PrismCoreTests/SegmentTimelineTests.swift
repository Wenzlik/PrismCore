import Testing
import Foundation
import Libavcodec
@testable import PrismCore

/// `segmentTargetDuration` and its read-back, `segmentTimeline`. The fixture
/// (`h264_aac_30s.mkv`) cuts a keyframe every 2 s and carries Cues, so it plans
/// on its index and every boundary lands exactly where the target puts it.
@Suite("Segment target duration and timeline", .serialized)
struct SegmentTimelineTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func variantPlaylist(_ master: URL) async throws -> String {
        let (data, _) = try await URLSession.uncached.data(from: master.deletingLastPathComponent()
            .appendingPathComponent("index.m3u8"))
        return String(decoding: data, as: UTF8.self)
    }

    @Test("The target is clamped to 1...10 and reads back as the value in force")
    func clamping() async throws {
        let url = try fixture("h264_aac_30s.mkv")
        for (asked, inForce) in [(nil, 6), (0, 1), (99, 10), (4, 4)] as [(Int?, Int)] {
            let session = try asked.map { try PrismCoreSession(url: url, segmentTargetDuration: $0) }
                ?? PrismCoreSession(url: url)
            #expect(await session.options.segmentTargetDuration == inForce)
        }
    }

    @Test("A 4 s target plans 4 s segments, and the timeline matches the playlist")
    func customTargetPlansAndReadsBack() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"), segmentTargetDuration: 4)
        defer { Task { await session.stop() } }
        #expect(session.segmentTimeline == nil, "nothing is planned before start()")
        let master = try await session.start()
        let timeline = try #require(session.segmentTimeline)

        // The short first segment `start()` waits for, then the asked-for stride.
        #expect(abs(timeline.segments[0].duration - 2) < 0.01)
        #expect(timeline.segments.dropFirst().dropLast().allSatisfy { abs($0.duration - 4) < 0.01 })
        // The ceiling of the longest, as RFC 8216 wants — the fixture's tail
        // runs a few ms over 4 s, which is a 5 on the wire, not a 4.
        let longest = timeline.segments.map(\.duration).max() ?? 0
        #expect(timeline.targetDuration == Int(longest.rounded(.up)))
        // Contiguous on the playlist timeline, and the whole title.
        for (previous, next) in zip(timeline.segments, timeline.segments.dropFirst()) {
            #expect(abs(previous.start + previous.duration - next.start) < 1e-9)
        }
        let end = timeline.segments.last.map { $0.start + $0.duration } ?? 0
        #expect(abs(end - 30) < 0.5)

        // The served playlist says the same thing, entry for entry.
        let playlist = try await variantPlaylist(master)
        #expect(playlist.contains("#EXT-X-TARGETDURATION:\(timeline.targetDuration)\n"))
        let extinf = playlist.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).dropLast()) }
        #expect(extinf.count == timeline.segments.count)
        for (listed, planned) in zip(extinf, timeline.segments) {
            #expect(abs(listed - planned.duration) < 1e-4)
        }
    }

    @Test("The default stays 6 s")
    func defaultTarget() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        defer { Task { await session.stop() } }
        let master = try await session.start()
        let timeline = try #require(session.segmentTimeline)
        #expect(timeline.segments.dropFirst().dropLast().allSatisfy { abs($0.duration - 6) < 0.01 })
        #expect(try await variantPlaylist(master).contains("#EXT-X-TARGETDURATION:\(timeline.targetDuration)\n"))
    }
}

@Suite("Coded field order")
struct CodedFieldOrderTests {

    @Test("Each AVFieldOrder maps to ffprobe's spelling")
    func mapping() {
        let cases: [(AVFieldOrder, VideoTrackInfo.CodedFieldOrder, String)] = [
            (AV_FIELD_PROGRESSIVE, .progressive, "progressive"),
            (AV_FIELD_TT, .tt, "tt"),
            (AV_FIELD_BB, .bb, "bb"),
            (AV_FIELD_TB, .tb, "tb"),
            (AV_FIELD_BT, .bt, "bt"),
            (AV_FIELD_UNKNOWN, .unknown, "unknown"),
        ]
        for (order, expected, spelling) in cases {
            #expect(VideoTrackInfo.CodedFieldOrder(order) == expected)
            #expect(expected.rawValue == spelling)
        }
    }

    @Test("The probe reports the declared order beside the verified one")
    func probeReportsTheDeclaration() throws {
        func probe(_ name: String) throws -> VideoTrackInfo {
            let url = try #require(
                Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
                    ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            )
            return try #require(try SourceProbe.probe(url: url).video)
        }
        // Encoded interlaced, flagged `tb` (top coded first, bottom shown first).
        let interlaced = try probe("h264_interlaced.mkv")
        #expect(interlaced.codedFieldOrder == .tb)
        #expect(interlaced.fieldOrder == .topFieldFirst)
        #expect(try probe("h264_aac.mkv").codedFieldOrder == .progressive)
    }
}
