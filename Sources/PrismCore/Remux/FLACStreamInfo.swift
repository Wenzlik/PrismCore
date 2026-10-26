import Foundation

/// The block sizes a FLAC track's STREAMINFO declares — the one field of it the
/// system judges before it plays a sample.
///
/// CoreMedia refuses a FLAC track whose STREAMINFO `min_blocksize` is under 192
/// samples: AudioToolbox will not even open it (`'wht?'` from `afinfo` and
/// `afconvert`). Measured on macOS 27.0.1 with FFmpeg-made fMP4: blocks of 64, 128 and
/// 191 refused, 192 and up opened and decoded, and the same 4096-block file refused once its
/// header's `min_blocksize` alone was patched to 16. The frames themselves are
/// not the problem — a 100-sample final frame under a 4096 header decodes — so
/// it is the declaration that decides. Such a track is decoded and re-encoded
/// instead of stream-copied (`HLSRemuxer.route`).
enum FLACStreamInfo {

    static let coreMediaMinimumBlockSize = 192

    /// `min_blocksize` and `max_blocksize` from FFmpeg's FLAC extradata: the
    /// bare 34-byte STREAMINFO (MP4's `dfLa`), or `fLaC` and a metadata block
    /// header before it (Matroska's CodecPrivate). `nil` when it is neither.
    static func blockSizes(extradata: UnsafeBufferPointer<UInt8>) -> (min: Int, max: Int)? {
        var start = 0
        if extradata.count >= 4, Array(extradata[0..<4]) == Array("fLaC".utf8) {
            // The first metadata block must be STREAMINFO (type 0), 34 bytes long.
            guard extradata.count >= 42, extradata[4] & 0x7F == 0,
                  Int(extradata[5]) << 16 | Int(extradata[6]) << 8 | Int(extradata[7]) == 34
            else { return nil }
            start = 8
        } else if extradata.count < 34 {
            return nil
        }
        let field = { (offset: Int) in Int(extradata[start + offset]) << 8 | Int(extradata[start + offset + 1]) }
        return (field(0), field(2))
    }

    /// Whether CoreMedia takes this track stream-copied. Unreadable extradata
    /// says nothing, so it keeps the copy it always had.
    static func isStreamCopyable(extradata: UnsafePointer<UInt8>?, size: Int32) -> Bool {
        guard let extradata, size > 0,
              let sizes = blockSizes(extradata: UnsafeBufferPointer(start: extradata, count: Int(size)))
        else { return true }
        return sizes.min >= coreMediaMinimumBlockSize
    }
}
