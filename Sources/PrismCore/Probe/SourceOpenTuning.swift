import Foundation
import Libavformat
import Libavutil

/// How much of a source libavformat may read before it has to answer what is
/// in it — the setting that decides what "opening a file" costs over a network.
///
/// FFmpeg's defaults (5 MB probe, 5 s of analysis) are tuned for containers
/// that hide their structure. The ones PrismCore takes describe themselves in
/// their header: Matroska carries CodecPrivate, MP4 carries the whole `moov`.
/// Measured against a 5.4 GB HEVC/EAC3 remux over HTTP, one open cost
/// **1.31 MB across 3 requests** at the defaults and **0.92 MB** capped — and
/// on a living-room Wi-Fi link to a media server that difference is the
/// visible part of "Preparing…", paid twice because the routing probe and the
/// remuxer each open the source.
///
/// The caps are a *ceiling*, not a target: libavformat stops as soon as it has
/// what it needs, so a well-formed file reads far less than either number.
/// What they bound is the pathological case — sparse audio, junk streams, a
/// container that never settles — where the analysis would otherwise read
/// megabytes to learn nothing new.
public enum SourceOpenTuning {

    /// Bytes libavformat may read while probing the container. Comfortably
    /// past a Matroska header with dozens of tracks, well short of the default.
    public static let probeSizeBytes = 4 << 20

    /// Microseconds of content the analysis may consume. Two seconds covers
    /// audio sparse enough to matter (a 1 s cap loses nothing on this corpus,
    /// but a stream with a long silent lead-in is exactly the case not worth
    /// being clever about).
    public static let analyzeDurationMicroseconds = 2_000_000

    /// How long a probe may spend before it answers with an error instead.
    ///
    /// A probe with no deadline is a playback with no fallback: a server that
    /// accepts the connection and then starves the reads (busy transcoding,
    /// sleeping disk) left the host with neither a verdict nor an error — the
    /// 2026-08-14 field log shows five play attempts over four minutes with
    /// no line from the engine at all, because `avformat_open_input` was
    /// still blocked on the first. Generous on purpose: a healthy probe over
    /// LAN answers in well under a second, so the budget only ever cuts off
    /// sources that were not going to answer.
    public static let probeBudget: Duration = .seconds(10)

    /// How long one network read may wait for its first byte before it counts
    /// as stalled (FFmpeg's `rw_timeout`). A bound on ONE read, not on the
    /// open: a host range proxy fetches each window whole before it writes a
    /// byte, and the slowest remote open in the field took ~13 s in total —
    /// so a single wait past 20 s is a stall, not a slow source.
    static let readStallTimeoutMicroseconds = 20_000_000

    /// FFmpeg's reconnect backoff ceiling. Its delays run 0, 1, 3, 7, … s;
    /// a 4 s ceiling allows the first three reconnects and then answers the
    /// read with an error (the default, 120 s, allows minutes of them).
    static let reconnectDelayMaxSeconds = 4

