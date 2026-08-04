import Foundation
import Network

/// A minimal HTTP/1.1 file server bound to `127.0.0.1` on an ephemeral port —
/// the loopback half of the remux pipeline. It serves exactly one directory
/// (the remux session's segment dir): the growing playlist, the init segment,
/// and the media segments.
///
/// Deliberately tiny for v0:
/// - `GET` only; anything else is `405`.
/// - Whole-file responses with `Content-Length` (`Range` is ignored — HLS
///   clients fetch whole segments).
/// - `Connection: close` per request. AVPlayer opens parallel connections
///   happily; keep-alive is an optimization for a later phase, not a
///   correctness need.
///
/// One thing v0 already respects from the prior art's war stories: AVPlayer's
/// media watchdog gives a request ~3.5 s to produce response HEADERS before
/// `-12889` failures start accruing. A file server that only serves what
/// exists answers instantly (200 or 404), which is safe; anything smarter
/// (waiting for a segment that is still being produced) must send early
/// headers + chunked transfer — that lands with the demand-driven producer
/// phase.
public actor LoopbackHTTPServer {

    public struct FailedToStart: Error {}

    private let root: URL
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The bound port, available after `start()`.
    public private(set) var port: UInt16 = 0

    public init(root: URL) {
        self.root = root
    }

    /// Bind and listen. Returns the base URL (`http://127.0.0.1:<port>/`).
    @discardableResult
    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        // Loopback only — never reachable off-device.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.adopt(connection) }
        }

        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // Resume-once guard, lock-protected: the state handler runs on
            // the listener queue and a `.failed` can chase a `.ready`.
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: FailedToStart()) }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        listener.stateUpdateHandler = nil
        guard bound != 0 else { throw FailedToStart() }
        port = bound
        return URL(string: "http://127.0.0.1:\(bound)/")!
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    // MARK: - Connections

    private func adopt(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.forget(connection) }
            }
            if case .cancelled = state {
                Task { await self?.forget(connection) }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection, buffered: Data())
    }

    private func forget(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func receiveRequest(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                Task { await self.respond(to: head, on: connection) }
                return
            }
            if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
                Task { await self.forget(connection) }
                return
            }
            self.receiveRequestNonisolated(on: connection, buffered: buffer)
        }
    }

    /// Trampoline so the `receive` callback (nonisolated context) can continue
    /// the read loop without hopping through the actor for every chunk.
    private nonisolated func receiveRequestNonisolated(on connection: NWConnection, buffered: Data) {
        Task { await self.receiveRequest(on: connection, buffered: buffered) }
    }

    // MARK: - Responses

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
        let requestParts = lines.first?.split(separator: " ") ?? []
        guard requestParts.count >= 2 else {
            send(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }
        let method = requestParts[0]
        guard method == "GET" else {
            send(status: "405 Method Not Allowed", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        // Strip the query, decode, and refuse anything that escapes the root.
        let rawPath = String(requestParts[1].split(separator: "?").first ?? "/")
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        guard !relative.isEmpty, !relative.contains("..") else {
            send(status: "404 Not Found", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let fileURL = root.appendingPathComponent(relative)
        guard let body = try? Data(contentsOf: fileURL) else {
            send(status: "404 Not Found", body: Data(), contentType: "text/plain", on: connection)
            return
        }
        send(status: "200 OK", body: body, contentType: Self.contentType(for: fileURL), on: connection)
    }

    private func send(status: String, body: Data, contentType: String, on connection: NWConnection) {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        // The playlist grows while the remux runs — a cached copy is a stale
        // copy. Segments are immutable but tiny-header cheap to refetch.
        response += "Cache-Control: no-store\r\n"
        response += "Connection: close\r\n\r\n"

        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            guard let self else { return }
            Task { await self.forget(connection) }
        })
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mp4", "m4s": return "video/mp4"
        case "vtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }
}

/// Runs its block at most once, under a lock — the resume-once guard for
/// continuation-bridged callbacks (the `ASWebAuthenticationSession.cancel()`
/// lesson: never trust a callback to fire exactly once).
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        let shouldRun: Bool = lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
        if shouldRun { block() }
    }
}
