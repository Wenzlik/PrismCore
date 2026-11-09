import Foundation
import Testing
import Libavcodec
import Libavformat
@testable import PrismCore

/// Which opens ask the Matroska demuxer to skip attachments, and that asking
/// on a build without `skip_attachments` changes nothing.
///
/// The policy is tested through the pure option builder with `supported`
/// forced, so it holds on any FFmpeg; the linked build (Wenzlik/MPVKit 1.0.2,
/// FFmpeg n8.1.3) is checked separately to really have the option.
struct MatroskaAttachmentSkipTests {

    @Test func defaultFirstOpenDoesNotRequestSkip() {
        #expect(SourceOpenTuning.attachmentOption(role: .first(skipAttachments: false), supported: true) == nil)
        var options = SourceOpenTuning.makeOptions(httpHeaders: [:], attachmentSkipSupported: true)
        defer { av_dict_free(&options) }
        #expect(avMetadataValue(options, SourceOpenTuning.attachmentSkipKey) == nil)
    }

    @Test func optInFirstOpenRequestsSkip() {
        let option = SourceOpenTuning.attachmentOption(role: .first(skipAttachments: true), supported: true)
        #expect(option?.key == "skip_attachments")
        #expect(option?.value == "1")
        var options = SourceOpenTuning.makeOptions(
            httpHeaders: [:], role: .first(skipAttachments: true), attachmentSkipSupported: true
        )
        defer { av_dict_free(&options) }
        #expect(avMetadataValue(options, "skip_attachments") == "1")
    }

    @Test func reopensAlwaysRequestSkip() {
        #expect(SourceOpenTuning.OpenRole.reopen.skipsAttachments)
        #expect(SourceOpenTuning.attachmentOption(role: .reopen, supported: true)?.key == "skip_attachments")
        var options = SourceOpenTuning.makeOptions(httpHeaders: [:], role: .reopen, attachmentSkipSupported: true)
        defer { av_dict_free(&options) }
        #expect(avMetadataValue(options, "skip_attachments") == "1")
    }

    @Test func unsupportedBuildSetsNothing() {
        for role in [SourceOpenTuning.OpenRole.first(skipAttachments: false), .first(skipAttachments: true), .reopen] {
            #expect(SourceOpenTuning.attachmentOption(role: role, supported: false) == nil)
            var options = SourceOpenTuning.makeOptions(httpHeaders: [:], role: role, attachmentSkipSupported: false)
            defer { av_dict_free(&options) }
            // headers absent: reconnect, reconnect_streamed, probesize, analyzeduration.
            #expect(av_dict_count(options) == 4)
        }
    }

    /// The package floor is MPVKit 1.0.2, whose FFmpeg has the option. A
    /// `false` here means an older FFmpeg got linked and every re-open is
    /// back to reading the fonts in full.
    @Test func linkedFFmpegHasTheOption() {
        #expect(SourceOpenTuning.matroskaSkipsAttachments)
    }

