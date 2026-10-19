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
    /// TrueHD Atmos as 7.1.4, served as APAC: heights included, derived from
    /// the stream's 7.1 presentation by where its objects lie. Lossy where the
    /// bed bridge can be lossless — the trade the host opted into.
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
/// `.heights` builds 7.1.4 out of the stream's own 7.1 presentation (the bed
/// `.lossless` plays): truehdd's decoder decodes it and the Atmos presentation,
/// each 7.1 channel is split per frequency bin between ear level and the
/// heights by where the objects' energy lies (positions read as points; no
/// object signal reaches an output), each channel's level is matched to what the
/// objects put into it, and the result is encoded as Apple Positional Audio
/// (OS 26). TrueHD only — DTS:X is not rendered. Whatever stops it before the
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
