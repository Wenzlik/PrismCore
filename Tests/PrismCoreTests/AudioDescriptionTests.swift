import Testing
import Foundation
import Libavcodec
import Libavformat
import Libavutil
@testable import PrismCore

/// Audio description: the container's `AV_DISPOSITION_VISUAL_IMPAIRED` read
/// into `AudioTrackInfo`, and declared in the master as
/// `public.accessibility.describes-video` — which keeps AVFoundation from
/// auto-selecting a narrated track for everyone.
@Suite("Audio description")
struct AudioDescriptionTests {

    private func track(isAudioDescription: Bool) -> AudioTrackInfo {
        AudioTrackInfo(
            streamIndex: 1, codecName: "eac3", profileName: nil,
            channelCount: 6, channelLayoutDescription: "5.1",
            sampleRate: 48_000, language: "en", title: "Described",
            isObjectAudio: false, copyability: .streamCopy,
            isAudioDescription: isAudioDescription
        )
    }

    @Test("The disposition flag reaches AudioTrackInfo, and its absence does not")
    func probeReadsDisposition() throws {
        let format = try #require(avformat_alloc_context())
        defer { avformat_free_context(format) }
        for flagged in [true, false] {
            let stream = try #require(avformat_new_stream(format, nil))
            stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
            stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_AAC
            stream.pointee.codecpar.pointee.sample_rate = 48_000
            av_channel_layout_default(&stream.pointee.codecpar.pointee.ch_layout, 2)
            stream.pointee.disposition = flagged ? AV_DISPOSITION_VISUAL_IMPAIRED : AV_DISPOSITION_DEFAULT
        }
        let info = SourceProbe.describe(input: format)
        #expect(info.audioTracks.map(\.isAudioDescription) == [true, false])
    }

    @Test("Existing initializers default to not-described")
    func defaultsOff() {
        let plain = AudioTrackInfo(
            streamIndex: 0, codecName: "aac", profileName: nil,
            channelCount: 2, channelLayoutDescription: "stereo",
            sampleRate: 48_000, language: nil, title: nil,
            isObjectAudio: false, copyability: .streamCopy
        )
        #expect(!plain.isAudioDescription)
    }

    @Test("Characteristics: boost, description, both, neither")
    func characteristicCombinations() {
        #expect(AudioRenditionWriter.characteristics(isDialogueBoost: false, isAudioDescription: false).isEmpty)
        #expect(AudioRenditionWriter.characteristics(isDialogueBoost: false, isAudioDescription: true)
            == [audioDescriptionCharacteristic])
        #expect(AudioRenditionWriter.characteristics(isDialogueBoost: true, isAudioDescription: false)
            == [dialogueBoostCharacteristic])
        #expect(AudioRenditionWriter.characteristics(isDialogueBoost: true, isAudioDescription: true)
            == [dialogueBoostCharacteristic, audioDescriptionCharacteristic])
        #expect(audioDescriptionCharacteristic == "public.accessibility.describes-video")
    }

    @Test("A described stream-copied track declares describes-video in the master")
    func masterDeclaresDescription() throws {
        let directory = FileManager.default.temporaryDirectory
        let described = AudioRenditionWriter(
            route: .init(index: 1, mode: .streamCopy),
            track: track(isAudioDescription: true), ordinal: 1, parent: directory
        ).rendition(groupID: "aud", isDefault: false)
        let plain = AudioRenditionWriter(
            route: .init(index: 1, mode: .streamCopy),
            track: track(isAudioDescription: false), ordinal: 0, parent: directory
        ).rendition(groupID: "aud", isDefault: true)
        #expect(described.characteristics == [audioDescriptionCharacteristic])
        #expect(plain.characteristics.isEmpty)

        let master = try MasterPlaylistBuilder.build(.init(
            bandwidth: 5_000_000,
            videoCodec: .explicit("avc1.640028"),
            audioRenditions: [plain, described]
        ))
        let lines = master.split(separator: "\n").filter { $0.contains("CHARACTERISTICS") }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("CHARACTERISTICS=\"public.accessibility.describes-video\"") == true)
    }
}
