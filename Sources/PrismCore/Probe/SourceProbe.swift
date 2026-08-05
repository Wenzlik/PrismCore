import Foundation
import Libavformat
import Libavcodec
import Libavutil

// MARK: - Value types

/// How a variant's dynamic range is declared to AVPlayer. The raw values are
/// exactly the `VIDEO-RANGE` attribute values HLS defines, so the playlist
/// builder can print them directly.
public enum DynamicRange: String, Sendable, Equatable {
    case sdr = "SDR"
    /// HDR10 and every Dolby Vision profile whose base layer is PQ.
    case pq = "PQ"
    case hlg = "HLG"
}

/// The `hvcC` profile_tier_level fields, which are the only honest source for
/// an HEVC `CODECS` string.
///
/// `AVCodecParameters.profile` / `.level` alone cannot produce one: they carry
/// no tier flag, no profile space and — critically — no
/// `general_profile_compatibility_flags`, the element AVPlayer checks the
/// declaration against. So we read the record itself.
public struct HEVCConfigurationRecord: Sendable, Equatable {
    /// `general_profile_space`, 0…3 (printed as the '', 'A', 'B', 'C' prefix).
    public let profileSpace: UInt8
    /// `general_tier_flag`: 0 = Main tier ('L'), 1 = High tier ('H').
    public let tierFlag: UInt8
    /// `general_profile_idc`: 1 = Main, 2 = Main10, 4 = Rext, …
    public let profileIDC: UInt8
    /// `general_profile_compatibility_flags`, stored order (NOT reversed).
    /// A real Main10 record stores `0x20000000`.
    public let profileCompatibilityFlags: UInt32
    /// `general_constraint_indicator_flags`: 48 bits, right-aligned in the
    /// `UInt64` (byte 0 of the 6 is the most significant of the low 48).
    public let constraintIndicatorFlags: UInt64
    /// `general_level_idc` = level × 30 (L4.0 = 120, L5.1 = 153).
    public let levelIDC: UInt8

    public init(
        profileSpace: UInt8,
        tierFlag: UInt8,
        profileIDC: UInt8,
        profileCompatibilityFlags: UInt32,
        constraintIndicatorFlags: UInt64,
        levelIDC: UInt8
    ) {
        self.profileSpace = profileSpace
        self.tierFlag = tierFlag
        self.profileIDC = profileIDC
        self.profileCompatibilityFlags = profileCompatibilityFlags
        self.constraintIndicatorFlags = constraintIndicatorFlags
        self.levelIDC = levelIDC
    }

    /// Parses an ISO 14496-15 `HEVCDecoderConfigurationRecord` (the `hvcC` /
    /// `hev1` box payload, which is what libavformat hands us as HEVC
    /// `extradata` for MP4- and Matroska-sourced streams).
    ///
    /// Returns `nil` for anything else — most importantly Annex-B extradata
    /// (MPEG-TS sources, where the parameter sets arrive in band). Deriving a
    /// PTL from Annex-B means parsing the SPS, which phase 4 deliberately does
    /// not do: without a record we simply have no HEVC `CODECS` string, and
    /// the caller routes media-direct instead of guessing one.
    public static func parse(hvcC data: Data) -> HEVCConfigurationRecord? {
        // configurationVersion(1) + PTL(12) + … + numOfArrays: 23 bytes of
        // fixed header before the parameter-set arrays begin.
        guard data.count >= 23 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 1 else { return nil }

        let ptl = bytes[1]
        var constraints: UInt64 = 0
        for index in 6...11 {
            constraints = (constraints << 8) | UInt64(bytes[index])
        }
        return HEVCConfigurationRecord(
            profileSpace: (ptl & 0xC0) >> 6,
            tierFlag: (ptl & 0x20) >> 5,
            profileIDC: ptl & 0x1F,
            profileCompatibilityFlags: (UInt32(bytes[2]) << 24) | (UInt32(bytes[3]) << 16)
                | (UInt32(bytes[4]) << 8) | UInt32(bytes[5]),
            constraintIndicatorFlags: constraints,
            levelIDC: bytes[12]
        )
    }
}

