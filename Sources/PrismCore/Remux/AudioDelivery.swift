import Foundation
import Libavcodec

public enum AudioDelivery: String, Sendable, Equatable {
    case pending, streamCopy, bridged, decoded, noAudioInSource, unavailable
}

/// Counts describe the current bridge epoch (reset by seek), not the file's
/// metadata. Zero output during codec priming is not by itself a failure.
public struct AudioBridgeProgress: Sendable, Equatable {
    public internal(set) var inputPackets = 0
    public internal(set) var decodedFrames = 0
    public internal(set) var resampledSamples = 0
    public internal(set) var outputPackets = 0
    public internal(set) var encoderFrameSamples = 0
    public var awaitingFirstOutput: Bool { inputPackets > 0 && outputPackets == 0 }
}

public enum AudioBridgeFailure: Error, Sendable {
    /// Source packets were supplied, but draining the entire bridge still
    /// delivered no encoded audio. Counters locate the stage that stopped.
    case producedNoAudio(AudioBridgeProgress)
}

public struct AudioTrackDelivery: Sendable, Equatable {
    public let streamIndex: Int
    public internal(set) var delivery: AudioDelivery
    public internal(set) var bridge: AudioBridgeProgress?
    /// What became of Dolby Atmos on this track — the answer behind an
    /// "Atmos" or "Atmos not preserved" label.
    public internal(set) var objectAudio: ObjectAudioDelivery = .none
}

/// Whether a track's Dolby Atmos objects reach the player.
///
/// Two forms of Atmos survive this engine. E-AC-3 + JOC is stream-copied with
/// its `dec3` extension (`.preserved`). TrueHD Atmos is turned — only when the
/// host opts in (`ObjectAudioRendering.heights`) — into 7.1.4 speaker feeds served
/// as Apple Positional Audio (`.renderedHeights`): the heights play, the objects
/// as objects do not. Otherwise TrueHD Atmos and DTS:X are bridged, and the
/// bridge keeps at most the channel bed: FFmpeg decodes TrueHD only up to its
/// 7.1 presentation (the objects are mixed into it, not lost as sound, but their
/// height and placement are). Hosts read this per track instead of inferring it
/// from the codec.
public enum ObjectAudioDelivery: String, Sendable, Equatable {
    /// Nothing found the source track to carry object audio.
    case none
    /// The served rendition carries the objects (`CHANNELS="16/JOC"`).
    case preserved
    /// The source carries objects; the served rendition is their channel bed.
    case notPreserved
    /// TrueHD Atmos as 7.1.4, served as APAC: heights included — its objects
    /// rendered by their metadata, or (for metadata the renderer does not
    /// place) its 7.1 presentation split by where its objects lie. Lossy where
    /// the bed bridge can be lossless — the trade the host opted into.
    case renderedHeights

    /// Evidence first — the bitstream (`ObjectAudioFinding`, the TrueHD major
    /// sync) — and only then the container's claim, which is silent more
    /// often than it is wrong. DTS:X has no bitstream reader yet, so for it
    /// the claim is all there is.
    init(sourceCarriesObjects: Bool, delivery: AudioDelivery) {
        guard sourceCarriesObjects else { self = .none; return }
        self = delivery == .streamCopy ? .preserved : .notPreserved
    }
}

/// Whether a TrueHD Atmos track's objects are rendered into height channels.
///
/// Off by default, and engaged only when the host also says the output plays
/// Atmos (`PrismCoreSession.Options.allowsAtmosOutput`, which Aether maps to the
/// system's Dolby Atmos setting): a route that cannot play it would get a lossy
/// 7.1.4 folded back down, where `.lossless` delivers the 7.1 bed intact.
///
/// `.heights` renders the objects to 7.1.4: truehdd's decoder decodes the Atmos
/// presentation and its object metadata, and the ETSI TS 103 448 panner places
/// each object. Where the render meets metadata it does not place, the stream's
/// own 7.1 presentation (the bed `.lossless` plays) is split per frequency bin
/// between ear level and the heights by where the objects' energy lies,
/// instead. The result is encoded as Apple Positional Audio (OS 26). TrueHD only — DTS:X is not rendered. Whatever stops it before the
/// master is written (an older OS, a build without the `TrueHDObjects` library,
/// a track whose bitstream — read before the master — is not Atmos, a rate
/// other than 48 kHz) leaves the
/// track on the regular bridge; whatever stops it after keeps playing, as the
/// stream's channel bed, and says so (`ObjectAudioDelivery.notPreserved`).
public enum ObjectAudioRendering: String, Sendable, Equatable {
    case off
    case heights

