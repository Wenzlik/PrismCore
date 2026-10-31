import Testing
import Foundation
import Libavcodec
import Libavutil
@testable import PrismCore

/// Night mode and the channel cap (`BridgedAudioProcessing`): the filter chain
/// a re-encoded rendition runs (pure), the bridge that runs it, and the
/// session option that reaches it. Stream-copied tracks never build a bridge,
/// which is the whole guarantee that they stay untouched.
@Suite("Bridged audio processing")
struct BridgedAudioProcessingTests {

    private static let sampleRate: Int32 = 48_000
    private let surround = ["FL", "FR", "FC", "LFE", "SL", "SR"]
    private let night = "acompressor=threshold=0.0625:ratio=4:attack=10:release=250"

    private func describe(_ names: [String], _ level: DialogueBoostLevel?, night: Bool) -> String {
        DialogueBoostFilter.graphDescription(
            DialogueBoostFilter.stages(channelNames: names, boostLevel: level, nightMode: night)
        )
    }

    @Test("Off by default")
    func defaultIsOff() {
        let processing = BridgedAudioProcessing()
        #expect(!processing.nightMode)
        #expect(processing.maxChannels == nil)
    }

    @Test("Boost alone is the pan it always was")
    func boostOnly() {
        #expect(describe(surround, .medium, night: false)
            == "pan=FL+FR+FC+LFE+SL+SR|FL=0.5000*FL|FR=0.5000*FR|FC=FC|LFE=0.5000*LFE|SL=0.5000*SL|SR=0.5000*SR")
    }

    @Test("Night mode alone runs on any layout, stereo included")
    func nightOnly() {
        #expect(describe(["FL", "FR"], nil, night: true) == night)
        #expect(describe(surround, nil, night: true) == night)
    }

    @Test("Boost and night mode chain: pan first, then the compressor")
    func boostThenNight() {
        let chain = describe(surround, .high, night: true)
        #expect(chain.hasPrefix("pan=FL+FR+FC+LFE+SL+SR|FL=0.2500*FL|"))
        #expect(chain.hasSuffix("," + night))
    }

    @Test("Nothing to do is an empty chain — the frames pass through")
    func emptyChain() {
        #expect(DialogueBoostFilter.stages(channelNames: surround, boostLevel: nil, nightMode: false).isEmpty)
        // No centre: the boost has nothing to favour.
        #expect(DialogueBoostFilter.stages(channelNames: ["FL", "FR"], boostLevel: .medium, nightMode: false).isEmpty)
        // …but night mode still applies.
        #expect(describe(["FL", "FR"], .medium, night: true) == night)
    }

    // MARK: - The bridge

    private static var stubEncoder: AVCodecID? {
        for candidate in [AV_CODEC_ID_FLAC, AV_CODEC_ID_AAC, AV_CODEC_ID_ALAC]
        where avcodec_find_encoder(candidate) != nil {
            return candidate
        }
        return nil
    }

    private func makeCodecpar(channels: Int32) -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        par.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        par.pointee.sample_rate = Self.sampleRate
        par.pointee.bits_per_coded_sample = 16
        par.pointee.block_align = channels * 2
        av_channel_layout_default(&par.pointee.ch_layout, channels)
        return par
    }

    private func makeBridge(
        channels: Int32, processing: BridgedAudioProcessing
    ) throws -> AudioBridge {
        let target = try #require(Self.stubEncoder, "no audio encoder in this FFmpeg build")
        let par = makeCodecpar(channels: channels)
        defer { var par: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&par) }
        return try AudioBridge(
            codecpar: par,
            timeBase: AVRational(num: 1, den: Self.sampleRate),
            globalHeader: false,
            targetCodec: target,
            processing: processing
        )
    }

    @Test("The cap narrows the encoder's layout; without it 5.1 stays 5.1")
    func channelCap() throws {
        let capped = try makeBridge(channels: 6, processing: .init(maxChannels: 2))
        defer { capped.close() }
        #expect(capped.outputChannelCount == 2)

        let uncapped = try makeBridge(channels: 6, processing: .init())
        defer { uncapped.close() }
        #expect(uncapped.outputChannelCount == 6)

        // A cap wider than the source, or nonsensical, changes nothing.
        let wide = try makeBridge(channels: 2, processing: .init(maxChannels: 6))
        defer { wide.close() }
        #expect(wide.outputChannelCount == 2)
        let zero = try makeBridge(channels: 6, processing: .init(maxChannels: 0))
        defer { zero.close() }
        #expect(zero.outputChannelCount == 6)
    }

    @Test("A night-mode bridge keeps the source anchor and monotonic timestamps")
    func nightModePipeline() throws {
        guard DialogueBoostFilter.isNightModeAvailable else { return }
        let bridge = try makeBridge(channels: 6, processing: .init(nightMode: true, maxChannels: 2))
        defer { bridge.close() }
        #expect(bridge.routeDescription.contains("night mode"))
        #expect(bridge.outputChannelCount == 2)

        let startPTS: Int64 = 96_000
        var timestamps: [Int64] = []
        for index in 0..<20 {
            let packet = av_packet_alloc()!
            defer { var packet: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&packet) }
            let samples: Int32 = 1_000
            av_new_packet(packet, samples * 6 * 2)
            packet.pointee.data.withMemoryRebound(to: Int16.self, capacity: Int(samples * 6)) {
                for sample in 0..<Int(samples * 6) {
                    $0[sample] = Int16(truncatingIfNeeded: sample * 17)
                }
            }
            packet.pointee.pts = startPTS + Int64(index) * Int64(samples)
            packet.pointee.dts = packet.pointee.pts
            packet.pointee.duration = Int64(samples)
            try bridge.feed(packet) { timestamps.append($0.pointee.pts) }
        }
        try bridge.flush { timestamps.append($0.pointee.pts) }

        #expect(!timestamps.isEmpty, "the night-mode bridge produced no packets")
        #expect(timestamps.first == startPTS, "the compressor must not cost the source anchor")
        #expect(timestamps == timestamps.sorted())
    }

    @Test("Without night mode the route description says nothing about it")
    func plainRouteDescription() throws {
        let bridge = try makeBridge(channels: 2, processing: .init())
        defer { bridge.close() }
        #expect(!bridge.routeDescription.contains("night mode"))
    }
}

