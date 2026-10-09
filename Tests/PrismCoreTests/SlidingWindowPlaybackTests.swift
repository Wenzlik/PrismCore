import Testing
import Foundation
@testable import PrismCore

/// A sequential session in sliding-window mode, served over the loopback the
/// way AVPlayer reads it: the promise under test is that no URL a manifest
/// offers — the current one, or an older copy still inside its grace period —
/// answers anything but 200.
@Suite("Sequential sliding window over HTTP", .serialized)
struct SlidingWindowPlaybackTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// The window's grace-period clock, moved by the test.
    private final class SteppedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var now: TimeInterval { lock.withLock { value } }
        func set(_ seconds: TimeInterval) { lock.withLock { value = seconds } }
    }

    private func status(_ url: URL) async throws -> Int {
        let (_, response) = try await URLSession.uncached.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func text(_ url: URL) async throws -> String {
        String(decoding: try await URLSession.uncached.data(from: url).0, as: UTF8.self)
    }

    @Test("Every URL a manifest offers serves, before and during the grace period; only then is it unlinked")
    func everyOfferedURLServes() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreSliding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        // A minute, two copied audio tracks and an SRT: ~11 segments per
        // playlist. The zero index budget makes it sequential (the Cues are
        // at the tail — at the default 6 s target; a 2 s one would accept the
        // keyframes the probe happened to read as a plan), and ~100 KB of
        // budget is a few segments, so the budget — not just time — moves
        // the window.
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        let demand = DemandCoordinator()
        let remuxer = HLSRemuxer(
            sourceURL: try fixture("h264_aac_ac3_srt_60s.mkv"),
            outputDirectory: output,
            demand: demand,
            segmentCacheBytes: 100_000,
            sequentialPlaylist: .slidingWindow(seconds: 8),
            indexLoadBudget: .zero
        )
        let clock = SteppedClock()
        remuxer.windowClock = { clock.now }
        // One cut per round, on the test's word: every check below fetches
        // segments, every fetch moves the playhead the window follows, and a
        // local file left to run would be remuxed to EOF before the first
        // round. Held right after a variant segment lands — before its
        // renditions are cut and before the window slides for it.
        let gate = DispatchSemaphore(value: 0)
        remuxer.onSegmentLanded = { _ in gate.wait() }
        let server = LoopbackHTTPServer(provider: PlanSegmentProvider(root: output, coordinator: demand))
        let base = try await server.start()
        defer { Task { await server.stop() } }
        demand.noteFetch(of: 0)
        let producer = ProducerThread(name: "prismcore.tests.sliding") { try remuxer.run() }
        defer {
            remuxer.cancel()
            for _ in 0..<64 { gate.signal() }
            Task { await producer.join() }
        }
        /// Let the held cut finish and wait until the next one is held (or
        /// the source ended).
        func step() async throws {
            let variant = output.appendingPathComponent(HLSRemuxer.mediaPlaylistFileName)
            let before = (try? String(contentsOf: variant, encoding: .utf8)) ?? ""
            gate.signal()
            while ContinuousClock.now < deadline {
                let now = (try? String(contentsOf: variant, encoding: .utf8)) ?? ""
                let parsed = SegmentVerifier.parseMediaPlaylist(now)
                if parsed.isEnded || parsed.segments.last?.uri != SegmentVerifier.parseMediaPlaylist(before).segments.last?.uri {
                    // Ended: give the renditions' closing writes their moment.
                    if parsed.isEnded { await producer.join() }
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let master = base.appendingPathComponent(HLSRemuxer.masterPlaylistFileName)
        let variantPath = output.appendingPathComponent(HLSRemuxer.mediaPlaylistFileName).path
        while !FileManager.default.fileExists(atPath: variantPath), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The first cut's renditions write their playlists once it is let go.
        try await step()
        let playlistURIs = PrismCoreSession.playlistURIs(inMaster: try await text(master))
        // Variant, both audio renditions and the subtitle rendition.
        #expect(playlistURIs.count == 4, "\(playlistURIs)")

        /// Every media playlist, parsed, by URI.
        func manifests() async throws -> [String: SegmentVerifier.MediaPlaylist] {
            var result: [String: SegmentVerifier.MediaPlaylist] = [:]
            for uri in playlistURIs {
                let url = base.appendingPathComponent(uri)
                // A rendition writes its playlist at its first cut, a moment
                // after the master names it.
                while (try? await status(url)) != 200, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let body = try await text(url)
                #expect(!body.contains("PLAYLIST-TYPE"), "\(uri) is not a sliding playlist:\n\(body)")
                result[uri] = SegmentVerifier.parseMediaPlaylist(body)
            }
            return result
        }
        func offered(_ manifests: [String: SegmentVerifier.MediaPlaylist]) -> Set<String> {
            var urls: Set<String> = []
            for (uri, playlist) in manifests {
                let directory = (uri as NSString).deletingLastPathComponent
                for segment in playlist.segments {
                    urls.insert(directory.isEmpty ? segment.uri : "\(directory)/\(segment.uri)")
                }
                if let initURI = playlist.initURI {
                    urls.insert(directory.isEmpty ? initURI : "\(directory)/\(initURI)")
                }
            }
            return urls
        }
        var variantURI: String { playlistURIs.first { !$0.contains("/") } ?? "index.m3u8" }

        var previous: Set<String> = []
        var left: Set<String> = []
        var lastSequence: [String: Int] = [:]
        var playhead = 0
        var unlinked: Set<String>?   // what left before the clock jumped
        var ended = false
        while !ended, ContinuousClock.now < deadline {
            let current = try await manifests()
            for (uri, playlist) in current {
                #expect(playlist.mediaSequence >= lastSequence[uri, default: 0], "\(uri) went backwards")
                lastSequence[uri] = playlist.mediaSequence
            }
            let offeredNow = offered(current)
            // An older manifest's URLs are still inside their grace period:
            // whatever left since the last round left at a cut after any
            // clock jump, so its period runs from a clock that has not moved.
            for url in previous.subtracting(offeredNow) {
                #expect(try await status(base.appendingPathComponent(url)) == 200, "\(url) left the playlist and stopped serving at once")
            }
            left.formUnion(previous.subtracting(offeredNow))
            for url in offeredNow.sorted() {
                #expect(try await status(base.appendingPathComponent(url)) == 200, "\(url) is offered but does not serve")
            }
            previous = offeredNow
            ended = current.values.allSatisfy(\.isEnded)

            // Fetched last, so it is the playhead the next cut sees.
            let variant = try #require(current[variantURI])
            playhead = max(playhead, variant.mediaSequence)
            _ = try await status(base.appendingPathComponent(String(format: "seg%05d.m4s", playhead)))
            playhead += 1

            // Once the window has moved, let the grace period run out: the
            // next cut unlinks everything that left before now.
            if unlinked == nil, variant.mediaSequence >= 2, !ended {
                unlinked = left
                clock.set(1_000_000)
            }
            if !ended { try await step() }
        }
        #expect(ended, "production never reached EOF")

        let final = try await manifests()
        for (uri, playlist) in final {
            #expect(playlist.isEnded, "\(uri) has no ENDLIST")
            #expect(playlist.mediaSequence > 0, "\(uri) never slid")
        }
        let gone = try #require(unlinked)
        #expect(gone.contains { $0.hasSuffix(".vtt") }, "no subtitle segment left the window: \(gone)")
        #expect(gone.contains { $0.hasPrefix("audio1/") }, "no second-audio segment left the window: \(gone)")
        // Unlinked off the producer's thread: wait for the queue, then the
        // files are gone and the provider answers a plain 404 — a segment no
        // current manifest offers any more.
        let unlinkDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while gone.contains(where: { FileManager.default.fileExists(atPath: output.appendingPathComponent($0).path) }),
              ContinuousClock.now < unlinkDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        for url in gone.sorted() {
            #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent(url).path), "\(url) was not unlinked")
            #expect(try await status(base.appendingPathComponent(url)) == 404, "\(url)")
        }
        // Left after the jump, so still inside its grace period: on disk.
        #expect(!left.subtracting(gone).isEmpty, "nothing left the window after the clock jumped")
        for url in left.subtracting(gone) {
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(url).path), "\(url) was unlinked early")
        }

        // The same walk `prismcore-cli segverify --hls` makes, over what the
        // finished window offers.
        let report = try await SegmentVerifier.verify(playlist: master)
        #expect(!report.hasErrors, "findings: \(report.findings)")
    }

    @Test("A planned session ignores the option: the VOD playlist lists the whole source")
    func plannedSessionIgnoresTheWindow() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreSlidingPlanned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let demand = DemandCoordinator()
        demand.noteFetch(of: 0)
        let remuxer = HLSRemuxer(
            sourceURL: try fixture("h264_aac_30s.mkv"),
            outputDirectory: output,
            demand: demand,
            segmentCacheBytes: 1,
            sequentialPlaylist: .slidingWindow(seconds: 0)
        )
        let producer = ProducerThread(name: "prismcore.tests.sliding-planned") { try remuxer.run() }
        defer { remuxer.cancel(); Task { await producer.join() } }
        let variant = output.appendingPathComponent(HLSRemuxer.mediaPlaylistFileName)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !FileManager.default.fileExists(atPath: variant.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try String(contentsOf: variant, encoding: .utf8)
        #expect(text.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:0\n"))
        #expect(text.contains("seg00000.m4s"))
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }
}
