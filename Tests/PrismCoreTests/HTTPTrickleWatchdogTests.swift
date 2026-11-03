import Testing
import Foundation
@testable import PrismCore
import Libavformat

/// The volume half of the coordinated reader's delivery watchdog: a
/// connection that drips is ended like a silent one. The judgement is pure
/// and timed by the caller, so these walk a timeline instead of waiting
/// through one; the one network test runs on shrunken thresholds.
@Suite("HTTP trickle watchdog", .serialized)
struct HTTPTrickleWatchdogTests {
    static let standard = TrickleWatchdog.Thresholds(stallPeriod: 15, window: 20, floorBytes: 2 << 20)

    /// 256 KB and then nothing: the silent-connection clock was reset by the
    /// drip, so only volume can end it.
    @Test func dripIsJudgedAfterOneStallPeriod() {
        var watchdog = TrickleWatchdog(thresholds: Self.standard)
        watchdog.readBlocked(at: 0)
        watchdog.delivered(256 << 10, at: 1)
        #expect(!watchdog.judge(at: 14.5))
        #expect(watchdog.judge(at: 15))
        // The reconnect starts with a clean slate, not with the old verdict.
        watchdog.readBlocked(at: 15.5)
        #expect(!watchdog.judge(at: 16))
    }

    /// Starvation is the sum over many short blocked reads, each fed in
    /// small chunks — no single read is anywhere near a stall period.
    @Test func starvationAccumulatesAcrossSmallReads() {
        var watchdog = TrickleWatchdog(thresholds: Self.standard)
        var firstVerdict: Int?
        for read in 0..<30 {
            let start = Double(read) * 0.625
            watchdog.readBlocked(at: start)
            for chunk in 0..<4 { watchdog.delivered(4096, at: start + 0.0625 * Double(chunk + 1)) }
            if watchdog.judge(at: start + 0.5), firstVerdict == nil { firstVerdict = read }
            watchdog.readUnblocked(at: start + 0.5)
        }
        // 30 reads × 0.5 s blocked = the first 15 s of starvation.
        #expect(firstVerdict == 29)
    }

    /// The same read pattern carrying enough bytes, delivered as many small
    /// pieces, is a stream: the volume has to be summed piece by piece.
    @Test func smallChunksAddUpToAHealthyVolume() {
        var watchdog = TrickleWatchdog(thresholds: Self.standard)
        for read in 0..<30 {
            let start = Double(read) * 0.625
            watchdog.readBlocked(at: start)
            for chunk in 0..<160 { watchdog.delivered(512, at: start + 0.002 * Double(chunk + 1)) }
            #expect(!watchdog.judge(at: start + 0.5))
            watchdog.readUnblocked(at: start + 0.5)
        }
    }

    /// Blocked the whole time but fed well above the floor.
    @Test func healthyStreamIsNeverJudged() {
        var watchdog = TrickleWatchdog(thresholds: Self.standard)
        watchdog.readBlocked(at: 0)
        for second in 1...60 {
            if second % 5 == 0 { watchdog.delivered(1 << 20, at: Double(second)) }
            #expect(!watchdog.judge(at: Double(second)))
        }
    }

    /// A paused player reads nothing, so nothing arrives — and nothing is
    /// being waited for either. Nor does starvation from before the pause
    /// carry over to the first read after it.
    @Test func parkedReaderIsNeverJudged() {
        var watchdog = TrickleWatchdog(thresholds: Self.standard)
        watchdog.readBlocked(at: 0)
        watchdog.readUnblocked(at: 14)
        #expect(!watchdog.judge(at: 100), "no read is pending")
        watchdog.readBlocked(at: 114)
        #expect(!watchdog.judge(at: 115), "the pre-pause starvation left the window")
    }

    /// End to end: the first connection drips, the reader ends it on volume,
    /// keeps the bytes it did get, and the next fill reconnects at full speed.
    @Test func drippingConnectionIsEndedAndReconnected() async throws {
        // Contents only need to be checkable; nothing demuxes here.
        let media = Data((0..<(2 << 20)).map { UInt8($0 % 251) })
        let server = try ScriptedHTTPServer { request in
            let reply = ScriptedHTTPServer.ranged(media, for: request)
            // Only the first fill (from byte zero) drips: ~80 KB/s.
            return request.headers["range"]?.hasPrefix("bytes=0-") == true
                ? .trickle(reply, chunk: 4096, interval: 0.05) : reply
        }
        let url = try await server.start()
        defer { server.stop() }

        let input = HTTPRangeInput(
            url: url.appendingPathComponent("film.mkv"), headers: [:], prewarmStore: nil,
            trickle: .init(stallPeriod: 0.3, window: 0.5, floorBytes: 512 << 10),
            interrupted: { false }
        )
        defer { withExtendedLifetime(input) {} }
        let guardian = ReadInterruptGuard()
        let context = try #require(guardian.makeContext())
        defer { var closing: UnsafeMutablePointer<AVFormatContext>? = context; avformat_close_input(&closing) }
        try input.install(on: context)
        let io = try #require(context.pointee.pb)

        let start = ContinuousClock.now
        var scratch = [UInt8](repeating: 0, count: 256 << 10)
        #expect(avio_read(io, &scratch, Int32(scratch.count)) == Int32(scratch.count))
        // The drip alone would take ~13 s for its 1 MiB block.
        #expect(start.duration(to: .now) < .seconds(5))
        #expect(scratch == Array(media.prefix(scratch.count)), "the kept partial or the refill served wrong bytes")
        #expect(server.requests.count >= 2, "the dripping connection was never replaced")
    }
}
