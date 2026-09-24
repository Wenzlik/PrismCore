import Testing
import Foundation
@testable import PrismCore
import Libavformat

/// The coordinated reader's memory over a long read, on the kind of thread the
/// producer really runs on.
///
/// 3.2.1 built a fresh `URLSession` for every 1 MiB fill and ran on a plain
/// `Thread` that never drains an autorelease pool, so each fill left roughly
/// its own payload behind: ~1.13 MB per fill, linear in bytes played, never
/// returned. An Apple TV playing a 4K remux over the host's range proxy grew
/// to 1.56 GB in under nine minutes and was killed by Jetsam
/// (`vm-pageshortage`). Nothing in the output was wrong, which is why only a
/// footprint assertion can hold the line.
@Suite("HTTP range memory", .serialized)
struct HTTPRangeMemoryTests {
    @Test func manyFillsOnAPoollessThreadKeepTheFootprintFlat() async throws {
        // Twice the reader's retained-bytes bound, so every block visited is
        // evicted before it comes round again and each read below is a fill.
        let blocks = 8
        var media = Data(count: blocks << 20)
        media.withUnsafeMutableBytes { $0.copyBytes(from: (0..<(blocks << 20)).map { UInt8($0 % 251) }) }
        let server = try RangeFixtureServer(media: media, bytesPerSecond: 10_000_000_000, firstByteDelay: 0)
        let url = try await server.start()
        defer { server.stop() }

        let warmUp = 16
        let fills = 256
        let measured = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int64, Int64), Error>) in
            // A bare `Thread`, deliberately — not a Task and not a dispatch
            // queue, both of which drain a pool per work item and would hide
            // exactly the leak this test exists for.
            let thread = Thread {
                let guardian = ReadInterruptGuard()
                guard let context = guardian.makeContext() else {
                    continuation.resume(throwing: CancellationError()); return
                }
                defer { var closing: UnsafeMutablePointer<AVFormatContext>? = context; avformat_close_input(&closing) }
                do { try guardian.installHTTPInput(on: context, url: url, headers: [:]) }
                catch { continuation.resume(throwing: error); return }
                guard let io = context.pointee.pb else { continuation.resume(throwing: CancellationError()); return }
                var scratch = [UInt8](repeating: 0, count: 16)
                var baseline: Int64 = 0
                for fill in 0..<(warmUp + fills) {
                    // The warm-up pays for the one-time costs (URL loading's
                    // own caches, the first connection) so the delta measures
                    // only what each further fill keeps.
                    if fill == warmUp { baseline = Self.footprint() }
                    let offset = Int64(fill % blocks) << 20
                    guard avio_seek(io, offset, SEEK_SET) == offset, avio_read(io, &scratch, 16) == 16 else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                }
                continuation.resume(returning: (baseline, Self.footprint()))
            }
            thread.start()
        }
        #expect(server.requests.count >= warmUp + fills, "every read should have been a fill")
        let growth = Double(measured.1 - measured.0) / 1_048_576
        // 3.2.1 grows ~290 MB over these fills. What is left once the leak is
        // gone is allocator noise and the reader's own 4 MiB of blocks; the
        // bound is loose enough for a busy test process and still an order of
        // magnitude under the leak.
        #expect(growth < 64, "footprint grew \(growth) MB over \(fills) fills")
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
