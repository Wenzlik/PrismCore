import Testing
import Foundation
@testable import PrismCore

/// Temporary reproduction: SDR 1080p panel + 2160p HDR10/DV hybrid MKV
/// crashes the app at load on Apple TV. Run against the user's real file.
@Suite(
    "DEBUG Witcher crash",
    .enabled(if: ProcessInfo.processInfo.environment["WITCHER"] != nil)
)
struct DebugWitcherCrash {

    private var mediaURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["WITCHER"]!)
    }

    @Test("probe + SDR session survives startup and serves segments")
    func sdrSessionStartup() async throws {
        let info = try SourceProbe.probe(url: mediaURL)
        print("DEBUG video: \(String(describing: info.video))")
        print("DEBUG decision: \(String(describing: try? PrismCoreEngine.decide(for: info)))")

        // The user's panel: 1080p, no HDR, no DV.
        let session = try PrismCoreSession(
            url: mediaURL,
            display: DisplayCapabilities(isHDRReady: false, isDolbyVisionCapable: false)
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        print("DEBUG playlist: \(playlist.lastPathComponent)")

        let (data, _) = try await URLSession.shared.data(from: playlist)
        let master = String(decoding: data, as: UTF8.self)
        print("DEBUG master/media:\n\(master)")

        // Follow to the variant and pull a few segments the way AVPlayer would.
        var mediaPlaylist = playlist
        if master.contains("#EXT-X-STREAM-INF") {
            let uris = PrismCoreSession.playlistURIs(inMaster: master)
            mediaPlaylist = playlist.deletingLastPathComponent()
                .appendingPathComponent(uris.last!)
        }
        let (mediaData, _) = try await URLSession.shared.data(from: mediaPlaylist)
        let media = String(decoding: mediaData, as: UTF8.self)
        print("DEBUG media playlist head:\n\(media.prefix(600))")

        let base = mediaPlaylist.deletingLastPathComponent()
        for name in ["init.mp4", "seg00000.m4s", "seg00001.m4s", "seg00002.m4s"] {
            let (segment, response) = try await URLSession.shared.data(
                from: base.appendingPathComponent(name)
            )
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("DEBUG \(name): HTTP \(status), \(segment.count) bytes")
        }
        if let criteria = await session.displayCriteria {
            print("DEBUG display criteria: \(criteria)")
        } else {
            print("DEBUG display criteria: none")
        }
    }
}