    /// Whether this build and OS can render heights at all: the
    /// `TrueHDObjects` library is linked and the APAC encoder exists.
    public static var isAvailable: Bool {
        guard rendererIsLinked else { return false }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return false }
        return HeightsBridge.encoderExists
    }
}

/// The loudspeaker layout `ObjectAudioRendering.heights` renders TrueHD Atmos into: the
/// layouts with heights that ETSI TS 103 448 (the object renderer's panner) defines and Apple
/// Positional Audio encodes, each served in the channel order of the matching
/// `kAudioChannelLayoutTag_Atmos_*`. Objects are panned onto the layout's own loudspeakers
/// (TS 103 448 tables A.5–A.8) and bed channels routed by its table 6; the 7.1.4 split the
/// renderer falls back to is routed into the layout by the same table. `.atmos7_1_4` is the
/// default and what earlier versions always rendered. 9.1.6 is not offered: TS 103 448 defines
/// no 9.1.6 layout for the panner.
public enum HeightsLayout: String, Sendable, Equatable, CaseIterable {
    /// 8 channels: L R C LFE Ls Rs, top middle left/right.
    case atmos5_1_2 = "5.1.2"
    /// 10 channels: L R C LFE Ls Rs, top front and top rear left/right.
    case atmos5_1_4 = "5.1.4"
    /// 10 channels: L R C LFE, side and rear surrounds, top middle left/right.
    case atmos7_1_2 = "7.1.2"
    /// 12 channels: L R C LFE, side and rear surrounds, top front and top rear left/right.
    case atmos7_1_4 = "7.1.4"

    public var channelCount: Int {
        switch self {
        case .atmos5_1_2: return 8
        case .atmos5_1_4, .atmos7_1_2: return 10
        case .atmos7_1_4: return 12
        }
    }

    /// Whether this build and OS can render heights into this layout: the `TrueHDObjects`
    /// library is linked and this OS's APAC encoder takes the layout.
    public var isAvailable: Bool {
        guard ObjectAudioRendering.rendererIsLinked else { return false }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return false }
        return HeightsBridge.encoderLayouts.contains(self)
    }
}

/// How `ObjectAudioRendering.heights` delivers the rendered layout: Apple Positional Audio (the
/// default, what every earlier version served) or linear PCM.
///
/// **`.lpcm` is experimental** (issue #176): opt-in only, and it may change or go away once it
/// has been tried on a device.
///
/// - `.apac`: lossy, 256 kbps a channel (3.07 Mbit/s for 7.1.4), the codec Apple's HLS
///   authoring spec lists for channels with heights. The choice for AirPlay and any route
///   that is not a local multichannel output.
/// - `.lpcm` (experimental): lossless, the renderer's output as 24-bit integer PCM in an ISO/IEC 23003-5
///   `ipcm` sample entry with its `pcmC` box and a `chnl` box (ISO/IEC 14496-12) naming each
///   channel's ISO/IEC 23091-3 speaker position, in the order of the layout's
///   `kAudioChannelLayoutTag_Atmos_*` — what CoreMedia reads back as that layout's channel
///   labels. `CODECS` is `ipcm`, the sample entry's own code: Apple's HLS authoring spec lists
///   no PCM format at all, so there is no other value to use. 48 kHz × 24 bits × the layout's
///   channels: 9.2 Mbit/s for 5.1.2, 11.5 for 5.1.4 and 7.1.2, 13.8 for 7.1.4. Meant for HDMI
///   and other local outputs.
///
/// **The host decides.** PrismCore cannot reliably tell which route the audio will take, so it
/// never picks `.lpcm` itself. **Playback is not verified anywhere.** Measured on macOS 27 (a
/// Mac mini, stereo output): AVFoundation opens every layout's `ipcm` media, reads the
/// `chnl` back as exactly the layout's `Atmos_*` tag and decodes every channel in place — but
/// AVPlayer refuses to play LPCM whose layout has height channels at all (`'fmt?'`: 5.1.2 at 8
/// channels, while the same 8 channels described as 7.1 play), and anything above 8 channels,
/// in HLS, `.mp4` and `.caf` alike, and 32-bit float (`fpcm`) the same. HDMI carries at most 8
/// channels of LPCM; whether tvOS hands such a track to an AV receiver (as Dolby MAT) or
/// refuses it as macOS does needs an Apple TV and an AVR, and has not been tried. Until it
/// has, `.lpcm` is for that device test, not for users.
public enum HeightsOutput: String, Sendable, Equatable, CaseIterable {
    case apac
    case lpcm

