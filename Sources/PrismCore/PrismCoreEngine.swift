import Foundation

/// The one call that answers *"how do I play this?"* — and hands back something
/// already started.
///
/// PrismCore has two engines with genuinely different shapes, and phase 7 is
/// where that stops being hideable. `PrismCoreSession` is a **service**: it
/// remuxes into HLS-fMP4 and gives the host a playlist URL for its own
/// `AVPlayer`, which keeps PiP, AirPlay, Atmos passthrough and the Dolby Vision
/// handshake. `SoftwarePlaybackPipeline` is a **player**: for containers whose
/// video AVPlayer cannot decode at all there is no URL to hand anywhere, so it
/// owns the decode, the renderers and the clock, and the host gets a layer.
///
/// A host must not have to ask twice, and must not have to re-derive the
/// decision from `SourceProbe` itself — so the decision lives here.
///
/// ## Why not inside `PrismCoreSession`
///
/// The roadmap's phase 7 line says "wire it into `PrismCoreSession`". That would
/// be the worse design and it isn't what this does. A session is built around a
/// work directory, a loopback server, a segmenting remuxer, demand coordination
/// and a disk budget — the software path needs **none** of it. Folding the
/// pipeline in would mean every software-decoded title allocates a temp
/// directory and binds a TCP port it will never use, and `start()` would return
/// a URL that doesn't exist for half its cases. Routing above both engines keeps
/// each one honest about what it owns.
public enum PrismCoreEngine {

    /// A started engine, ready for the host to present.
    public enum Playback: Sendable {
        /// Remux path: point an `AVPlayer` at `playlist` and keep `session`
        /// alive for the playback's life, then `stop()` it. Treat the URL as
        /// opaque — master or media playlist is a property of the source.
        case remux(session: PrismCoreSession, playlist: URL)
        /// Software path: add `pipeline.displayLayer` to a view, then `play()`.
        /// Loaded and paused on return; `stop()` when done.
        case software(pipeline: SoftwarePlaybackPipeline)
    }

    /// Why PrismCore declined a source. Every case means "give this to the
    /// host's other engine" — for Aether, Prism/libmpv — rather than "this file
    /// is broken".
    public enum RoutingFailure: Error, CustomStringConvertible {
        /// libavformat couldn't open or describe the source (an expired token, a
        /// proxy that isn't up yet, genuinely unreadable bytes).
        case probeFailed(underlying: any Error)
        /// No video stream at all. PrismCore is a video path; an audio-only
        /// source belongs to whatever the host plays music with.
        case noVideoStream
        /// The video can't ride the fMP4 pipeline *and* this FFmpeg build has no
        /// decoder for it either. Carries the codec name so a host can log
        /// something a user could act on.
        case noDecoderForVideo(codecName: String)
        /// The engine started but never produced a playable presentation inside
        /// its startup budget.
        case startupFailed(underlying: any Error)

        public var description: String {
            switch self {
            case .probeFailed(let error):
                return "source could not be probed: \(error)"
            case .noVideoStream:
                return "no video stream"
            case .noDecoderForVideo(let name):
                return "no native path and no software decoder for '\(name)'"
            case .startupFailed(let error):
                return "engine failed to start: \(error)"
            }
        }
    }

    /// What was decided, and why — for a host's log line and for tests that want
    /// the decision without paying for the engine.
    public struct Decision: Sendable, Equatable {
        public enum Engine: String, Sendable, Equatable {
            case remux
            case software
        }
        public let engine: Engine
        /// Human-readable justification, e.g. "video vp9 has no native path,
        /// software decoder libvpx-vp9".
        public let reason: String
    }

    /// Whether this build can re-encode non-streamable audio to EAC3.
    ///
    /// Public because it changes what PrismCore can do, and a host that ships
    /// its own FFmpeg build is the one that decides the answer: stock MPVKit has
    /// the ac3/eac3 *decoders* only, so the bridge is unavailable until a fork
    /// configures `--enable-encoder=eac3`.
    public static var isAudioBridgeAvailable: Bool { AudioBridge.isEncoderAvailable }

    // MARK: - Routing

