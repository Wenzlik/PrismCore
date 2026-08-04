import Foundation
import Libavformat
import Libavutil

/// A failed libav* call, carrying the FFmpeg error string.
public struct FFmpegError: Error, CustomStringConvertible {
    public let code: Int32
    public let operation: String

    public var description: String {
        var buffer = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        av_strerror(code, &buffer, buffer.count)
        let message = String(cString: buffer)
        return "\(operation) failed: \(message) (\(code))"
    }

    /// Throw when `code` is a libav* failure (negative).
    @discardableResult
    static func check(_ code: Int32, _ operation: @autoclosure () -> String) throws -> Int32 {
        guard code >= 0 else { throw FFmpegError(code: code, operation: operation()) }
        return code
    }
}

/// `AVERROR(e)` for a POSIX errno — the macro Swift can't import. On Apple
/// platforms libav* negates errno directly, which is what the header does.
func swift_AVERROR(_ errno: Int32) -> Int32 {
    -errno
}

/// `AV_NOPTS_VALUE`, another unimportable macro: the smallest int64. Compared
/// against, never arithmetic'd.
func swift_AV_NOPTS_VALUE() -> Int64 {
    Int64.min
}

/// One value out of an `AVDictionary` (a stream's or format's metadata), or
/// `nil` when the key is absent — or present and empty, which containers do
/// write and which no caller wants to treat as a language tag or a title.
func avMetadataValue(_ dictionary: OpaquePointer?, _ key: String) -> String? {
    guard let dictionary,
          let entry = av_dict_get(dictionary, key, nil, 0),
          let value = entry.pointee.value
    else { return nil }
    let text = String(cString: value)
    return text.isEmpty ? nil : text
}
