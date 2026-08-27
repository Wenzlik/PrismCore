import Foundation

/// What a provider can answer with for one request path.
public enum ProviderResult: Sendable {
    /// The payload is in hand — the server frames a `Content-Length` response.
    case data(Data, contentType: String)
    /// No such path, and no point waiting for one — `404`.
    case notFound
    /// The payload is still being produced. The server races the resolution
    /// against its slow-serve threshold, so a producer that needs seconds does
    /// not have to lie about it (see `LoopbackHTTPServer` for the framing).
    case pending(PendingResult)
}

/// A `ProviderResult` that hasn't landed yet: an awaitable that eventually
/// yields the terminal answer.
///
/// It is a box rather than a bare `Task` so a provider can hand over whatever
/// it already has — a detached production task, a continuation, an
/// `AsyncStream` drain — without the server caring which.
public struct PendingResult: Sendable {

    private let work: @Sendable () async -> ProviderResult

    public init(_ work: @escaping @Sendable () async -> ProviderResult) {
        self.work = work
    }

    /// Convenience for the common case: the payload is already being produced
    /// by a task somebody else owns.
    public init(task: Task<ProviderResult, Never>) {
        self.init { await task.value }
    }

    /// Await the terminal answer. A `.pending` that resolves to another
    /// `.pending` is followed, but only a few hops — a provider that keeps
    /// deferring forever is a bug, and the server must not hang on it.
    func resolve() async -> ProviderResult {
        var result = await work()
        for _ in 0..<8 {
            guard case .pending(let next) = result else { return result }
            result = await next.work()
        }
        return .notFound
    }
}

/// The server's payload seam. `LoopbackHTTPServer` never touches the filesystem
/// itself: it asks a provider for a path and frames whatever comes back.
///
/// v0 ships `DirectorySegmentProvider` (serve what's on disk, instantly). The
/// demand-driven producer of the seek phase plugs in here instead: it can
/// answer `.pending` for a segment it is about to cut, and the server keeps
/// AVPlayer's watchdog fed on its behalf.
public protocol SegmentProvider: Sendable {
    /// `path` is already normalized: root-relative, percent-decoded, query
    /// stripped, and rejected if it tried to escape (the server does that
    /// before asking).
    func data(forPath path: String) async -> ProviderResult
}

/// Serves one directory, whole files, from disk. The v0 behavior, now behind
/// the seam.
public struct DirectorySegmentProvider: SegmentProvider {

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func data(forPath path: String) async -> ProviderResult {
        let fileURL = root.appendingPathComponent(path)
        // Belt to the server's braces: a symlink or an encoded oddity that
        // survived path normalization still must not read outside the root.
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return .notFound
        }
        // Mapped, not read: the segment's pages come in as the send touches
        // them, instead of a copy into a buffer that is copied again onto the
        // socket. Eviction unlinks the path; a mapping outlives the unlink.
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return .notFound }
        return .data(data, contentType: LoopbackHTTPServer.contentType(for: fileURL))
    }
}