/// The option as a host sets it: carried into the session and its clones, and
/// visible in what the master declares.
@Suite("Bridged audio processing sessions", .serialized)
struct BridgedAudioProcessingSessionTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    @Test("The option is kept by the session, a clone and the muxed fallback")
    func optionIsCarried() async throws {
        let processing = BridgedAudioProcessing(nightMode: true, maxChannels: 2)
        let session = try PrismCoreSession(
            url: try fixture("h264_truehd_14s.mkv"), bridgedAudioProcessing: processing
        )
        #expect(await session.options.bridgedAudioProcessing == processing)
        let clone = try await session.makeSession { $0.preferredAudioLanguage = "ces" }
        #expect(await clone.options.bridgedAudioProcessing == processing)
        let fallback = try await clone.makeMuxedFallbackSession()
        #expect(await fallback.options.bridgedAudioProcessing == processing)
    }

    @Test("A stereo cap declares CHANNELS=2 on the bridged TrueHD renditions")
    func capReachesTheMaster() async throws {
        guard AudioBridge.canBridge(codecID: AV_CODEC_ID_TRUEHD) else { return }
        // h264_truehd_14s.mkv: a 5.1 TrueHD default track and a stereo one.
        let session = try PrismCoreSession(
            url: try fixture("h264_truehd_14s.mkv"),
            bridgedAudioProcessing: .init(maxChannels: 2)
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let (masterData, _) = try await URLSession.uncached.data(from: playlist)
        let master = String(decoding: masterData, as: UTF8.self)
        let media = master.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
        #expect(!media.isEmpty)
        for line in media {
            #expect(line.contains("CHANNELS=\"2\""), "\(line)")
        }
    }
}