    /// Whether this build and OS can deliver `layout` this way: the `TrueHDObjects` library is
    /// linked, and for `.apac` this OS's encoder takes the layout (`HeightsLayout.isAvailable`).
    /// `.lpcm` needs no encoder.
    public func isAvailable(for layout: HeightsLayout) -> Bool {
        switch self {
        case .apac: return layout.isAvailable
        case .lpcm:
            guard ObjectAudioRendering.rendererIsLinked else { return false }
            guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return false }
            return true
        }
    }
}

/// What the audio bridge encodes TrueHD, DTS, PCM and the other codecs HLS
/// cannot carry into.
public enum BridgedAudioFormat: String, Sendable, Equatable {
    /// EAC3 at 128 kbps per channel, at most 5.1 (AAC 5.1 in a build without
    /// the `eac3` encoder). Bitstream-friendly: a sink that takes only stereo
    /// PCM still gets 5.1 as Dolby Digital Plus.
    case compressed
    /// FLAC with the source's own channels, up to 7.1, at up to 24 bits — a
    /// TrueHD or DTS-HD MA track arrives without loss when its layout is one
    /// FLAC carries (stereo, 5.1, 7.1; another is remixed onto the nearest),
    /// its full 7.1 bed instead of a lossy 5.1 fold-down. AVPlayer hands it to the system as
    /// multichannel PCM, so it suits a route that takes 8 channels (an Apple
    /// TV on HDMI: `AVAudioSession.maximumOutputNumberOfChannels >= 8`);
    /// on a stereo route it is downmixed by the system instead. Falls back to
    /// `.compressed` in a build without the `flac` encoder (`isAvailable`).
    case lossless

    /// Whether this build can deliver it. `.lossless` needs FFmpeg's `flac`
    /// encoder, which every MPVKit build ships; a session asked for it in a
    /// build without one bridges `.compressed`, and its diagnostic report
    /// says so.
    public var isAvailable: Bool {
        self == .compressed || AudioBridge.targetCodec(for: .lossless) == AV_CODEC_ID_FLAC
    }
}

/// Processing applied to audio PrismCore re-encodes — bridged tracks and
/// dialogue-boost renditions. A stream-copied track is never touched: its bits
/// go to the player as the source carried them, which is the point of copying.
/// Rendered heights (`ObjectAudioRendering.heights`) are not affected either.
/// Everything is off by default, and the default leaves the output unchanged.
public struct BridgedAudioProcessing: Sendable, Equatable {
    /// Night mode: gentle downward compression of loud passages (FFmpeg's
    /// `acompressor`, −24 dBFS threshold, 4:1, no make-up gain), so
    /// explosions come down toward the dialogue without anything being raised
    /// into clipping. Skipped, never an error, in a build without the filter
    /// (`isNightModeAvailable`).
    public var nightMode: Bool
    /// The most channels a re-encoded track leaves with — `2` folds 5.1 and
    /// 7.1 to stereo. The resampler downmixes, and the master's `CHANNELS`
    /// declares what the encoder was given. `nil` (or anything below 1)
    /// keeps the encoder's own ceiling.
    public var maxChannels: Int?

    public init(nightMode: Bool = false, maxChannels: Int? = nil) {
        self.nightMode = nightMode
        self.maxChannels = maxChannels
    }

    /// Whether this build has the filter night mode needs.
    public static var isNightModeAvailable: Bool { DialogueBoostFilter.isNightModeAvailable }
}

