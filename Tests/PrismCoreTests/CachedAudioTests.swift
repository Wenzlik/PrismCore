import Testing
import Foundation
@testable import PrismCore

/// `cachedAudio` reads what is resident and nothing else. The fixtures are
/// testsrc2 + sine, so a decoded clip is a steady tone: its RMS says the
/// decode ran, its length and rate say the resample did. The side-effect
/// assertions are the point of the API — a read the demand seam took for a
/// fetch would move the playhead production is scheduled around.
@Suite("Cached audio", .serialized)
struct CachedAudioTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// A private copy, so a test can delete the source and prove the read
    /// never needed it.
    private func copiedFixture(_ name: String) throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreCachedAudio-\(UUID().uuidString)-\(name)")
        try FileManager.default.copyItem(at: try fixture(name), to: copy)
        return copy
    }

    /// Waits for the producer to have written `[from, to]` (it runs to EOF
    /// with nobody fetching).
    private func waitResident(_ session: PrismCoreSession, _ from: Double, _ to: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if session.residentRanges.contains(where: { $0.startSeconds <= from && $0.endSeconds >= to }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("[\(from), \(to)] never became resident: \(session.residentRanges)")
    }

    private func rms(_ samples: [Float]) -> Double {
        (samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))).squareRoot()
    }

    /// `(NAME, URI)` of every audio rendition in the served master.
    private func audioRenditions(_ session: PrismCoreSession) async throws -> [(name: String, uri: String)] {
        let master = try String(contentsOf: await session.workDirectory.appendingPathComponent("master.m3u8"), encoding: .utf8)
        func attribute(_ key: String, _ line: Substring) -> String? {
            guard let range = line.range(of: "\(key)=\"") else { return nil }
            return String(line[range.upperBound...].prefix { $0 != "\"" })
        }
        return master.split(separator: "\n").filter { $0.contains("TYPE=AUDIO") }.compactMap { line in
            guard let name = attribute("NAME", line), let uri = attribute("URI", line) else { return nil }
            return (name, uri)
        }
    }

    @Test("A resident AAC range comes back as 48 kHz mono of the asked length, and touches nothing")
    func aacClipHasNoSideEffects() async throws {
        let source = try copiedFixture("h264_aac_30s.mkv")
        let session = try PrismCoreSession(url: source)
        defer { Task { await session.stop() } }
        _ = try await session.start()
        try await waitResident(session, 0, 29)
        let bytesBefore = session.sourceBytesRead
        try FileManager.default.removeItem(at: source)

        let clip = try #require(try await session.cachedAudio(from: 10, duration: 3))
        #expect(clip.sampleRate == 48_000)
        #expect(clip.samples.count == 144_000, "44.1 kHz source, 3 s at 48 kHz")
        #expect(abs(clip.startSeconds - 10) < 0.001)
        #expect(rms(clip.samples) > 0.02, "the fixture's sine decoded to silence")

        try await Task.sleep(for: .milliseconds(300))
        #expect(session.demand.playheadIndex == nil, "a cache read reached noteFetch")
        #expect(session.demand.takeAnchorRequest() == nil, "a cache read asked for production")
        #expect(session.sourceBytesRead == bytesBefore, "a cache read made the producer read the source")
    }

    @Test("A duration past the cap is clamped to 30 s, not refused")
    func durationClamps() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_ac3_srt_60s.mkv"))
        defer { Task { await session.stop() } }
        _ = try await session.start()
        try await waitResident(session, 5, 50)
        let clip = try #require(try await session.cachedAudio(from: 10, duration: 45))
        #expect(clip.samples.count == 30 * 48_000)
    }

    @Test("Anything not resident is nil, and the demand seam never hears of it")
    func nonResidentIsNil() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        defer { Task { await session.stop() } }
        #expect(try await session.cachedAudio(from: 1, duration: 2) == nil, "before start()")
        _ = try await session.start()
        try await waitResident(session, 0, 29)
        let bytesBefore = session.sourceBytesRead

        #expect(try await session.cachedAudio(from: 10_000, duration: 2) == nil)
        #expect(try await session.cachedAudio(from: -50, duration: 2) == nil)
        #expect(try await session.cachedAudio(from: 25, duration: 20) == nil, "runs past the end")
        #expect(try await session.cachedAudio(from: 5, duration: 0) == nil)
        #expect(try await session.cachedAudio(from: .nan, duration: 2) == nil)

        try await Task.sleep(for: .milliseconds(300))
        #expect(session.demand.playheadIndex == nil)
        #expect(session.demand.takeAnchorRequest() == nil)
        #expect(session.sourceBytesRead == bytesBefore)
    }

    @Test("AC-3 5.1 downmixes; a lazy bridged rendition is not resident and stays unarmed")
    func ac3AndLazyRendition() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_ac3_dts_20s.mkv"))
        defer { Task { await session.stop() } }
        _ = try await session.start()
        try await waitResident(session, 0, 19)

        let clip = try #require(try await session.cachedAudio(from: 6, duration: 2))
        #expect(clip.samples.count == 96_000)
        #expect(rms(clip.samples) > 0.01)

        let renditions = try await audioRenditions(session)
        #expect(renditions.count == 2)
        let lazy = try #require(renditions.last)
        #expect(await session.audioRenditionProductions.contains { $0.production == .lazy })
        #expect(try await session.cachedAudio(from: 6, duration: 2, renditionName: lazy.name) == nil)

        try await Task.sleep(for: .milliseconds(300))
        let lazyDirectory = await session.workDirectory
            .appendingPathComponent(String(lazy.uri.split(separator: "/").first ?? ""))
        let written = (try? FileManager.default.contentsOfDirectory(atPath: lazyDirectory.path)) ?? []
        #expect(!written.contains { $0.hasSuffix(".mp4") || $0.hasSuffix(".m4s") }, "the lazy rendition was armed: \(written)")
        #expect(session.demand.playheadIndex == nil)
    }

    @Test("E-AC-3 decodes")
    func eac3Clip() async throws {
        let session = try PrismCoreSession(url: try fixture("hevc_eac3.mkv"))
        defer { Task { await session.stop() } }
        _ = try await session.start()
        try await waitResident(session, 2, 5)
        let clip = try #require(try await session.cachedAudio(from: 2, duration: 2))
        #expect(clip.samples.count == 96_000)
        #expect(rms(clip.samples) > 0.02)
    }

    @Test("renditionName picks the track; nil is the DEFAULT; an unknown name throws")
    func renditionSelection() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_multi_audio.mkv"))
        defer { Task { await session.stop() } }
        _ = try await session.start()
        try await waitResident(session, 2, 6)
        let renditions = try await audioRenditions(session)
        #expect(renditions.count == 2)
        let defaultName = try #require(renditions.first?.name)
        let otherName = try #require(renditions.last?.name)

        let byDefault = try #require(try await session.cachedAudio(from: 3, duration: 2))
        let named = try #require(try await session.cachedAudio(from: 3, duration: 2, renditionName: defaultName))
        let other = try #require(try await session.cachedAudio(from: 3, duration: 2, renditionName: otherName))
        #expect(byDefault == named)
        #expect(other.samples.count == 96_000)
        #expect(other != byDefault, "both names decoded the same track")
        await #expect(throws: PrismCoreSession.CachedAudioError.unknownRendition("Klingon")) {
            _ = try await session.cachedAudio(from: 3, duration: 2, renditionName: "Klingon")
        }
    }

    @Test("The muxed shape reads the variant's own track")
    func muxedShape() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"), forceMuxedShape: true)
        defer { Task { await session.stop() } }
        _ = try await session.start()
        try await waitResident(session, 8, 14)
        let clip = try #require(try await session.cachedAudio(from: 10, duration: 3))
        #expect(clip.samples.count == 144_000)
        #expect(rms(clip.samples) > 0.02)
        await #expect(throws: PrismCoreSession.CachedAudioError.self) {
            _ = try await session.cachedAudio(from: 10, duration: 3, renditionName: "English")
        }
    }

    @Test("After stop() the answer is nil")
    func afterStop() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        _ = try await session.start()
        try await waitResident(session, 2, 6)
        #expect(try await session.cachedAudio(from: 3, duration: 2) != nil)
        await session.stop()
        #expect(try await session.cachedAudio(from: 3, duration: 2) == nil)
    }

    @Test("An audio offset moves the clip: it is what is heard at the time asked")
    func audioDelayAlignment() async throws {
        let plain = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"))
        let delayed = try PrismCoreSession(url: try fixture("h264_aac_30s.mkv"), audioDelaySeconds: 0.5)
        defer { Task { await plain.stop(); await delayed.stop() } }
        _ = try await plain.start()
        _ = try await delayed.start()
        try await waitResident(plain, 0, 6)
        try await waitResident(delayed, 0, 6)
        let origin = try #require(delayed.residentRanges.first?.startSeconds)

        #expect(try await plain.cachedAudio(from: origin, duration: 1) != nil)
        // Nothing is heard in the first half second of the delayed session.
        #expect(try await delayed.cachedAudio(from: origin, duration: 1) == nil)
        let shifted = try #require(try await delayed.cachedAudio(from: origin + 0.5, duration: 1))
        #expect(abs(shifted.startSeconds - (origin + 0.5)) < 0.001)
        #expect(shifted.samples.count == 48_000)
    }

    // MARK: - The store

    private func storeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrismCoreAudioRun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio0"), withIntermediateDirectories: true)
        try Data([0xAA]).write(to: root.appendingPathComponent("audio0/init.mp4"))
        return root
    }

    private func publish(_ store: ResidentSegmentStore, _ index: Int, _ start: Double, _ end: Double, root: URL) throws {
        try store.publish(index: index, start: start, end: end, data: Data([UInt8(index)]), root: root)
        try Data([UInt8(100 + index)]).write(to: root.appendingPathComponent(String(format: "audio0/seg%05d.m4s", index)))
    }

    @Test("A run is init plus every segment the range needs, with a neighbour each side; a gap is nil")
    func storeRun() throws {
        let root = try storeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResidentSegmentStore()
        for (index, start) in [0.0, 2, 4, 6].enumerated() {
            try publish(store, index, start, start + 2, root: root)
        }
        let run = try #require(store.openAudioRun(from: 2.5, to: 4.5, directory: "audio0", root: root))
        #expect(try run.map { try $0.readToEnd() } == [Data([0xAA]), Data([100]), Data([101]), Data([102]), Data([103])])

        store.retire([2])
        #expect(store.openAudioRun(from: 3, to: 5, directory: "audio0", root: root) == nil, "a gap counted as resident")
        // Missing rendition file for a needed segment: its cut has not landed.
        try FileManager.default.removeItem(at: root.appendingPathComponent("audio0/seg00000.m4s"))
        #expect(store.openAudioRun(from: 0.5, to: 1, directory: "audio0", root: root) == nil)
        // A missing NEIGHBOUR is not needed.
        #expect(store.openAudioRun(from: 2.5, to: 3, directory: "audio0", root: root)?.count == 2)
    }

    @Test("A superseded index is not resident; an eviction mid-read does not take the bytes away")
    func storeSupersedeAndEviction() throws {
        let root = try storeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResidentSegmentStore()
        try publish(store, 0, 0, 2, root: root)
        try publish(store, 1, 2, 4, root: root)

        let run = try #require(store.openAudioRun(from: 0.5, to: 3, directory: "audio0", root: root))
        store.retire([0, 1])
        store.unlinkRetired(index: 0, directories: [root, root.appendingPathComponent("audio0")])
        store.unlinkRetired(index: 1, directories: [root, root.appendingPathComponent("audio0")])
        #expect(try run.map { try $0.readToEnd() } == [Data([0xAA]), Data([100]), Data([101])])

        try publish(store, 0, 0, 2, root: root)
        try publish(store, 1, 2, 4, root: root)
        _ = store.supersedeAll()
        // Re-published video, rendition not yet rewritten: still superseded.
        try publish(store, 0, 0, 2, root: root)
        #expect(store.openAudioRun(from: 0.5, to: 1, directory: "audio0", root: root) == nil)
        store.markProduced(index: 0)
        #expect(store.openAudioRun(from: 0.5, to: 1, directory: "audio0", root: root) != nil)

        store.clear()
        #expect(store.openAudioRun(from: 0.5, to: 1, directory: "audio0", root: root) == nil)
    }
}
