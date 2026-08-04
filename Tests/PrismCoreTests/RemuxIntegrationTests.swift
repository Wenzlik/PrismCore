import Testing
import Foundation
import AVFoundation
@testable import PrismCore

/// End-to-end: fixture file → `PrismCoreSession` → loopback playlist →
/// (a) HTTP round-trip, (b) libavformat re-probe of the produced HLS,
/// (c) a real `AVPlayer` reaching `.readyToPlay` on the served stream.
///
/// The fixtures are synthetic (testsrc2 + sine) — they prove the pipeline,
/// not the premium claims. Atmos (EAC3+JOC) and Dolby Vision need real
/// media and a device; see README "Status".
@Suite("Remux end-to-end", .serialized)
struct RemuxIntegrationTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// Poll the served playlist until it carries `EXT-X-ENDLIST` (remux done).
    private func waitForFinishedPlaylist(_ playlistURL: URL, timeout: Duration = .seconds(30)) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let (data, _) = try await URLSession.shared.data(from: playlistURL)
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("#EXT-X-ENDLIST") { return text }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw PrismCoreSession.SessionError.startupTimedOut(underlying: nil)
    }

    @Test("H.264 + AAC MKV remuxes, serves, and re-probes as the same codecs")
    func h264AACRoundTrip() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let text = try await waitForFinishedPlaylist(playlist)
        #expect(text.contains("#EXT-X-MAP"))
        #expect(text.contains(".m4s"))

        // Round-trip proof: our own probe re-opens the SERVED playlist (the
        // hls demuxer follows init + segments over the loopback).
        let info = try SourceProbe.probe(url: playlist)
        #expect(info.video?.codecName == "h264")
        #expect(info.audioTracks.map(\.codecName).contains("aac"))
    }

    @Test("HEVC + EAC3 MKV keeps EAC3 by stream-copy — the Atmos carrier path")
    func hevcEAC3KeepsBitstream() async throws {
        let session = try PrismCoreSession(url: try fixture("hevc_eac3.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        _ = try await waitForFinishedPlaylist(playlist)
        let info = try SourceProbe.probe(url: playlist)
        let audioCodecs = info.audioTracks.map(\.codecName)
        // Stream-copy means the codec survives untouched. A real Atmos track
        // is EAC3+JOC — same codec id, JOC rides inside — so this is the
        // closest a synthetic fixture can get to the Atmos claim.
        #expect(audioCodecs.contains("eac3"))
    }

    @Test("DTS audio: video still plays; any audio that survives is bridged EAC3")
    func dtsAudio() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_dts.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        _ = try await waitForFinishedPlaylist(playlist)
        let info = try SourceProbe.probe(url: playlist)
        let audioCodecs = info.audioTracks.map(\.codecName)
        #expect(info.video?.codecName == "h264")
        // v0 drops non-copyable audio with no copyable sibling; the phase-3
        // bridge turns it into EAC3. Either way, DTS must never reach the
        // output — AVPlayer can't decode it from fMP4.
        #expect(!audioCodecs.contains("dts"))
        if !audioCodecs.isEmpty {
            #expect(audioCodecs.contains("eac3"))
        }
    }

    @Test("VP9 refuses fast with the routing error — the 'send it to Prism' signal")
    func vp9Refuses() async throws {
        let session = try PrismCoreSession(url: try fixture("vp9.webm"))
        do {
            _ = try await session.start()
            Issue.record("VP9 must not produce a native playlist")
        } catch let error as PrismCoreSession.SessionError {
            if case .startupTimedOut(let underlying) = error {
                #expect(underlying is HLSRemuxer.Failure)
            }
        }
        await session.stop()
    }

    @Test("AVPlayer reaches readyToPlay on the served stream")
    func avPlayerReadiness() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let item = AVPlayerItem(url: playlist)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        let ready: Bool = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                switch item.status {
                case .readyToPlay: once.run { continuation.resume(returning: true) }
                case .failed: once.run { continuation.resume(returning: false) }
                default: break
                }
            }
            // Bound the wait; keep the observation alive inside the closure.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                _ = observation   // retained until here
                once.run { continuation.resume(returning: false) }
            }
        }
        #expect(ready, "AVPlayerItem should reach .readyToPlay (error: \(String(describing: item.error)))")
        _ = player   // keep alive through the wait
    }
}
