import Testing
import Foundation
import Darwin
import Libavformat
@testable import PrismCore

/// The 1.1.1 regression, made unrepeatable: the interrupt guard must be baked
/// into the context at `avformat_open_input` — the blocking reads check the
/// URLContext's copy of the callback, taken at creation — or it bounds
/// nothing (issue #39). The unit tests pin the mechanics and the placement;
/// the transport test proves the bound against a read that actually blocks,
/// which no committed fixture can do on its own — hence the stalling server.
@Suite("ReadInterruptGuard")
struct ReadInterruptGuardTests {

    @Test("Disarmed is the resting state; arming starts the clock; disarming stops it")
    func armDisarm() async throws {
        let guardBox = ReadInterruptGuard()
        #expect(!guardBox.shouldInterrupt)

        guardBox.arm(budget: .zero)
        #expect(guardBox.shouldInterrupt)

        guardBox.disarm()
        #expect(!guardBox.shouldInterrupt)

        // A budget still running must not interrupt.
        guardBox.arm(budget: .seconds(60))
        #expect(!guardBox.shouldInterrupt)
        guardBox.disarm()
    }

    @Test("The probe's context is opened with the guard's callback installed")
    func probeInstallsCallbackAtOpen() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"
        ))
        let probed = try SourceProbe.open(url: fixture)
        let context = try #require(probed.consumeContext())
        defer {
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
        }
        // The opaque pointer is the guard itself — the same object the
        // adopting remuxer arms. If these ever diverge, arming bounds nothing
        // and the bug is back.
        #expect(context.pointee.interrupt_callback.callback != nil)
        #expect(
            context.pointee.interrupt_callback.opaque
                == Unmanaged.passUnretained(probed.interruptGuard).toOpaque()
        )
    }

    @Test("A stalled transport cannot eat more than the index-load budget")
    func stalledIndexLoadAborts() async throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "h264_aac_30s", withExtension: "mkv", subdirectory: "Fixtures"
        ))
        // Serve the head of the file and then hold every read forever: the
        // open succeeds (header and first clusters are inside the prefix),
        // and the index-load seek — Matroska Cues live at the tail — walks
        // straight into the stall. This is the shape of the field case (a
        // 5.4 GB cue-less MKV over SMB, 66 s for one seek), compressed into
        // a fixture: what matters is only that the read BLOCKS.
        let server = try StallingHTTPServer(
            data: Data(contentsOf: fixture), servedPrefixBytes: 384 << 10
        )
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/stalled.mkv"))

        let started = ContinuousClock.now
        enum Outcome { case plan(SegmentPlan?), timedOut }
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                .plan(SegmentPlanProbe.plan(
                    url: url, targetSeconds: 6, indexLoadBudget: .milliseconds(500)
                ))
            }
            // Before the fix this test does not fail, it HANGS — the guard
            // never reached the blocking read. The timeout turns that hang
            // into a failure. Generous: CI machines are slow, and a passing
            // run only needs ~1 s.
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        guard case .plan(let plan) = outcome else {
            Issue.record("index-load seek never returned — the interrupt guard is not reaching the blocking reads")
            return
        }
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(10), "aborting took \(elapsed) against a 0.5 s budget")

        // The abort must degrade, not destroy: the Cues are unreachable, so
        // the only honest plan is uniform — but it must still exist, start at
        // the head, and cover the source.
        let built = try #require(plan)
        #expect(built.basis == .uniform)
        #expect(built.entries.first?.startPTS == 0)
        let covered = built.entries.reduce(0) { $0 + $1.duration }
        #expect(covered > 29, "a 30 s source planned as \(covered)s")
    }
}

/// A deliberately hostile HTTP server: it answers correctly, serves the first
/// `servedPrefixBytes` of the payload, and then never sends another byte —
/// without closing the connection. That is what a dead NAS, a sleeping disk
/// or a saturated link look like to libavformat: not an error, a read that
/// simply does not return.
private final class StallingHTTPServer: @unchecked Sendable {

    let port: UInt16
    private let data: Data
    private let servedPrefix: Int
    private let listenFD: Int32
    private let stopped = NSLock()
    private var isStopped = false

    init(data: Data, servedPrefixBytes: Int) throws {
        self.data = data
        self.servedPrefix = servedPrefixBytes

        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EMFILE) }
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let boundFD = listenFD  // referencing the property would capture self pre-init
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(boundFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else {
            close(listenFD)
            throw POSIXError(.EADDRINUSE)
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = listenFD  // referencing the property would capture self pre-init
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: assigned.sin_port)
        startAccepting()
    }

    private func startAccepting() {
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0, let self else {
                    if client >= 0 { close(client) }
                    return
                }
                Thread.detachNewThread { self.handle(client: client) }
            }
        }
    }

    func stop() {
        stopped.withLock { isStopped = true }
        close(listenFD)
    }

    private func handle(client: Int32) {
        defer { close(client) }
        // The client ABORTING is this server's happy path — without this, the
        // write racing that close raises SIGPIPE and takes the whole test
        // process down (signal 13), not just the connection.
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        // Read the request head. One recv is realistically enough for
        // libavformat's GET, but loop to the blank line to stay honest.
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let read = recv(client, &buffer, buffer.count, 0)
            guard read > 0 else { return }
            request.append(contentsOf: buffer[0..<read])
            if request.count > 64 << 10 { return }
        }

        // "Range: bytes=X-" → offset X; anything else serves from 0.
        var offset = 0
        if let head = String(data: request, encoding: .utf8),
           let rangeLine = head.split(separator: "\r\n").first(where: {
               $0.lowercased().hasPrefix("range:")
           }),
           let bytesPart = rangeLine.split(separator: "=").last,
           let startPart = bytesPart.split(separator: "-").first,
           let start = Int(startPart) {
            offset = min(start, data.count)
        }

        let remaining = data.count - offset
        let header: String
        if offset > 0 {
            header = "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Range: bytes \(offset)-\(data.count - 1)/\(data.count)\r\n"
                + "Content-Length: \(remaining)\r\n"
                + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        } else {
            header = "HTTP/1.1 200 OK\r\n"
                + "Content-Length: \(data.count)\r\n"
                + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        }
        _ = header.withCString { send(client, $0, strlen($0), 0) }

        // The promise is the full payload; the delivery stops at the prefix.
        if offset < servedPrefix {
            data.subdata(in: offset..<min(servedPrefix, data.count)).withUnsafeBytes {
                _ = send(client, $0.baseAddress, $0.count, 0)
            }
        }
        guard servedPrefix < data.count else { return }

        // Now stall: block until the CLIENT gives up. recv returning means
        // the peer closed (an aborted read tears the connection down), which
        // is exactly the release condition.
        var drain = [UInt8](repeating: 0, count: 256)
        while recv(client, &drain, drain.count, 0) > 0 {
            if stopped.withLock({ isStopped }) { return }
        }
    }
}
