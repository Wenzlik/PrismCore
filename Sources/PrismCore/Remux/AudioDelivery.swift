import Foundation

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
}

final class AudioDeliveryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tracks: [Int: AudioTrackDelivery] = [:]
    private var prepared = false

    var snapshot: [AudioTrackDelivery] {
        lock.withLock { tracks.values.sorted { $0.streamIndex < $1.streamIndex } }
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

    func prepare(indexes: [Int]) {
        lock.withLock {
            prepared = true
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