/// The three `avcC` bytes an H.264 `CODECS` string is made of.
///
/// The HEVC story above needs the whole profile_tier_level; H.264 needs exactly
/// `AVCProfileIndication`, `profile_compatibility` and `AVCLevelIndication`,
/// which is what `avc1.PPCCLL` prints. Read from the record rather than from
/// `AVCodecParameters.profile`/`.level` for the same reason: the compatibility
/// byte (constraint_set flags) exists nowhere else, and AVPlayer checks the
/// declaration against the init segment's own `avcC`.
public struct AVCConfigurationRecord: Sendable, Equatable {
    /// `AVCProfileIndication`: 66 = Baseline, 77 = Main, 100 = High.
    public let profileIDC: UInt8
    /// `profile_compatibility`, the constraint_set flags byte.
    public let profileCompatibility: UInt8
    /// `AVCLevelIndication` = level × 10 (L4.0 = 40, L5.1 = 51).
    public let levelIDC: UInt8

    public init(profileIDC: UInt8, profileCompatibility: UInt8, levelIDC: UInt8) {
        self.profileIDC = profileIDC
        self.profileCompatibility = profileCompatibility
        self.levelIDC = levelIDC
    }

    /// Parses an ISO 14496-15 `AVCDecoderConfigurationRecord` (the `avcC` box
    /// payload, which is what libavformat hands us as H.264 `extradata` for
    /// MP4- and Matroska-sourced streams).
    ///
    /// `nil` for Annex-B extradata (MPEG-TS), exactly like the `hvcC` parse:
    /// without a record there is no honest `CODECS` string, and the caller
    /// routes media-direct instead of guessing one.
    public static func parse(avcC data: Data) -> AVCConfigurationRecord? {
        // configurationVersion(1) + the three PTL bytes + lengthSizeMinusOne.
        guard data.count >= 5 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 1 else { return nil }
        return AVCConfigurationRecord(
            profileIDC: bytes[1],
            profileCompatibility: bytes[2],
            levelIDC: bytes[3]
        )
    }
}

/// The container's `AVDOVIDecoderConfigurationRecord` (the `dvcC` / `dvvC`
/// box), which is what decides the whole DV signaling route.
public struct DolbyVisionConfiguration: Sendable, Equatable {
    public let versionMajor: UInt8
    public let versionMinor: UInt8
    /// `dv_profile`: 5, 7, 8, … (the *major* profile only).
    public let profile: UInt8
    /// `dv_level`: the DV level, printed zero-padded in the codec tag.
    public let level: UInt8
    public let rpuPresent: Bool
    public let enhancementLayerPresent: Bool
    public let baseLayerPresent: Bool
    /// `dv_bl_signal_compatibility_id` — the sub-profile: 1 = HDR10 base
    /// (8.1), 2 = SDR/Rec.709 base (8.2), 4 = HLG base (8.4), 6 = Blu-ray
    /// HDR10 base. Zero for the profiles that have no base layer (5).
    public let baseLayerSignalCompatibilityID: UInt8

    public init(
        versionMajor: UInt8,
        versionMinor: UInt8,
        profile: UInt8,
        level: UInt8,
        rpuPresent: Bool,
        enhancementLayerPresent: Bool,
        baseLayerPresent: Bool,
        baseLayerSignalCompatibilityID: UInt8
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.profile = profile
        self.level = level
        self.rpuPresent = rpuPresent
        self.enhancementLayerPresent = enhancementLayerPresent
        self.baseLayerPresent = baseLayerPresent
        self.baseLayerSignalCompatibilityID = baseLayerSignalCompatibilityID
    }

    /// "5", "8.1", "8.4", "7" — the human profile name used in logs and in
    /// routing decisions.
    public var profileName: String {
        baseLayerSignalCompatibilityID == 0
            ? "\(profile)"
            : "\(profile).\(baseLayerSignalCompatibilityID)"
    }