    /// Probe `url` and decide which engine takes it — without starting anything.
    ///
    /// Exposed separately from `open` so a host can log or gate on the decision,
    /// and so the routing rules are testable without standing up a server or a
    /// renderer.
    public static func decide(
        for info: SourceInfo,
        availability: SoftwareDecoderAvailability = .report(),
        isAudioBridgeAvailable: Bool = Self.isAudioBridgeAvailable
    ) throws -> Decision {
        guard let video = info.video else { throw RoutingFailure.noVideoStream }

        switch info.nativeReadiness {
        case .streamCopy:
            // The native path in full: hardware decode, Atmos passthrough, DV.
            // Always preferred when it is available at all.
            return Decision(
                engine: .remux,
                reason: "video \(video.codecName) and audio stream-copy into fMP4"
            )

        case .requiresAudioBridge:
            // Video copies, but every audio track needs the EAC3 encoder. Two
            // honest outcomes, and which is better depends on the build:
            if isAudioBridgeAvailable {
                return Decision(
                    engine: .remux,
                    reason: "video \(video.codecName) copies; audio re-encoded by the bridge"
                )
            }
            // Without the encoder the remux path can only offer silent video.
            // The software path decodes TrueHD/DTS itself — no passthrough, but
            // sound — so it is strictly the better answer here. This is the one
            // place phase 7 improves a case the native path already "handled".
            guard availability.isAvailable(video.codecName) else {
                throw RoutingFailure.noDecoderForVideo(codecName: video.codecName)
            }
            return Decision(
                engine: .software,
                reason: """
                    audio needs the EAC3 encoder this build lacks; decoding \
                    \(video.codecName) + audio in software keeps the sound
                    """
            )

        case .unsupported:
            // The video itself can't ride the pipeline (VP9, MPEG-2, VC-1, …)
            // — or it is verified interlaced, which AVPlayer would display
            // with combing because it never deinterlaces. Either way, this is
            // what phase 7 exists for.
            guard let entry = availability.entry(for: video.codecName), entry.isAvailable else {
                throw RoutingFailure.noDecoderForVideo(codecName: video.codecName)
            }
            if video.fieldOrder.isInterlaced {
                return Decision(
                    engine: .software,
                    reason: """
                        video \(video.codecName) is interlaced \
                        (\(video.fieldOrder.rawValue)); AVPlayer never \
                        deinterlaces, the software path does (bwdif)
                        """
                )
            }
            return Decision(
                engine: .software,
                reason: """
                    video \(video.codecName) has no native path; software decoder \
                    \(entry.decoderName ?? "?")\(entry.supportsVideoToolbox ? " (VideoToolbox)" : "")
                    """
            )
        }
    }

    /// Probe, decide, and start the chosen engine.
    ///
    /// The probe is a real open — a network round trip on a server source — and
    /// starting either engine blocks on I/O, so this is `async` and must not be
    /// called from a context that can't wait.
    ///
    /// - Parameters:
    ///   - display: what the display can present. Only the remux path uses it
    ///     (it gates the HDR and Dolby Vision claims in the master playlist);
    ///     the software path renders into a layer and makes no claims.
    ///   - segmentCacheBytes: remux path only — disk budget for produced
    ///     segments.
    public static func open(
        url: URL,
        httpHeaders: [String: String] = [:],
        display: DisplayCapabilities = .conservative,
        segmentCacheBytes: Int? = 1 << 30
    ) async throws -> Playback {
        // Keep the probe's CONTEXT, not just its answer: the software path
        // adopts it and skips a second open (the remux path still opens its
        // own — see `PrismCoreSession(probed:)` for that half of the story).
        let probed: ProbedSource
        do {
            probed = try SourceProbe.open(url: url, httpHeaders: httpHeaders)
        } catch {
            throw RoutingFailure.probeFailed(underlying: error)
        }
        let info = probed.info

        let decision = try decide(for: info)

        switch decision.engine {
        case .remux:
            do {
                let session = try PrismCoreSession(
                    url: url,
                    httpHeaders: httpHeaders,
                    display: display,
                    segmentCacheBytes: segmentCacheBytes
                )
                return .remux(session: session, playlist: try await session.start())
            } catch {
                throw RoutingFailure.startupFailed(underlying: error)
            }

        case .software:
            return .software(pipeline: try await openSoftware(probed: probed))
        }
    }

    /// Start the software pipeline over an already-probed source — the entry
    /// a host uses when it ran `SourceProbe.open` + `decide` itself (to log
    /// or gate on the decision) and wants the probe's open to count. The
    /// pipeline adopts the context; a `ProbedSource` already consumed
    /// elsewhere makes it open `probed.url` afresh instead.
    ///
    /// Returned loaded and paused, like `open(url:)`'s software case.
    public static func openSoftware(probed: ProbedSource) async throws -> SoftwarePlaybackPipeline {
        do {
            let pipeline = SoftwarePlaybackPipeline()
            // `load` is synchronous and blocking (it rewinds the container and
            // opens both decoders), so it runs off whatever actor called us.
            try await Task.detached(priority: .userInitiated) {
                try pipeline.load(probed: probed)
            }.value
            return pipeline
        } catch {
            throw RoutingFailure.startupFailed(underlying: error)
        }
    }
}