final class AudioDeliveryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tracks: [Int: AudioTrackDelivery] = [:]
    private var prepared = false
    /// Tracks the probe's metadata called object audio.
    private var objectAudioClaims: Set<Int> = []
    /// What a track's own bitstream said, which overrides the claim.
    private var objectAudioEvidence: [Int: Bool] = [:]
    /// What the heights renderer reported for a track it renders, which
    /// overrides both: it is the one that knows what is playing.
    private var renderedObjectAudio: [Int: ObjectAudioDelivery] = [:]

    var snapshot: [AudioTrackDelivery] {
        lock.withLock {
            tracks.values.sorted { $0.streamIndex < $1.streamIndex }.map { track in
                var track = track
                track.objectAudio = renderedObjectAudio[track.streamIndex] ?? ObjectAudioDelivery(
                    sourceCarriesObjects: objectAudioEvidence[track.streamIndex]
                        ?? objectAudioClaims.contains(track.streamIndex),
                    delivery: track.delivery
                )
                return track
            }
        }
    }

    var summary: AudioDelivery {
        lock.withLock {
            guard prepared else { return .pending }
            guard !tracks.isEmpty else { return .noAudioInSource }
            if tracks.values.contains(where: { $0.delivery == .streamCopy }) { return .streamCopy }
            if tracks.values.contains(where: { $0.delivery == .bridged }) { return .bridged }
            return .unavailable
        }
    }

    func prepare(indexes: [Int], objectAudioClaims: Set<Int> = []) {
        lock.withLock {
            prepared = true
            self.objectAudioClaims = objectAudioClaims
            tracks = Dictionary(uniqueKeysWithValues: indexes.map {
                ($0, AudioTrackDelivery(streamIndex: $0, delivery: .unavailable))
            })
        }
    }

    func update(index: Int, delivery: AudioDelivery, bridge: AudioBridgeProgress? = nil) {
        lock.withLock {
            tracks[index] = AudioTrackDelivery(streamIndex: index, delivery: delivery, bridge: bridge)
        }
    }

    func noteRenderedObjectAudio(index: Int, _ delivery: ObjectAudioDelivery) {
        lock.withLock { renderedObjectAudio[index] = delivery }
    }

    func noteSourceObjectAudio(index: Int, present: Bool) {
        lock.withLock { objectAudioEvidence[index] = present }
    }

    /// What a track's bitstream said, `nil` while it has not answered.
    func objectAudioEvidence(index: Int) -> Bool? {
        lock.withLock { objectAudioEvidence[index] }
    }
}

/// When an audio rendition of the served master is produced — the answer to
/// "what is this session spending CPU on" that `audioTrackDeliveries` (how a
/// track is carried) does not give.
///
/// It exists because the cost is invisible from outside: a bridged rendition
/// is a decode → resample → encode chain, and a UHD remux with four TrueHD /
/// DTS tracks used to run all four for the whole film while one was heard
/// (issue #122, a Vision Pro running hot). The list is what a field log needs
/// to tell an expensive session from a cheap one.
public struct AudioRenditionProduction: Sendable, Equatable {

    public enum Production: String, Sendable, Equatable {
        /// Produced from the first packet: the DEFAULT rendition, and every
        /// stream-copied one (copying costs a muxer, not a codec).
        case eager
        /// Declared in the master; nothing runs until AVPlayer fetches under
        /// its directory, which re-anchors production at the demanded segment.
        case lazy
        /// Not declared at all. Only in the sequential shape, which has no
        /// demand seam to start a lazy rendition from: a bridged or boost
        /// rendition there would have to run for the whole film on the
        /// chance someone picks it.
        case omitted
    }

    /// The source stream the rendition is built from. A dialogue-boost
    /// rendition shares its stream with the DEFAULT rendition.
    public let streamIndex: Int
    /// Set on a dialogue-boost rendition, `nil` on a track's own.
    public let dialogueBoost: DialogueBoostLevel?
    /// Whether the rendition re-encodes (bridge or boost) rather than copies.
    public let encodes: Bool
    public let production: Production

    public init(
        streamIndex: Int, dialogueBoost: DialogueBoostLevel?, encodes: Bool, production: Production
    ) {
        self.streamIndex = streamIndex
        self.dialogueBoost = dialogueBoost
        self.encodes = encodes
        self.production = production
    }

    /// One line for a host's startup log, e.g.
    /// `eager #1; lazy #2 #3 #1/boost-medium #1/boost-high; omitted none`.
    /// A stream index rather than a language: the line is for whoever reads
    /// the log next to the probe's track list, which is indexed the same way.
    public static func summary(_ productions: [AudioRenditionProduction]) -> String {
        func names(_ production: Production) -> String {
            let matching = productions.filter { $0.production == production }
            guard !matching.isEmpty else { return "none" }
            return matching.map { entry in
                "#\(entry.streamIndex)" + (entry.dialogueBoost.map { "/boost-\($0.rawValue)" } ?? "")
            }.joined(separator: " ")
        }
        return "eager \(names(.eager)); lazy \(names(.lazy)); omitted \(names(.omitted))"
    }
}
