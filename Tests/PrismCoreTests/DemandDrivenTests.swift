import Testing
import Foundation
import AVFoundation
@testable import PrismCore

/// Phase 5 end to end: a plannable VOD source gets its COMPLETE playlist
/// upfront, and fetching a segment the producer hasn't reached yet re-anchors
/// it there instead of waiting for sequential production to arrive.
///
/// The fixture (`h264_aac_30s.mkv`) is synthetic — 30 s of testsrc2 + sine
/// with a fixed 2 s keyframe cadence (`g=48` at 24 fps), so the Matroska Cues
/// pass both plan witnesses and the planned boundaries sit on real keyframes.
@Suite("Demand-driven production", .serialized)
struct DemandDrivenTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func fetch(_ url: URL) async throws -> (data: Data, status: Int) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The variant playlist behind whatever `start()` returned (master or not).
    private func variantURL(playlist: URL) async throws -> URL {
        let (data, _) = try await fetch(playlist)
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("#EXT-X-STREAM-INF") else { return playlist }
        let variant = try #require(PrismCoreSession.playlistURIs(inMaster: text).last)
        return playlist.deletingLastPathComponent().appendingPathComponent(variant)
    }

    // MARK: - Coordinator unit behaviour

    @Test("Requests inside the forward-wait window do not re-anchor; outside, last one wins")
    func coordinatorWindow() {
        let coordinator = DemandCoordinator()
        coordinator.publish(plan: SegmentPlan(
            entries: (0..<10).map { .init(startPTS: Int64($0) * 6000, duration: 6.0) },
            basis: .keyframeIndex,
            timeBaseNum: 1,
            timeBaseDen: 1000
        ))
        coordinator.setProducing(index: 2)

        // Within [2, 2+window]: the producer gets there on its own.
        coordinator.requestProduction(of: 3)
        #expect(coordinator.takeAnchorRequest() == nil)

        // Beyond it: a real seek.
        coordinator.requestProduction(of: 8)
        coordinator.requestProduction(of: 5)   // playhead moved again — last wins
        #expect(coordinator.takeAnchorRequest() == 5)
        #expect(coordinator.takeAnchorRequest() == nil)   // consumed

        // Backwards is always a re-anchor.
        coordinator.requestProduction(of: 0)
        #expect(coordinator.takeAnchorRequest() == 0)
    }

    @Test("Planned segment paths parse to indices; everything else does not")
    func segmentPathParsing() {
        #expect(PlanSegmentProvider.segmentIndex(inPath: "seg00004.m4s") == 4)
        #expect(PlanSegmentProvider.segmentIndex(inPath: "audio0/seg00012.m4s") == 12)
        #expect(PlanSegmentProvider.segmentIndex(inPath: "init.mp4") == nil)
        #expect(PlanSegmentProvider.segmentIndex(inPath: "subs0/seg00001.vtt") == nil)
        #expect(PlanSegmentProvider.segmentIndex(inPath: "index.m3u8") == nil)
    }

    // MARK: - End to end

    @Test("A plannable source publishes complete VOD playlists before production finishes")
    func plannedVODPlaylistUpfront() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        // Immediately after readiness — long before a 30 s remux completes —
        // the variant playlist is already a finished VOD listing every
        // planned segment.
        let variant = try await variantURL(playlist: playlist)
        let (data, _) = try await fetch(variant)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(text.contains("#EXT-X-ENDLIST"))

        let segments = text.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
        // 30 s at 6 s targets on a 2 s keyframe grid → 5 segments.
        #expect(segments.count >= 4 && segments.count <= 6)

        // EXTINF durations must sum to (roughly) the container duration —
        // the promise a seek relies on.
        let total = text.split(separator: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).dropLast()) }
            .reduce(0, +)
        #expect(abs(total - 30.0) < 2.0)

        // The audio rendition's planned playlist agrees segment for segment.
        let base = variant.deletingLastPathComponent()
        let (audioData, _) = try await fetch(base.appendingPathComponent("audio0/index.m3u8"))
        let audioText = String(decoding: audioData, as: UTF8.self)
        #expect(audioText.contains("#EXT-X-ENDLIST"))
        let audioSegments = audioText.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
        #expect(audioSegments.count == segments.count)
    }

    @Test("Fetching a not-yet-produced segment re-anchors the producer and serves it")
    func seekAheadProducesOnDemand() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let variant = try await variantURL(playlist: playlist)
        let base = variant.deletingLastPathComponent()
        let (data, _) = try await fetch(variant)
        let text = String(decoding: data, as: UTF8.self)
        let segments = text.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
        let last = try #require(segments.last.map(String.init))

        // The LAST planned segment, demanded right after startup: sequential
        // production can't be there yet, so this serve only succeeds if the
        // provider re-anchored the producer to it (a pending serve that waits
        // for the file). moof+mdat proves it's a real fragment, not filler.
        let (media, status) = try await fetch(base.appendingPathComponent(last))
        #expect(status == 200)
        #expect(media.count > 1_000)
        #expect(media.range(of: Data("moof".utf8)) != nil)
        #expect(media.range(of: Data("mdat".utf8)) != nil)

        // The matching audio rendition segment comes off the same re-anchored
        // producer run.
        let audioLast = last   // same numbering across renditions by design
        let (audio, audioStatus) = try await fetch(base.appendingPathComponent("audio0/\(audioLast)"))
        #expect(audioStatus == 200)
        #expect(audio.range(of: Data("mdat".utf8)) != nil)

        // And a jump BACK still works — the head segment may or may not have
        // been produced before the re-anchor; either way it must serve.
        let first = try #require(segments.first.map(String.init))
        let (headMedia, headStatus) = try await fetch(base.appendingPathComponent(first))
        #expect(headStatus == 200)
        #expect(headMedia.range(of: Data("moof".utf8)) != nil)
    }

    @Test("A segment skipped by a re-anchor is produced even after the producer hit EOF")
    func postEOFBackwardDemand() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let variant = try await variantURL(playlist: playlist)
        let base = variant.deletingLastPathComponent()
        let (data, _) = try await fetch(variant)
        let segments = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").filter { $0.hasSuffix(".m4s") }.map(String.init)

        // Jump straight to the end: the re-anchor skips the middle, and the
        // producer then runs off the EOF cliff…
        _ = try await fetch(base.appendingPathComponent(try #require(segments.last)))
        try await Task.sleep(for: .milliseconds(500))

        // …where it must be PARKED, not gone: a seek back into the skipped
        // middle still has to produce a real fragment.
        let middle = segments[segments.count / 2]
        let (media, status) = try await fetch(base.appendingPathComponent(middle))
        #expect(status == 200)
        #expect(media.range(of: Data("moof".utf8)) != nil)
        #expect(media.range(of: Data("mdat".utf8)) != nil)
    }

    @Test("AVPlayer seeks into unproduced territory and keeps playing there")
    func avPlayerSeek() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let item = AVPlayerItem(url: playlist)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while item.status != .readyToPlay {
            if item.status == .failed || ContinuousClock.now >= readyDeadline {
                Issue.record("item never became ready (error: \(String(describing: item.error)))")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        player.play()
        // Deep into the plan — far past anything sequential production could
        // have reached at readiness. The fetches this triggers only succeed
        // through the demand path.
        await player.seek(to: CMTime(seconds: 24, preferredTimescale: 600))

        var reached = false
        let playDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < playDeadline {
            if item.status == .failed { break }
            if player.currentTime().seconds >= 24.5 { reached = true; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(reached, "playhead never crossed the seek target (error: \(String(describing: item.error)))")
    }

    @Test("A short source (no plan needed) still finishes exactly as before")
    func shortSourceStillSequential() async throws {
        // The 8 s fixture also plans fine — what this really guards is that
        // the planned path's EOF tail produces the final segment and the
        // playlist arithmetic stays coherent end to end.
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let variant = try await variantURL(playlist: playlist)
        // Poll until every listed segment actually exists and serves.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var served = false
        while ContinuousClock.now < deadline, !served {
            let (data, _) = try await fetch(variant)
            let text = String(decoding: data, as: UTF8.self)
            let segments = text.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
            guard text.contains("#EXT-X-ENDLIST"), !segments.isEmpty else {
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            served = true
            for segment in segments {
                let (media, status) = try await fetch(
                    variant.deletingLastPathComponent().appendingPathComponent(String(segment))
                )
                #expect(status == 200)
                #expect(!media.isEmpty)
            }
        }
        #expect(served)
    }
}
