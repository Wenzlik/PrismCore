import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// libass renderers for every ASS/SSA stream of one opened source, sharing
/// one `ASS_Library` loaded with the container's font attachments. Built
/// once, when the demux context is first read (`SubtitleRenditionSet
/// .prepare`, the software pipeline's `load`), and only for a host that
/// asked for `ASSRenderingMode.libass` — fonts can be tens of MB.
///
/// Fonts come from the context's attachment streams, which exist only on a
/// first open that did not skip them (`SourceProbe.open(skipAttachments:)`
/// defaults to reading them; a re-open always skips). Without them libass
/// substitutes system faces through CoreText, which is a degraded look, not
/// a failure.
// Safety: `renderers` is immutable after init; each renderer locks itself.
final class ASSTrackSet: @unchecked Sendable {
    private let renderers: [Int32: (renderer: ASSSubtitleRenderer, timeBase: AVRational)]
    let fontCount: Int

    init?(input: UnsafeMutablePointer<AVFormatContext>) {
        var assStreams: [Int32] = []
        var storage: (width: Int, height: Int)?
        for index in 0..<Int(input.pointee.nb_streams) {
            guard let par = input.pointee.streams[index]?.pointee.codecpar.pointee else { continue }
            if par.codec_type == AVMEDIA_TYPE_SUBTITLE, SubtitleRenditionSet.kind(for: par.codec_id) == .ass {
                assStreams.append(Int32(index))
            } else if storage == nil, par.codec_type == AVMEDIA_TYPE_VIDEO,
                      input.pointee.streams[index]!.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0,
                      par.width > 0, par.height > 0 {
                storage = (Int(par.width), Int(par.height))
            }
        }
        guard !assStreams.isEmpty, let library = try? LibassLibrary() else { return nil }

        var fonts = 0
        for index in 0..<Int(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[index], Self.isFontAttachment(stream),
                  let extradata = stream.pointee.codecpar.pointee.extradata,
                  stream.pointee.codecpar.pointee.extradata_size > 0 else { continue }
            // No copy on our side: libass copies, and the context outlives this call.
            let bytes = Data(bytesNoCopy: extradata, count: Int(stream.pointee.codecpar.pointee.extradata_size),
                             deallocator: .none)
            library.addFont(name: avMetadataValue(stream.pointee.metadata, "filename") ?? "attachment\(index)", bytes: bytes)
            fonts += 1
        }
        fontCount = fonts

        var built: [Int32: (renderer: ASSSubtitleRenderer, timeBase: AVRational)] = [:]
        for index in assStreams {
            let stream = input.pointee.streams[Int(index)]!
            let par = stream.pointee.codecpar.pointee
            let header = par.extradata.map { Data(bytes: $0, count: Int(par.extradata_size)) }
            guard let renderer = try? ASSSubtitleRenderer(header: header, library: library, storageSize: storage)
            else { continue }
            built[index] = (renderer, stream.pointee.time_base)
        }
        guard !built.isEmpty else { return nil }
        renderers = built
    }

    /// Matroska tags fonts by MIME type, and real files use every spelling
    /// there is; the file extension and FFmpeg's own codec guess back it up.
    static func isFontAttachment(_ stream: UnsafeMutablePointer<AVStream>) -> Bool {
        let par = stream.pointee.codecpar.pointee
        guard par.codec_type == AVMEDIA_TYPE_ATTACHMENT else { return false }
        if par.codec_id == AV_CODEC_ID_TTF || par.codec_id == AV_CODEC_ID_OTF { return true }
        let mime = avMetadataValue(stream.pointee.metadata, "mimetype")?.lowercased() ?? ""
        if mime.hasPrefix("font/") || mime.contains("truetype") || mime.contains("opentype")
            || mime.contains("font-sfnt") || mime.contains("x-font") { return true }
        let name = avMetadataValue(stream.pointee.metadata, "filename")?.lowercased() ?? ""
        return [".ttf", ".otf", ".ttc", ".otc"].contains { name.hasSuffix($0) }
    }

    var streamIndices: [Int] { renderers.keys.map(Int.init).sorted() }

    func renderer(streamIndex: Int) -> ASSSubtitleRenderer? {
        renderers[Int32(truncatingIfNeeded: streamIndex)]?.renderer
    }

    /// One packet of an ASS stream, on the source axis. Packets of any other
    /// stream are ignored, so a caller need not filter.
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let entry = renderers[packet.pointee.stream_index],
              packet.pointee.pts != swift_AV_NOPTS_VALUE(),
              let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let tick = av_q2d(entry.timeBase)
        let duration = packet.pointee.duration > 0
            ? Double(packet.pointee.duration) * tick : WebVTTRenditionWriter.fallbackCueSeconds
        entry.renderer.appendEvent(
            Data(bytesNoCopy: data, count: Int(packet.pointee.size), deallocator: .none),
            start: Double(packet.pointee.pts) * tick, duration: duration
        )
    }

    func setTimelineOrigin(_ seconds: Double) {
        for entry in renderers.values { entry.renderer.setTimelineOrigin(seconds) }
    }
}
