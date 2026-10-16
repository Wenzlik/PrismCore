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
/// Run only when heights were asked for and can run. It reads from wherever the context is and
/// leaves the read position where it stopped; the remuxer rewinds to the head before the copy
/// loop in every case anyway (`needsRewindToHead`), so this adds reads, never a seek.
enum TrueHDAtmosScout {

    /// Packets (all streams) the scout may read before giving up on the streams still silent.
    static let packetBudget = 4096

    /// `[stream index: carries Atmos]` for each of `streams` whose major sync was seen.
    static func scan(
        input: UnsafeMutablePointer<AVFormatContext>, streams: Set<Int>, packetBudget: Int = packetBudget
    ) -> [Int: Bool] {
        guard !streams.isEmpty else { return [:] }
        var found: [Int: Bool] = [:]
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { return [:] }
        var read = 0
        while read < packetBudget, found.count < streams.count, av_read_frame(input, packet) >= 0 {
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
        return found
    }
}
