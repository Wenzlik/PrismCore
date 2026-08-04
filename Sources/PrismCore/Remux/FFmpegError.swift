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