    /// True for profiles whose base layer no Apple platform can present as DV
    /// *and* whose base is not even HDR: 8.2 carries a Rec.709 base, so the
    /// only honest signaling is plain `hvc1` SDR — no supplemental codec, no
    /// DV, on any display.
    public var hasSDRCompatibleBase: Bool {
        profile == 8 && baseLayerSignalCompatibilityID == 2
    }

    /// Profile 5 has no base layer at all (IPT-PQ), so it is either presented
    /// as DV or not at all.
    public var isSingleLayerDVOnly: Bool { profile == 5 }

    /// Profile 7 is dual-layer; Apple has no decoder for it. Phase 4's
    /// groundwork only *reports* it — the live RPU conversion to 8.1 is the
    /// next step.
    public var isDualLayer: Bool { profile == 7 }
}

/// What the native (HLS-fMP4 + AVPlayer) path can do with a stream.
public enum StreamCopyability: String, Sendable, Equatable {
    /// Rides the fMP4 pipeline untouched.
    case streamCopy
    /// Needs the phase-3 audio bridge (TrueHD / DTS family → EAC3).
    case requiresAudioBridge
    /// Neither: this source has to keep going to Prism/libmpv for now.
    case unsupported
}

public struct VideoTrackInfo: Sendable, Equatable {
    public let streamIndex: Int
    public let codecName: String
    public let profileName: String?
    /// `AVCodecParameters.profile` / `.level` as libavcodec reports them.
    public let profile: Int32
    public let level: Int32
    public let width: Int
    public let height: Int
    /// Luma bit depth from the pixel format, `nil` if the format is unknown.
    public let bitDepth: Int?
    public let colorPrimariesName: String?
    public let colorTransferName: String?
    public let colorSpaceName: String?
    public let isBT2020: Bool
    public let frameRate: Double?
    public let frameRateSource: FrameRateSource
    public let hevcConfiguration: HEVCConfigurationRecord?
    /// The `avcC` bytes, for H.264 sources (`nil` for anything else).
    public let avcConfiguration: AVCConfigurationRecord?
    /// How many bytes each NAL unit's length prefix occupies in this stream's
    /// packets (`lengthSizeMinusOne + 1`), read from the configuration record.
    ///
    /// Needed by anything that has to walk the packets' NAL units rather than
    /// pass them through — today that is the Profile 7 → 8.1 RPU conversion.
    /// `nil` for Annex-B sources and non-HEVC/AVC codecs, which is also exactly
    /// when that conversion can't run.
    public let nalUnitLengthSize: Int?
    public let dolbyVision: DolbyVisionConfiguration?
    public let dynamicRange: DynamicRange
    public let copyability: StreamCopyability

    public enum FrameRateSource: String, Sendable, Equatable {
        case averageFrameRate
        case realFrameRate
        case unknown
    }
}

public struct AudioTrackInfo: Sendable, Equatable {
    public let streamIndex: Int
    public let codecName: String
    public let profileName: String?
    public let channelCount: Int
    public let channelLayoutDescription: String?
    public let sampleRate: Int
    public let language: String?
    public let title: String?
    public let copyability: StreamCopyability
}

public struct SubtitleTrackInfo: Sendable, Equatable {

    /// What PrismCore can do with the track.
    public enum Kind: String, Sendable, Equatable {
        /// Text codec (SubRip / ASS / SSA / WebVTT / mov_text): carried as a
        /// WebVTT `SUBTITLES` rendition, so it survives PiP and AirPlay.
        case textRendition
        /// Bitmap codec (PGS / DVB / DVD / XSUB) or teletext: **not** carried.
        /// Reported so the host can render it in its own overlay — a rendition
        /// would need OCR, which phase 6 doesn't ship.
        case bitmapHostOnly
        /// Something we neither convert nor recognize as bitmap.
        case unsupported
    }

    public let streamIndex: Int
    public let codecName: String
    public let language: String?
    public let title: String?
    public let kind: Kind
    public let isDefault: Bool
    public let isForced: Bool
    public let isHearingImpaired: Bool
}

