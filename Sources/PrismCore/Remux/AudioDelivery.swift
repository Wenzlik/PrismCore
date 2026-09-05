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
