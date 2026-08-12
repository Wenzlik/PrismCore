import Foundation

/// What the **bitstream** said about object audio on one stream-copied E-AC-3
/// track — as opposed to what the container's metadata claimed.
///
/// The distinction is the whole reason this type exists. `AudioTrackInfo`'s
/// `isObjectAudio` reads `AVCodecParameters.profile`, and libavformat only ever
/// fills that in when `avformat_find_stream_info` happened to decode an audio
/// frame while it was sampling. Nothing guarantees it did. So the claim is a
/// **guess that fails silently in the false direction**: a real Atmos track
/// reported as plain DD+, with no error anywhere.
///
/// PrismCore already reads the truth for its own purposes — `EAC3Syncframe`
/// walks the BSI to find the TS 103 420 `complexity_index_type_a`, because the
/// `dec3` box the muxer writes needs that number. This publishes what that walk
/// found, so a host can state what is playing instead of repeating the guess.
public struct ObjectAudioFinding: Sendable, Equatable {

    /// The source stream this describes.
    public let streamIndex: Int
    /// `complexity_index_type_a` from the first syncframe that answered, or
    /// `nil` when the walk read its whole budget of frames and found no JOC.
    /// Either way the question is **settled**: a finding only exists once the
    /// bitstream has been asked.
    public let complexityIndex: Int?
    /// What the container's metadata claimed before a frame was read. Kept
    /// because the interesting case is the disagreement — and because a host
    /// that logs both learns which sources lie.
    public let claimedByMetadata: Bool

    /// Whether this track really carries Dolby Atmos objects.
    public var isObjectAudio: Bool { complexityIndex != nil }

    /// The metadata said no and the bitstream said yes — the silent failure
    /// this whole mechanism exists to catch.
    public var wasMissedByMetadata: Bool { isObjectAudio && !claimedByMetadata }

    public init(streamIndex: Int, complexityIndex: Int?, claimedByMetadata: Bool) {
        self.streamIndex = streamIndex
        self.complexityIndex = complexityIndex
        self.claimedByMetadata = claimedByMetadata
    }
}