/// Everything Aether's engine routing needs to decide PrismCore vs Prism, and
/// everything `MasterPlaylistBuilder` needs to sign the manifest — read in one
/// libavformat open.
public struct SourceInfo: Sendable, Equatable {
    public let formatName: String
    /// Source duration in seconds; `nil` when the container doesn't know
    /// (some live ingests).
    public let duration: Double?
    public let video: VideoTrackInfo?
    public let audioTracks: [AudioTrackInfo]
    /// Every subtitle stream, text and bitmap alike — the bitmap ones are
    /// reported precisely because PrismCore does *not* carry them (phase 6),
    /// and the host has to know they exist to offer them in its own overlay.
    public let subtitleTracks: [SubtitleTrackInfo]

    /// Explicit so `subtitleTracks` could be added without breaking callers
    /// that predate it.
    public init(
        formatName: String,
        duration: Double?,
        video: VideoTrackInfo?,
        audioTracks: [AudioTrackInfo],
        subtitleTracks: [SubtitleTrackInfo] = []
    ) {
        self.formatName = formatName
        self.duration = duration
        self.video = video
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
    }

    /// Text subtitle tracks PrismCore turns into WebVTT renditions.
    public var textSubtitleTracks: [SubtitleTrackInfo] {
        subtitleTracks.filter { $0.kind == .textRendition }
    }

    /// Bitmap subtitle tracks the host has to render itself.
    public var bitmapSubtitleTracks: [SubtitleTrackInfo] {
        subtitleTracks.filter { $0.kind == .bitmapHostOnly }
    }

    /// The single question the router asks: can PrismCore take this source
    /// today?
    ///
    /// `.streamCopy` when video and at least one audio track copy as-is,
    /// `.requiresAudioBridge` when video copies but every audio track needs
    /// the phase-3 encoder, `.unsupported` when the video itself can't ride
    /// the pipeline (VP9, MPEG-2, …).
    public var nativeReadiness: StreamCopyability {
        guard let video, video.copyability == .streamCopy else { return .unsupported }
        if audioTracks.isEmpty { return .streamCopy }
        if audioTracks.contains(where: { $0.copyability == .streamCopy }) { return .streamCopy }
        if audioTracks.contains(where: { $0.copyability == .requiresAudioBridge }) {
            return .requiresAudioBridge
        }
        return .unsupported
    }

    /// The first stream-copyable audio track, i.e. the one the v0 remuxer
    /// would pick (an AC3 compat track beats a DTS main track).
    public var preferredCopyableAudioTrack: AudioTrackInfo? {
        audioTracks.first { $0.copyability == .streamCopy }
    }
}

// MARK: - Probe

/// Opens a URL with libavformat and reports it. Read-only and one-shot: no
/// muxer, no output, nothing left running — the router calls this *before*
/// deciding which engine gets the source, so it must be cheap and total.
public enum SourceProbe {

    public enum Failure: Error {
        case openFailed(Error)
        case noStreams
    }

    /// Codecs AVPlayer's HLS-fMP4 pipeline accepts via stream-copy.
    /// Deliberately the same sets `HLSRemuxer` enforces — the probe's verdict
    /// has to match what the remuxer will actually accept.
    private static let copyableVideo: Set<AVCodecID> = [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC]
    private static let copyableAudio: Set<AVCodecID> = [
        AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3,
        AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC,
    ]
    /// Lossless/high-bitrate audio the fMP4 pipeline can't carry but the
    /// phase-3 bridge can re-encode to EAC3.
    private static let bridgeableAudio: Set<AVCodecID> = [
        AV_CODEC_ID_TRUEHD, AV_CODEC_ID_DTS, AV_CODEC_ID_MLP,
    ]

