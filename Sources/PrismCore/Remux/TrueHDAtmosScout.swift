import Foundation
import Libavcodec
import Libavformat

/// Whether each TrueHD track carries Atmos, read off its bitstream BEFORE the master playlist.
///
/// The heights rendition's codec (`apac`) goes into the master before the first packet, and
/// the probe's claim (`AV_PROFILE_TRUEHD_ATMOS`) is only set when `avformat_find_stream_info`
/// managed to decode a TrueHD frame inside its read cap — on a sparsely interleaved UHD remux it
/// silently does not, and a host that asked for heights got the bed with nothing saying why.
/// `TrueHDMajorSync` says it outright from the first restart unit (at least every 128 access
/// units), so the remuxer asks it here, like `ClosedCaptionScout` and for the same reason.
///
/// Run only when heights were asked for and can run, and only for tracks the claim calls
/// non-Atmos (libavcodec sets the Atmos profile only after decoding an Atmos major sync, so a
/// `true` claim is already evidence). It reads from wherever the context is and leaves the read
/// position where it stopped; the remuxer rewinds to the head before the copy loop in every
/// case anyway (`needsRewindToHead`), so this adds reads, never a seek — bounded by
/// `timeBudget`, `byteBudget` and `packetBudget`.
enum TrueHDAtmosScout {

    /// Packets (all streams) the scout may read before giving up on the streams still silent.
    static let packetBudget = 4096
    /// Bytes of source it may read: a restart unit comes every 128 access units, which is a
    /// fraction of this even on a UHD remux's interleave.
    static let byteBudget: Int64 = 8 << 20
    /// Wall clock it may spend. A stalled or slow source must not hold the master back: on
    /// expiry the blocked read is aborted through the context's `ReadInterruptGuard`, the
    /// tracks not yet answered fall back to the probe's claim, and startup carries on.
    static let timeBudget: Duration = .milliseconds(750)

    /// `[stream index: carries Atmos]` for each of `streams` whose major sync was seen within
    /// the budgets. Leaves the read position wherever it stopped and the AVIO error clear.
    static func scan(
        input: UnsafeMutablePointer<AVFormatContext>, streams: Set<Int>,
        interruptGuard: ReadInterruptGuard? = nil,
        packetBudget: Int = packetBudget, byteBudget: Int64 = byteBudget, timeBudget: Duration = timeBudget
    ) -> [Int: Bool] {
        guard !streams.isEmpty else { return [:] }
        var found: [Int: Bool] = [:]
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return [:] }
        let started = ContinuousClock.now
        let startByte = input.pointee.pb.map { avio_tell($0) } ?? 0
        // Without a guard nothing can interrupt a read that blocks, so the clock is checked
        // between reads only; every caller in production passes the context's own guard.
        interruptGuard?.arm(budget: timeBudget)
        var read = 0
        while read < packetBudget, found.count < streams.count,
              ContinuousClock.now - started < timeBudget,
              (input.pointee.pb.map { avio_tell($0) } ?? 0) - startByte < byteBudget,
              av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            read += 1
            let index = Int(packet.pointee.stream_index)
            guard streams.contains(index), found[index] == nil,
                  let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
            if let answer = TrueHDMajorSync.carriesObjectAudio(
                in: UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
            ) {
                found[index] = answer
            }
        }
        interruptGuard?.disarm()
        // An aborted read latches AVERROR_EXIT in the AVIOContext and every later read would
        // return it; the rewind and the copy loop need it gone (as `SegmentPlan.build` does).
        if interruptGuard != nil, let pb = input.pointee.pb, pb.pointee.error < 0 {
            pb.pointee.error = 0
        }
        return found
    }
}
