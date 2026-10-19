import Testing
import Foundation
@testable import PrismCore

/// Single byte ranges on the loopback server — for a host that proxies it and
/// forwards its own client's `Range`, instead of holding a whole 4K segment in
/// memory to answer one.
@Suite("Loopback byte ranges")
struct LoopbackRangeTests {

    private static let body = Data((0..<1000).map { UInt8($0 % 251) })

    /// `delay == nil` answers at once; otherwise `.pending`, resolving after it.
    private struct Provider: SegmentProvider {
        let delay: Duration?
        func data(forPath path: String) async -> ProviderResult {
            guard let delay else { return .data(LoopbackRangeTests.body, contentType: "video/mp4") }
            return .pending(PendingResult {
                try? await Task.sleep(for: delay)
                return .data(LoopbackRangeTests.body, contentType: "video/mp4")
            })
        }
    }

    private func request(
        _ server: LoopbackHTTPServer, method: String = "GET", headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        let base = try await server.start()
        var request = URLRequest(url: base.appendingPathComponent("seg00000.m4s"))
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.uncached.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    @Test("Range specs resolve per RFC 9110, and anything unparsable is the whole body")
    func parsing() {
        typealias R = LoopbackHTTPServer.ByteRange
        let cases: [(String?, R)] = [
            ("bytes=0-99", .partial(0...99)),
            ("bytes=900-", .partial(900...999)),
            ("bytes=-100", .partial(900...999)),
            ("bytes=-5000", .partial(0...999)),
            ("bytes=990-5000", .partial(990...999)),
            ("bytes=999-999", .partial(999...999)),
            ("bytes=1000-", .unsatisfiable),
            ("bytes=-0", .unsatisfiable),
            (nil, .whole),
            ("bytes=0-1,5-6", .whole),
            ("bytes=abc", .whole),
            ("bytes=5-2", .whole),
            ("items=0-5", .whole),
        ]
        for (header, expected) in cases {
            #expect(LoopbackHTTPServer.byteRange(header, length: 1000) == expected, "\(header ?? "nil")")
        }
        // A zero-length body has no first byte to start at, but a nonzero
        // suffix is satisfiable (RFC 9110 §14.1.2) — by the empty 200.
        #expect(LoopbackHTTPServer.byteRange("bytes=0-", length: 0) == .unsatisfiable)
        #expect(LoopbackHTTPServer.byteRange("bytes=-1", length: 0) == .whole)
    }

    @Test("A single range is a 206 with its Content-Range", arguments: ["bytes=0-99", "bytes=900-", "bytes=-100"])
    func partialContent(range: String) async throws {
        let server = LoopbackHTTPServer(provider: Provider(delay: nil))
        defer { Task { await server.stop() } }
        let (data, response) = try await request(server, headers: ["Range": range])
        guard case .partial(let expected) = LoopbackHTTPServer.byteRange(range, length: Self.body.count) else {
            Issue.record("\(range) did not resolve to a partial range"); return
        }
        #expect(response.statusCode == 206)
        #expect(response.value(forHTTPHeaderField: "Content-Range")
            == "bytes \(expected.lowerBound)-\(expected.upperBound)/1000")
        #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(data == Self.body.subdata(in: expected.lowerBound..<(expected.upperBound + 1)))
    }

    @Test("A range past the end is a 416 naming the length")
    func unsatisfiable() async throws {
        let server = LoopbackHTTPServer(provider: Provider(delay: nil))
        defer { Task { await server.stop() } }
        let (data, response) = try await request(server, headers: ["Range": "bytes=1000-"])
        #expect(response.statusCode == 416)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes */1000")
        #expect(data.isEmpty)
    }

    @Test("No range, multi-range and If-Range get the whole body as a 200")
    func wholeBodyAnswers() async throws {
        let server = LoopbackHTTPServer(provider: Provider(delay: nil))
        defer { Task { await server.stop() } }
        for headers in [[:], ["Range": "bytes=0-1,5-6"], ["Range": "bytes=0-99", "If-Range": "\"x\""]] {
            let (data, response) = try await request(server, headers: headers)
            #expect(response.statusCode == 200, "\(headers)")
            #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
            #expect(data == Self.body, "\(headers)")
        }
    }

    @Test("HEAD ignores Range: the whole body's headers, never a 206 or 416")
    func headIgnoresRange() async throws {
        let server = LoopbackHTTPServer(provider: Provider(delay: nil))
        defer { Task { await server.stop() } }
        for range in ["bytes=10-19", "bytes=1000-"] {
            let (data, response) = try await request(server, method: "HEAD", headers: ["Range": range])
            #expect(response.statusCode == 200, "\(range)")
            #expect(response.value(forHTTPHeaderField: "Content-Length") == "1000")
            #expect(response.value(forHTTPHeaderField: "Content-Range") == nil)
            #expect(data.isEmpty)
        }
    }

    @Test("A segment still being produced: ranged once it lands in time, whole past the threshold")
    func pendingSegments() async throws {
        // Lands inside the slow-serve threshold: the length is known before
        // any header goes out, so the range is honoured.
        let quick = LoopbackHTTPServer(
            provider: Provider(delay: .milliseconds(100)), limits: .init(slowServeThreshold: .seconds(2))
        )
        defer { Task { await quick.stop() } }
        let (partial, partialResponse) = try await request(quick, headers: ["Range": "bytes=0-9"])
        #expect(partialResponse.statusCode == 206)
        #expect(partial == Self.body.prefix(10))

        // Lands after it: the headers had to go before the length existed, so
        // the answer is the whole body, chunked — a correct response to a Range.
        let slow = LoopbackHTTPServer(
            provider: Provider(delay: .milliseconds(900)), limits: .init(slowServeThreshold: .milliseconds(200))
        )
        defer { Task { await slow.stop() } }
        let (whole, wholeResponse) = try await request(slow, headers: ["Range": "bytes=0-9"])
        #expect(wholeResponse.statusCode == 200)
        #expect(wholeResponse.value(forHTTPHeaderField: "Content-Range") == nil)
        #expect(whole == Self.body)
    }
}