    public static func probe(url: URL, httpHeaders: [String: String] = [:]) throws -> SourceInfo {
        var input: UnsafeMutablePointer<AVFormatContext>?

        // Same open pattern as HLSRemuxer: the caller's headers (Plex token,
        // WebDAV authorization) travel on the probe connection too, otherwise
        // a server source would 401 here and get mis-routed as unplayable.
        var openOptions: OpaquePointer?
        defer { av_dict_free(&openOptions) }
        if !httpHeaders.isEmpty {
            let headerBlob = httpHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
            av_dict_set(&openOptions, "headers", headerBlob, 0)
        }
        av_dict_set(&openOptions, "reconnect", "1", 0)
        av_dict_set(&openOptions, "reconnect_streamed", "1", 0)

        let sourceSpec = url.isFileURL ? url.path : url.absoluteString
        do {
            try FFmpegError.check(
                avformat_open_input(&input, sourceSpec, nil, &openOptions),
                "avformat_open_input"
            )
        } catch {
            throw Failure.openFailed(error)
        }
        defer { avformat_close_input(&input) }
        guard let input else { throw Failure.noStreams }

        // Needed for pixel format, color properties and the DV side data —
        // several of them are only filled in after the codec parser has seen
        // real packets.
        try FFmpegError.check(avformat_find_stream_info(input, nil), "avformat_find_stream_info")

        return describe(input: input)
    }

    /// Describe an input that is **already open** (and already through
    /// `avformat_find_stream_info`).
    ///
    /// Exists so `HLSRemuxer` can reuse the probe's per-stream detection —
    /// codecs, copyability, languages, HDR/DV signaling — on the context it
    /// opened for the remux itself, instead of duplicating the reads or opening
    /// the source a second time (a second open on a network source costs a real
    /// round trip and can even hand back different stream indices).
    static func describe(input: UnsafeMutablePointer<AVFormatContext>) -> SourceInfo {
        let formatName = input.pointee.iformat.flatMap { $0.pointee.name }
            .map { String(cString: $0) } ?? "unknown"
        let duration = input.pointee.duration == swift_AV_NOPTS_VALUE()
            ? nil
            : Double(input.pointee.duration) / Double(AV_TIME_BASE)

        var video: VideoTrackInfo?
        var audio: [AudioTrackInfo] = []
        var subtitles: [SubtitleTrackInfo] = []

        // The video track we report is the one the remuxer would select, so
        // routing and remuxing agree on which stream is "the" video.
        let bestVideoIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)

        for index in 0..<Int(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[index] else { continue }
            let par = stream.pointee.codecpar.pointee
            switch par.codec_type {
            case AVMEDIA_TYPE_VIDEO where Int32(index) == bestVideoIndex:
                video = makeVideoInfo(streamIndex: index, stream: stream)
            case AVMEDIA_TYPE_AUDIO:
                audio.append(makeAudioInfo(streamIndex: index, stream: stream))
            case AVMEDIA_TYPE_SUBTITLE:
                subtitles.append(makeSubtitleInfo(streamIndex: index, stream: stream))
            default:
                continue
            }
        }

