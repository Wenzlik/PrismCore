import Testing
import Foundation
import Libavcodec
@testable import PrismCore

/// A language cannot tell two tracks of one language apart — TrueHD Atmos and
/// EAC3-JOC are both `eng` — so a host that already chose a *track* names it by
/// source stream index, and that pick outranks the language.
@Suite("Preferred stream index")
struct StreamIndexPreferenceTests {

    private let bridgeEverything: (AVCodecID) -> Bool = { AudioBridge.bridgeableAudio.contains($0) }
    private let bridgeNothing: (AVCodecID) -> Bool = { _ in false }

    /// The shape the feature exists for: two English tracks, the TrueHD one
    /// first, original and default.
    private let twoEnglishTracks = [
        HLSRemuxer.AudioCandidate(
            index: 1, codecID: AV_CODEC_ID_TRUEHD, isOriginal: true, isDefault: true, language: "eng"
        ),
        HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_EAC3, language: "eng"),
    ]

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func master(of session: PrismCoreSession) async throws -> String {
        let playlist = try await session.start()
        let (data, _) = try await URLSession.uncached.data(from: playlist)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("The named track wins over a matching language and every source flag")
    func indexOutranksLanguage() {
        let route = HLSRemuxer.chooseAudio(
            candidates: twoEnglishTracks, best: 1, preferredLanguage: "en",
            preferredStreamIndex: 2, canBridge: bridgeEverything
        )
        #expect(route == HLSRemuxer.AudioRoute(index: 2, mode: .streamCopy))
        // It leads the renditions, so it is the master's DEFAULT; nothing is dropped.
        let routes = HLSRemuxer.routeAll(
            candidates: twoEnglishTracks, best: 1, preferredLanguage: "en",
            preferredStreamIndex: 2, canBridge: bridgeEverything
        )
        #expect(routes.map(\.index) == [2, 1])
    }

    @Test("An index naming nothing carriable falls back to the language, then the source")
    func uncarriableOrUnknownIndexFallsThrough() {
        // TrueHD with no encoder: neither copied nor bridged, so the pick finds nothing.
        let candidates = [
            HLSRemuxer.AudioCandidate(index: 1, codecID: AV_CODEC_ID_AAC, language: "eng"),
            HLSRemuxer.AudioCandidate(index: 2, codecID: AV_CODEC_ID_TRUEHD, language: "eng"),
            HLSRemuxer.AudioCandidate(index: 3, codecID: AV_CODEC_ID_AC3, language: "ces"),
        ]
        #expect(HLSRemuxer.chooseAudio(
            candidates: candidates, best: 1, preferredLanguage: "cs",
            preferredStreamIndex: 2, canBridge: bridgeNothing
        ) == HLSRemuxer.AudioRoute(index: 3, mode: .streamCopy))
        // An index that is no audio stream at all (the video's, say) is the same no-op.
        #expect(HLSRemuxer.chooseAudio(
            candidates: candidates, best: 1, preferredStreamIndex: 0, canBridge: bridgeNothing
        ) == HLSRemuxer.chooseAudio(candidates: candidates, best: 1, canBridge: bridgeNothing))
    }

    @Test("A subtitle position wins over the language, a stale one changes nothing")
    func subtitlePositionOutranksLanguage() {
        let renditions = [
            MasterPlaylistBuilder.SubtitleRendition(name: "English", language: "eng", uri: "subs0/index.m3u8"),
            MasterPlaylistBuilder.SubtitleRendition(name: "English SDH", language: "eng", uri: "subs1/index.m3u8"),
        ]
        let picked = SubtitleRenditionSet.applyingPreferredDefault(
            renditions, preferredLanguage: "en", preferredPosition: 1
        )
        #expect(picked.map(\.isDefault) == [false, true])
        let stale = SubtitleRenditionSet.applyingPreferredDefault(
            renditions, preferredLanguage: "en", preferredPosition: 7
        )
        #expect(stale.map(\.isDefault) == [true, false])
    }

    @Test("End to end: the named audio stream is the served DEFAULT despite the language")
    func audioIndexInTheServedMaster() async throws {
        // Stream 1 is English AAC, stream 2 Czech AC3.
        let session = try PrismCoreSession(
            url: try fixture("h264_multi_audio.mkv"),
            preferredAudioLanguage: "en",
            preferredAudioStreamIndex: 2
        )
        defer { Task { await session.stop() } }
        let lines = try await master(of: session).split(separator: "\n")
            .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
        let defaults = lines.filter { $0.contains("DEFAULT=YES") }
        #expect(defaults.count == 1)
        #expect(defaults.first?.contains("LANGUAGE=\"ces\"") == true, "\(lines)")
        #expect(lines.count == 2)
        #expect(await session.options.preferredAudioStreamIndex == 2)
    }

    @Test("An index no stream can have is unmatched, not a trap")
    func unrepresentableIndexFallsBack() async throws {
        let session = try PrismCoreSession(
            url: try fixture("h264_multi_audio.mkv"),
            preferredAudioLanguage: "cs",
            preferredAudioStreamIndex: Int.max,
            preferredSubtitleStreamIndex: Int.min
        )
        defer { Task { await session.stop() } }
        let defaults = try await master(of: session).split(separator: "\n")
            .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") && $0.contains("DEFAULT=YES") }
        #expect(defaults.count == 1)
        #expect(defaults.first?.contains("LANGUAGE=\"ces\"") == true)
    }

    @Test("End to end: the named subtitle stream is the DEFAULT, even a forced one")
    func subtitleIndexInTheServedMaster() async throws {
        // Two English SRT tracks: stream 2 full, stream 3 forced. The language
        // alone would give the flag to the full one.
        let session = try PrismCoreSession(
            url: try fixture("h264_aac_forced_subs.mkv"),
            preferredSubtitleLanguage: "en",
            preferredSubtitleStreamIndex: 3
        )
        defer { Task { await session.stop() } }
        let lines = try await master(of: session).split(separator: "\n")
            .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") }
        #expect(lines.count == 2)
        let defaults = lines.filter { $0.contains("DEFAULT=YES") }
        #expect(defaults.count == 1)
        #expect(defaults.first?.contains("subs1/") == true, "\(lines)")
    }
}
