import Testing
import Foundation
@testable import PrismCore

/// The listener the system takes away while the app is suspended (#loopback
/// listener health, 3.8.1): it has to be visible on `isListening`, and
/// `ensureListening()` has to bring the same content back.
@Suite("Loopback listener health")
struct ListenerHealthTests {

    /// The state handler hops onto the actor in a Task, so the flip is
    /// asynchronous; bounded so a regression fails instead of hanging.
    private func waitUntilNotListening(_ read: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await !read() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("A cancelled listener reads as not listening, and a rebind serves again")
    func serverRebinds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("#EXTM3U\n".utf8)
        try payload.write(to: root.appendingPathComponent("index.m3u8"))

        let server = LoopbackHTTPServer(root: root)
        #expect(await server.isListening == false)
        let base = try await server.start()
        defer { Task { await server.stop() } }
        #expect(await server.isListening)
        // While listening, a no-op that hands back the same URL.
        #expect(try await server.ensureListening() == base)

        await server.simulateListenerLoss()
        #expect(await waitUntilNotListening { await server.isListening })
        await #expect(throws: (any Error).self) {
            _ = try await URLSession.uncached.data(from: base.appendingPathComponent("index.m3u8"))
        }

        let rebound = try await server.ensureListening()
        #expect(await server.isListening)
        let (data, response) = try await URLSession.uncached.data(
            from: rebound.appendingPathComponent("index.m3u8")
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == payload)
    }

    @Test("After stop() the server is not listening and does not rebind")
    func stoppedServerStaysDown() async throws {
        let server = LoopbackHTTPServer(root: FileManager.default.temporaryDirectory)
        try await server.start()
        await server.stop()
        #expect(await server.isListening == false)
        await #expect(throws: LoopbackHTTPServer.FailedToStart.self) {
            try await server.ensureListening()
        }
    }

    @Test("A session rebinds its server and serves the same playlist")
    func sessionRebinds() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/h264_aac.mkv", withExtension: nil)
                ?? Bundle.module.url(forResource: "h264_aac.mkv", withExtension: nil, subdirectory: "Fixtures")
        )
        let session = try PrismCoreSession(url: url)
        await #expect(throws: LoopbackHTTPServer.FailedToStart.self) {
            _ = try await session.ensureListening()
        }
        let playlist = try await session.start()
        #expect(await session.isListening)
        let (before, _) = try await URLSession.uncached.data(from: playlist)

        await session.simulateListenerLoss()
        #expect(await waitUntilNotListening { await session.isListening })

        let rebound = try await session.ensureListening()
        #expect(rebound.lastPathComponent == playlist.lastPathComponent)
        #expect(await session.isListening)
        let (after, response) = try await URLSession.uncached.data(from: rebound)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(after == before)

        await session.stop()
        #expect(await session.isListening == false)
        await #expect(throws: LoopbackHTTPServer.FailedToStart.self) {
            _ = try await session.ensureListening()
        }
    }
}