    /// The options every open should carry: the caller's HTTP headers, the
    /// reconnect policy the demux side needs, and the caps above.
    ///
    /// Returns an owned dictionary — the caller frees it with `av_dict_free`.
    static func makeOptions(
        httpHeaders: [String: String],
        role: OpenRole = .first(skipAttachments: false),
        attachmentSkipSupported: Bool = matroskaSkipsAttachments
    ) -> OpaquePointer? {
        var options: OpaquePointer?
        applyHTTPHeaders(httpHeaders, to: &options)
        if let skip = attachmentOption(role: role, supported: attachmentSkipSupported) {
            av_dict_set(&options, skip.key, skip.value, 0)
        }
        // Reconnect on dropped HTTP connections — the demuxer read side.
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_streamed", "1", 0)
        // A read with no deadline is a seek with no end: without these, a
        // stalled HTTP read (FFmpeg's default `rw_timeout` is infinite)
        // blocked the producer for good, so a seek on a remote source
        // buffered forever and nothing ever reached the host's fallback. Now
        // the stall ends the read, FFmpeg's reconnect tries again (at most
        // three times, its default backoff runs to minutes), and what still
        // fails goes to the producer's own recovery and then to the host.
        av_dict_set(&options, "rw_timeout", String(readStallTimeoutMicroseconds), 0)
        av_dict_set(&options, "reconnect_delay_max", String(reconnectDelayMaxSeconds), 0)
        // Deliberately NOT `multiple_requests=1` (HTTP keep-alive). Measured
        // 2026-08-26 against a Range-capable loopback server, one session
        // start over a 30 s MKV: without it 4 requests on 4 connections;
        // with it 5–6 requests on 2–3 connections — the socket was reused,
        // but a duplicated Range request appeared in two runs of three, so
        // the round trips did not go down, and keep-alive semantics against
        // Plex/Jellyfin/Emby were an untested risk for no measured gain.
        av_dict_set(&options, "probesize", String(probeSizeBytes), 0)
        av_dict_set(&options, "analyzeduration", String(analyzeDurationMicroseconds), 0)
        return options
    }

    static func applyHTTPHeaders(_ httpHeaders: [String: String], to options: inout OpaquePointer?) {
        if !httpHeaders.isEmpty {
            let headerBlob = httpHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
            av_dict_set(&options, "headers", headerBlob, 0)
        }
    }

    // MARK: - Matroska attachments

    /// Which open of a source this is — the one thing that decides whether
    /// its Matroska attachments are worth reading.
    ///
    /// Attachments (ASS fonts, mostly; tens of MB on anime releases) sit in
    /// the header and are read in full before the first packet — measured
    /// at ~11 s over a WAN link. Nothing in the engine reads them, and a
    /// source that is already open has had them read once: every side reader
    /// and re-open after that pays the full cost again for nothing.
    enum OpenRole: Equatable, Sendable {
        /// The first open of a source. Reads attachments unless the host
        /// opted out (`SourceProbe.open(skipAttachments:)`).
        case first(skipAttachments: Bool)
        /// A side reader (preview, late index, segment plan) or a re-open of
        /// a source that was already opened once. Never reads attachments.
        case reopen

        var skipsAttachments: Bool {
            switch self {
            case .first(let skip): skip
            case .reopen: true
            }
        }
    }

    /// The demuxer option that skips attachments, or `nil` when this role
    /// keeps them or the linked FFmpeg does not have the option. Pure, so the
    /// policy is testable on a build that lacks the option.
    ///
    /// Never set when unsupported: an unknown key is left in the dictionary
    /// by `avformat_open_input` and silently ignored, which would be a no-op
    /// pretending to be a feature.
    static func attachmentOption(role: OpenRole, supported: Bool) -> (key: String, value: String)? {
        guard role.skipsAttachments, supported else { return nil }
        return (attachmentSkipKey, "1")
    }

    static let attachmentSkipKey = "skip_attachments"

    /// Whether the linked FFmpeg's Matroska demuxer has `skip_attachments`.
    /// Asked of the demuxer's own option table at runtime, not assumed from a
    /// version: the bundled build (MPVKit 1.0.2, FFmpeg n8.1.3) has it, but a
    /// host may override FFmpeg with an older build that does not, and an
    /// unknown key would be silently ignored rather than fail the open.
    static let matroskaSkipsAttachments: Bool = {
        guard let demuxer = av_find_input_format("matroska"),
              var privClass = demuxer.pointee.priv_class
        else { return false }
        // AV_OPT_SEARCH_FAKE_OBJ: search a class (passed as a pointer to its
        // pointer) without an instance of the demuxer's private context.
        return withUnsafeMutablePointer(to: &privClass) {
            av_opt_find($0, attachmentSkipKey, nil, 0, AV_OPT_SEARCH_FAKE_OBJ) != nil
        }
    }()
}