        return SourceInfo(
            formatName: formatName,
            duration: duration,
            video: video,
            audioTracks: audio,
            subtitleTracks: subtitles
        )
    }

    // MARK: - Per-stream reads

    private static func makeVideoInfo(
        streamIndex: Int,
        stream: UnsafeMutablePointer<AVStream>
    ) -> VideoTrackInfo {
        let par = stream.pointee.codecpar.pointee

        let hevcConfiguration: HEVCConfigurationRecord? = {
            guard par.codec_id == AV_CODEC_ID_HEVC,
                  let extradata = par.extradata, par.extradata_size > 0
            else { return nil }
            let data = Data(bytes: extradata, count: Int(par.extradata_size))
            return HEVCConfigurationRecord.parse(hvcC: data)
        }()

        let avcConfiguration: AVCConfigurationRecord? = {
            guard par.codec_id == AV_CODEC_ID_H264,
                  let extradata = par.extradata, par.extradata_size > 0
            else { return nil }
            let data = Data(bytes: extradata, count: Int(par.extradata_size))
            return AVCConfigurationRecord.parse(avcC: data)
        }()

        // Both configuration records put `lengthSizeMinusOne` in their last two
        // bits, at different offsets: byte 21 of an `hvcC`, byte 4 of an `avcC`.
        let nalUnitLengthSize: Int? = {
            guard let extradata = par.extradata, par.extradata_size > 0 else { return nil }
            let data = Data(bytes: extradata, count: Int(par.extradata_size))
            switch par.codec_id {
            case AV_CODEC_ID_HEVC:
                guard hevcConfiguration != nil else { return nil }
                return HEVCNALUnits.lengthSize(fromHVCC: data)
            case AV_CODEC_ID_H264:
                guard avcConfiguration != nil, data.count > 4 else { return nil }
                return Int(data[4] & 0x03) + 1
            default:
                return nil
            }
        }()

        let dolbyVision = readDolbyVisionConfiguration(stream.pointee.codecpar)

        // Frame rate: avg_frame_rate is the honest average over the whole
        // file; r_frame_rate is the "base" rate the demuxer guessed and only
        // stands in when the average is unset. An HDR master with no
        // FRAME-RATE attribute is filtered out by AVPlayer at master-parse
        // time, so a nil here has to be treated as "do not serve a master".
        let average = stream.pointee.avg_frame_rate
        let real = stream.pointee.r_frame_rate
        let frameRate: Double?
        let frameRateSource: VideoTrackInfo.FrameRateSource
        if average.num > 0, average.den > 0 {
            frameRate = av_q2d(average)
            frameRateSource = .averageFrameRate
        } else if real.num > 0, real.den > 0 {
            frameRate = av_q2d(real)
            frameRateSource = .realFrameRate
        } else {
            frameRate = nil
            frameRateSource = .unknown
        }

        let bitDepth: Int? = {
            guard par.format >= 0,
                  let descriptor = av_pix_fmt_desc_get(AVPixelFormat(rawValue: par.format))
            else { return nil }
            return Int(descriptor.pointee.comp.0.depth)
        }()

        let transfer = par.color_trc
        let dynamicRange: DynamicRange = {
            if let dolbyVision {
                // A Profile 5 stream's container colour tags are routinely
                // unset (its base is IPT-PQ, not a signalable BT.2020
                // transfer), so the profile decides the range, not the tags.
                if dolbyVision.isSingleLayerDVOnly { return .pq }
                if dolbyVision.baseLayerSignalCompatibilityID == 4 { return .hlg }
                if dolbyVision.hasSDRCompatibleBase { return .sdr }
                if dolbyVision.baseLayerSignalCompatibilityID == 1
                    || dolbyVision.baseLayerSignalCompatibilityID == 6 { return .pq }
            }
            if transfer == AVCOL_TRC_SMPTE2084 { return .pq }
            if transfer == AVCOL_TRC_ARIB_STD_B67 { return .hlg }
            return .sdr
        }()

        return VideoTrackInfo(
            streamIndex: streamIndex,
            codecName: codecName(par.codec_id),
            profileName: profileName(par.codec_id, par.profile),
            profile: par.profile,
            level: par.level,
            width: Int(par.width),
            height: Int(par.height),
            bitDepth: bitDepth,
            colorPrimariesName: cString(av_color_primaries_name(par.color_primaries)),
            colorTransferName: cString(av_color_transfer_name(transfer)),
            colorSpaceName: cString(av_color_space_name(par.color_space)),
            isBT2020: par.color_primaries == AVCOL_PRI_BT2020,
            frameRate: frameRate,
            frameRateSource: frameRateSource,
            hevcConfiguration: hevcConfiguration,
            avcConfiguration: avcConfiguration,
            nalUnitLengthSize: nalUnitLengthSize,
            dolbyVision: dolbyVision,
            dynamicRange: dynamicRange,
            copyability: copyableVideo.contains(par.codec_id) ? .streamCopy : .unsupported
        )
    }

    private static func makeAudioInfo(
        streamIndex: Int,
        stream: UnsafeMutablePointer<AVStream>
    ) -> AudioTrackInfo {
        let par = stream.pointee.codecpar.pointee

        let layout: String? = {
            var mutableLayout = par.ch_layout
            var buffer = [CChar](repeating: 0, count: 128)
            let written = av_channel_layout_describe(&mutableLayout, &buffer, buffer.count)
            return written > 0 ? String(cString: buffer) : nil
        }()

        let copyability: StreamCopyability
        if copyableAudio.contains(par.codec_id) {
            copyability = .streamCopy
        } else if bridgeableAudio.contains(par.codec_id) {
            copyability = .requiresAudioBridge
        } else {
            copyability = .unsupported
        }

        return AudioTrackInfo(
            streamIndex: streamIndex,
            codecName: codecName(par.codec_id),
            profileName: profileName(par.codec_id, par.profile),
            channelCount: Int(par.ch_layout.nb_channels),
            channelLayoutDescription: layout,
            sampleRate: Int(par.sample_rate),
            language: avMetadataValue(stream.pointee.metadata, "language"),
            title: avMetadataValue(stream.pointee.metadata, "title"),
            copyability: copyability
        )
    }

    /// Classification comes from `SubtitleRenditionSet`'s own codec sets — the
    /// remuxer decides what it converts, the probe only reports that decision,
    /// so the two can't drift.
    private static func makeSubtitleInfo(
        streamIndex: Int,
        stream: UnsafeMutablePointer<AVStream>
    ) -> SubtitleTrackInfo {
        let par = stream.pointee.codecpar.pointee
        let disposition = stream.pointee.disposition

        let kind: SubtitleTrackInfo.Kind
        if SubtitleRenditionSet.textCodecs.contains(par.codec_id) {
            kind = .textRendition
        } else if SubtitleRenditionSet.bitmapCodecs.contains(par.codec_id) {
            kind = .bitmapHostOnly
        } else {
            kind = .unsupported
        }

        return SubtitleTrackInfo(
            streamIndex: streamIndex,
            codecName: codecName(par.codec_id),
            language: avMetadataValue(stream.pointee.metadata, "language"),
            title: avMetadataValue(stream.pointee.metadata, "title"),
            kind: kind,
            isDefault: disposition & AV_DISPOSITION_DEFAULT != 0,
            isForced: disposition & AV_DISPOSITION_FORCED != 0,
            isHearingImpaired: disposition & AV_DISPOSITION_HEARING_IMPAIRED != 0
        )
    }

    /// Reads `AV_PKT_DATA_DOVI_CONF` off the stream's codec parameters.
    ///
    /// Modern libavformat attaches container side data to
    /// `AVCodecParameters.coded_side_data` (it used to hang off `AVStream`),
    /// and the payload is a straight `AVDOVIDecoderConfigurationRecord` — the
    /// `dvcC`/`dvvC` box the mov/matroska demuxers parse for us.
    private static func readDolbyVisionConfiguration(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>?
    ) -> DolbyVisionConfiguration? {
        guard let codecpar else { return nil }
        let par = codecpar.pointee
        guard let sideData = av_packet_side_data_get(
            par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF
        ) else { return nil }
        guard let raw = sideData.pointee.data,
              sideData.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        else { return nil }

        let record = raw.withMemoryRebound(
            to: AVDOVIDecoderConfigurationRecord.self, capacity: 1
        ) { $0.pointee }

        return DolbyVisionConfiguration(
            versionMajor: record.dv_version_major,
            versionMinor: record.dv_version_minor,
            profile: record.dv_profile,
            level: record.dv_level,
            rpuPresent: record.rpu_present_flag != 0,
            enhancementLayerPresent: record.el_present_flag != 0,
            baseLayerPresent: record.bl_present_flag != 0,
            baseLayerSignalCompatibilityID: record.dv_bl_signal_compatibility_id
        )
    }

    // MARK: - Small C bridges

    private static func codecName(_ id: AVCodecID) -> String {
        cString(avcodec_get_name(id)) ?? "unknown"
    }

    private static func profileName(_ id: AVCodecID, _ profile: Int32) -> String? {
        guard profile != swift_AV_PROFILE_UNKNOWN else { return nil }
        return cString(avcodec_profile_name(id, profile))
    }

    private static func cString(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }

}