    /// The capability must describe the demuxer that actually opens files, not
    /// just an option table: `avformat_open_input` consumes the keys it knows
    /// and hands unknown ones back in the dictionary, so a leftover key would
    /// mean the skip is silently ignored.
    @Test func linkedDemuxerConsumesTheOption() throws {
        let url = try #require(Bundle.module.url(forResource: "h264_aac_srt", withExtension: "mkv", subdirectory: "Fixtures"))
        var options: OpaquePointer?
        av_dict_set(&options, SourceOpenTuning.attachmentSkipKey, "1", 0)
        defer { av_dict_free(&options) }
        var input: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&input, url.path, nil, &options), "avformat_open_input")
        defer { avformat_close_input(&input) }
        let leftover = av_dict_get(options, SourceOpenTuning.attachmentSkipKey, nil, 0) != nil
        #expect(leftover == !SourceOpenTuning.matroskaSkipsAttachments)
    }

    @Test func detectionIsReportedInCapabilities() {
        #expect(FFmpegBuild.capabilities.skipsMatroskaAttachments == SourceOpenTuning.matroskaSkipsAttachments)
        #expect(FFmpegBuild.summary.contains("mkv attachment skip:"))
    }

    /// A re-open that skipped attachments must still match the first open's
    /// streams: trailing attachment streams are ignored, others are not.
    @Test func streamSignaturesIgnoreOnlyTrailingAttachments() {
        func signature(_ type: AVMediaType) -> HLSRemuxer.StreamSignature {
            .init(mediaType: type, codecID: AV_CODEC_ID_NONE, timeBaseNum: 1, timeBaseDen: 1000,
                  isAttachment: type == AVMEDIA_TYPE_ATTACHMENT)
        }
        let tracks = [signature(AVMEDIA_TYPE_VIDEO), signature(AVMEDIA_TYPE_AUDIO), signature(AVMEDIA_TYPE_SUBTITLE)]
        let withFonts = tracks + [signature(AVMEDIA_TYPE_ATTACHMENT), signature(AVMEDIA_TYPE_ATTACHMENT)]
        #expect(HLSRemuxer.trimmingTrailingAttachments(withFonts) == tracks)
        #expect(HLSRemuxer.trimmingTrailingAttachments(tracks) == tracks)

        let interleaved = [signature(AVMEDIA_TYPE_VIDEO), signature(AVMEDIA_TYPE_ATTACHMENT), signature(AVMEDIA_TYPE_AUDIO)]
        #expect(HLSRemuxer.trimmingTrailingAttachments(interleaved) == interleaved)
    }

    /// Matroska turns an image attachment into a VIDEO stream with
    /// `AV_DISPOSITION_ATTACHED_PIC`; it vanishes under `skip_attachments`
    /// like a font does, so a re-open without it must still match.
    @Test func streamSignaturesIgnoreTrailingAttachedPictures() {
        func signature(_ type: AVMediaType, attachment: Bool = false) -> HLSRemuxer.StreamSignature {
            .init(mediaType: type, codecID: AV_CODEC_ID_NONE, timeBaseNum: 1, timeBaseDen: 1000, isAttachment: attachment)
        }
        let tracks = [signature(AVMEDIA_TYPE_VIDEO), signature(AVMEDIA_TYPE_AUDIO)]
        let cover = signature(AVMEDIA_TYPE_VIDEO, attachment: true)
        let font = signature(AVMEDIA_TYPE_ATTACHMENT, attachment: true)
        #expect(HLSRemuxer.trimmingTrailingAttachments(tracks + [cover]) == tracks)
        #expect(HLSRemuxer.trimmingTrailingAttachments(tracks + [font, cover, font]) == tracks)

        // A real video track after an attached picture keeps everything.
        let coverFirst = [signature(AVMEDIA_TYPE_AUDIO), cover, signature(AVMEDIA_TYPE_VIDEO)]
        #expect(HLSRemuxer.trimmingTrailingAttachments(coverFirst) == coverFirst)
    }

    /// Opting in must be invisible on a file without attachments: same
    /// streams, same packets. The fixture has none, so this holds whether or
    /// not the linked demuxer honours the skip.
    @Test func optInLeavesTracksAndPacketsUnchanged() throws {
        let url = try #require(Bundle.module.url(forResource: "h264_aac_srt", withExtension: "mkv", subdirectory: "Fixtures"))
        let plain = try snapshot(SourceProbe.open(url: url))
        let skipped = try snapshot(SourceProbe.open(url: url, skipAttachments: true))
        #expect(!plain.streams.isEmpty)
        #expect(!plain.packets.isEmpty)
        #expect(plain.streams == skipped.streams)
        #expect(plain.streamCount == skipped.streamCount)
        #expect(plain.packets == skipped.packets)
    }

    private struct Packet: Equatable {
        let streamIndex: Int32
        let pts: Int64
        let size: Int32
    }

    private func snapshot(_ probed: ProbedSource) throws
        -> (streams: [HLSRemuxer.StreamSignature], streamCount: UInt32, packets: [Packet]) {
        let context = try #require(probed.consumeContext())
        defer {
            withExtendedLifetime(probed.interruptGuard) {
                var closing: UnsafeMutablePointer<AVFormatContext>? = context
                avformat_close_input(&closing)
            }
        }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        var packets: [Packet] = []
        while packets.count < 64, av_read_frame(context, pkt) >= 0 {
            packets.append(Packet(streamIndex: pkt.pointee.stream_index, pts: pkt.pointee.pts, size: pkt.pointee.size))
            av_packet_unref(pkt)
        }
        return (HLSRemuxer.streamSignatures(of: context), context.pointee.nb_streams, packets)
    }
}
