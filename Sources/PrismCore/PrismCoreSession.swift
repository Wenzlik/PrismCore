import Foundation

/// One playback session: remux `sourceURL` into HLS-fMP4 on disk and serve it
/// from the loopback. The host plays the returned playlist URL with its own
/// `AVPlayer` — PrismCore v0 is a service, not a player (see README).
///
/// ```swift
/// let session = try PrismCoreSession(url: mkvURL)
/// let playlist = try await session.start()
/// player.replaceCurrentItem(with: AVPlayerItem(url: playlist))
/// …
/// await session.stop()
/// ```
///
/// The URL that comes back is the **master** playlist whenever the source has
/// audio worth carrying as alternate renditions (`master.m3u8`), and the media
/// playlist (`index.m3u8`) when it hasn't — a silent source, or one whose master
/// couldn't be written honestly (see `HLSRemuxer`). Hosts should treat the URL as
/// opaque: the shape is a property of the source, not of the API.
///
/// ## The tvOS playback contract
///
/// On tvOS the panel's HDMI mode has to be programmed **before** AVPlayer sees
/// the playlist — tvOS validates an HDR variant's `VIDEO-RANGE` against the
/// panel's *current* mode, synchronously, so a PQ master handed to an
/// SDR-parked panel fails outright (`-11848`/`-11868`) instead of switching or
/// tone-mapping. The order that works:
///
/// ```swift
/// let playlist = try await session.start()
/// if let choice = await session.displayCriteria {   // 1. program the panel
///     criteriaController.apply(choice)
///     await criteriaController.waitForSwitch()      // 2. let it settle
/// }
/// player.replaceCurrentItem(with: AVPlayerItem(url: playlist))  // 3. then load
/// player.play()
/// ```
///
/// AVKit's `appliesPreferredDisplayCriteriaAutomatically` must be `false` for
/// these sessions: it derives criteria from the chosen variant's format
/// description, which only exists *after* the variant passes the very
/// validation the switch has to precede — and its late write races the one
/// above into a double handshake. `MasterRejection` remains the backstop for
/// the panel states no read can prove (Match Content off on an HDR panel).
public actor PrismCoreSession {

    public enum SessionError: Error {
        /// The remux produced no playable playlist within the startup budget.
        case startupTimedOut(underlying: Error?)
        /// A registration call that only makes sense before `start()` arrived
        /// after it. Silently ignoring it would leave a subtitle track the host
        /// believes exists but that no rendition backs.
        case alreadyStarted
    }

    /// Everything the session was built from, kept verbatim so
    /// `makeMuxedFallbackSession()` can mint a faithful clone. A session is
    /// single-use, so "retry differently" has to mean "a new session with the
    /// same inputs".
    private struct Configuration {
        var url: URL
        var httpHeaders: [String: String]
        var display: DisplayCapabilities
        var segmentCacheBytes: Int?
        var forceMuxedShape: Bool
    }

    private let configuration: Configuration
    /// External subtitle registrations, replayed onto a fallback session.
    private var externalSubtitles: [(url: URL, language: String?, name: String?, isForced: Bool)] = []
    private let workDirectory: URL
    private let server: LoopbackHTTPServer
    private let remuxer: HLSRemuxer
    private var remuxTask: Task<Void, Error>?
    private var started = false

    /// What the Profile 7 → 8.1 conversion did, or `nil` when this source isn't a
    /// converted P7. Populated from the first produced segment onwards, so it can
    /// be read as soon as playback starts.
    ///
    /// Worth logging rather than ignoring: `isClean` false means the master's
    /// `dvh1.08.xx/db1p` claim doesn't describe every frame.
    public var dolbyVisionConversion: DolbyVisionConversionStats? {
        remuxer.dolbyVisionConversionStats
    }

    /// The remux's terminal error, if it failed after startup. Hosts can poll
    /// this when AVPlayer reports a stalled item.
    public private(set) var remuxError: Error?

    /// The display criteria to program before AVPlayer loads this session's
    /// playlist — step 1 of the tvOS playback contract (see the type doc).
    ///
    /// Populated once the remux has probed the source, so it is ready by the
    /// time `start()` returns. `nil` only before that, or when the remux died
    /// before probing. Computed from the same declared Dolby Vision
    /// configuration the manifest claims (a converted P7 asks for DV as its
    /// declared 8.1), and clamped to the session's `DisplayCapabilities` — a
    /// non-DV display is asked for the base layer's range, a non-HDR-ready
    /// display for a rate-only (SDR) switch. Platforms whose panels engage
    /// HDR on demand (built-in iPhone/iPad/Mac displays) can ignore it; over
    /// HDMI it is the difference between playing and `-11848`.
    public var displayCriteria: DisplayCriteriaChoice? {
        remuxer.displayCriteriaChoice
    }

    /// - Parameters:
    ///   - displayIsHDRReady: whether the display this session plays to is in
    ///     (or will switch into) the source's own dynamic range. Only a host
    ///     knows this, and getting it wrong is expensive: an HDR variant offered
    ///     to an SDR-parked panel is rejected outright rather than tone-mapped,
    ///     so the default is `false` and an HDR source then keeps v0's
    ///     media-playlist shape — which means its audio stays muxed and
    ///     unswitchable until the host opts in. Phase 4 is where this becomes a
    ///     read instead of a parameter.
    ///   - displayIsDolbyVisionCapable: whether that display can present Dolby
    ///     Vision. Same reasoning; `false` simply omits the DV claims.
    ///   - segmentCacheBytes: disk budget for produced segments. Only
    ///     enforced when the source got a demand-driven plan — there a deleted
    ///     segment is reproduced on the next fetch, so the budget bounds disk,
    ///     not seekability. `nil` keeps everything for the session's lifetime.
    ///   - forceMuxedShape: skip the master/renditions shape and mux the one
    ///     best audio track into the variant (v0 shape). This is the host's
    ///     fallback when AVPlayer refuses a served master (-11868 / -11848 /
    ///     -1002): make a NEW session with this set — the rejected master's
    ///     variant alone would be silent video, renditions live only in
    ///     masters.
    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        displayIsHDRReady: Bool = false,
        displayIsDolbyVisionCapable: Bool = false,
        segmentCacheBytes: Int? = 1 << 30,
        forceMuxedShape: Bool = false
    ) throws {
        try self.init(
            url: url,
            httpHeaders: httpHeaders,
            display: DisplayCapabilities(
                isHDRReady: displayIsHDRReady,
                isDolbyVisionCapable: displayIsDolbyVisionCapable
            ),
            segmentCacheBytes: segmentCacheBytes,
            forceMuxedShape: forceMuxedShape
        )
    }

    /// The same session, taking the display's capabilities as one value.
    ///
    /// Prefer this over the two booleans: `DisplayCapabilities.current()` reads
    /// them from the display the host is actually playing to, which is what phase
    /// 4 set out to replace the caller-supplied guess with. The booleans stay for
    /// callers that genuinely know better than the read — a host mirroring to an
    /// external panel, or a test pinning a shape.
    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        display: DisplayCapabilities,
        segmentCacheBytes: Int? = 1 << 30,
        forceMuxedShape: Bool = false
    ) throws {
        self.configuration = Configuration(
            url: url,
            httpHeaders: httpHeaders,
            display: display,
            segmentCacheBytes: segmentCacheBytes,
            forceMuxedShape: forceMuxedShape
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.workDirectory = directory
        // The demand seam (phase 5): the provider turns a fetch of a
        // not-yet-produced planned segment into a producer re-anchor and a
        // pending serve. Sources the remuxer can't plan (live, junk index)
        // never publish a plan, and the provider then behaves exactly like
        // the plain directory provider.
        let demand = DemandCoordinator()
        self.server = LoopbackHTTPServer(
            provider: PlanSegmentProvider(root: directory, coordinator: demand)
        )
        self.remuxer = HLSRemuxer(
            sourceURL: url,
            httpHeaders: httpHeaders,
            outputDirectory: directory,
            // `offersHDR`, not `isHDRReady`: a panel currently presenting HDR
            // takes an HDR master even when the capability read came back
            // empty, so the certain signal rescues the conservative one.
            displayIsHDRReady: display.offersHDR,
            displayIsDolbyVisionCapable: display.isDolbyVisionCapable,
            demand: demand,
            segmentCacheBytes: segmentCacheBytes,
            forceMuxed: forceMuxedShape
        )
    }

    /// A session for the display the host is playing to right now.
    ///
    /// `@MainActor` because the display read is (see `DisplayCapabilities`), and
    /// the host's playback code is there already. This is the initializer Aether's
    /// routing should use: it is what makes an HDR or Dolby Vision source get a
    /// master playlist at all, since the caller-supplied defaults are `false`.
    @MainActor
    public static func readingCurrentDisplay(
        url: URL,
        httpHeaders: [String: String] = [:],
        segmentCacheBytes: Int? = 1 << 30,
        forceMuxedShape: Bool = false
    ) throws -> PrismCoreSession {
        try PrismCoreSession(
            url: url,
            httpHeaders: httpHeaders,
            display: .current(),
            segmentCacheBytes: segmentCacheBytes,
            forceMuxedShape: forceMuxedShape
        )
    }

    // MARK: - Master rejection (phase 4)

    /// Does this `AVPlayerItem.error` mean AVPlayer refused the master playlist,
    /// rather than that the source is unplayable?
    ///
    /// See `MasterRejection` for the three codes and why they are what they are.
    /// A host that gets `true` should stop this session, take
    /// `makeMuxedFallbackSession()`, and play that — *not* fall back to another
    /// engine, because the source itself was never the problem.
    public static func isMasterRejection(_ error: Error?) -> Bool {
        MasterRejection.matches(error)
    }

    /// A fresh session over the same source with `forceMuxedShape` set: no
    /// master, the one best audio track muxed into the variant, media playlist
    /// served directly.
    ///
    /// This is the recovery path for a refused master, and it has to be a *new*
    /// session because the shape is decided before the first packet and the
    /// output layout follows from it — there is nothing to re-negotiate in place.
    /// Registered external subtitles are replayed onto the clone so the host
    /// doesn't have to remember them, though in this shape nothing selects them:
    /// a `SUBTITLES` group exists only inside a master.
    ///
    /// Calling this on a session that is *already* muxed-shape returns an
    /// equivalent new session rather than refusing — a rejection here means
    /// something other than the shape was wrong, and the caller's own retry
    /// policy is the right place to stop, not this factory.
    /// `async` only because replaying the subtitle registrations means calling
    /// into the new session's actor.
    public func makeMuxedFallbackSession() async throws -> PrismCoreSession {
        let fallback = try PrismCoreSession(
            url: configuration.url,
            httpHeaders: configuration.httpHeaders,
            display: configuration.display,
            segmentCacheBytes: configuration.segmentCacheBytes,
            forceMuxedShape: true
        )
        for subtitle in externalSubtitles {
            try await fallback.addExternalSubtitle(
                url: subtitle.url,
                language: subtitle.language,
                name: subtitle.name,
                isForced: subtitle.isForced
            )
        }
        return fallback
    }

    // MARK: - Subtitles (phase 6)

    /// Register an external subtitle file (`.srt` / `.vtt`) as its own WebVTT
    /// rendition, before `start()`.
    ///
    /// The whole file is converted once at remux setup and then segmented on the
    /// video's own boundaries, exactly like an embedded text track — so an
    /// external track behaves identically from AVPlayer's side. The rendition
    /// set is fixed when the remux starts (it has to be: the master playlist a
    /// host builds from `subtitleRenditions` is read once at item creation),
    /// hence the `alreadyStarted` refusal.
    ///
    /// - Parameters:
    ///   - url: A local file URL. Remote sidecars are the host's to fetch —
    ///     PrismCore has no download machinery and would only duplicate the
    ///     header handling the host already does.
    ///   - language: ISO-639 tag for `LANGUAGE`, e.g. `"cs"` / `"ces"`.
    ///   - name: Display name for `NAME`; defaults to the language tag.
    ///   - isForced: Marks the rendition `FORCED=YES`.
    public func addExternalSubtitle(
        url: URL,
        language: String? = nil,
        name: String? = nil,
        isForced: Bool = false
    ) throws {
        guard !started else { throw SessionError.alreadyStarted }
        remuxer.subtitles.addExternalFile(
            .init(url: url, language: language, name: name, isForced: isForced)
        )
        // Remembered so a muxed fallback session can be a faithful clone.
        externalSubtitles.append((url: url, language: language, name: name, isForced: isForced))
    }

    /// The WebVTT subtitle renditions this session serves, in declaration order
    /// (embedded text tracks first, then registered external files).
    ///
    /// Populated once the remux has opened the source, i.e. any time after
    /// `start()` returns. The session's own master playlist already declares
    /// them — this is informational (a host listing tracks in its UI). A
    /// `SUBTITLES` group only exists in a master playlist, so a session served
    /// media-direct produces the renditions on disk but nothing selects them.
    public var subtitleRenditions: [MasterPlaylistBuilder.SubtitleRendition] {
        remuxer.subtitles.renditions
    }

    /// Start the loopback server and the remux, and return the playlist URL
    /// once everything that playlist references exists on disk — the point where
    /// AVPlayer can be pointed at it without racing an empty directory.
    public func start(startupTimeout: Duration = .seconds(20)) async throws -> URL {
        precondition(!started, "PrismCoreSession is single-use — make a new one per load")
        started = true

        let base = try await server.start()

        let remuxer = self.remuxer
        let task = Task.detached(priority: .userInitiated) {
            try remuxer.run()
        }
        remuxTask = task
        watchForTerminalError(task)

        let deadline = ContinuousClock.now.advanced(by: startupTimeout)
        while ContinuousClock.now < deadline {
            if let ready = readyPlaylistName() {
                return base.appendingPathComponent(ready)
            }
            // A remux that already died will never produce the playlist —
            // surface its error instead of burning the whole timeout.
            if task.isCancelled { break }
            if let remuxError { throw SessionError.startupTimedOut(underlying: remuxError) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SessionError.startupTimedOut(underlying: remuxError)
    }

    /// Cancel the remux, stop serving, and remove the session's segments.
    public func stop() async {
        remuxer.cancel()
        remuxTask?.cancel()
        _ = try? await remuxTask?.value
        await server.stop()
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: - Readiness

    /// The playlist to hand out, once it is genuinely playable — or `nil` while
    /// the remux is still finding its feet.
    ///
    /// The remuxer writes the master first (its contents are known before the
    /// first packet), so the master's presence is what decides the shape. What
    /// takes a moment is the *renditions*: a master whose audio playlist doesn't
    /// exist yet is a 404 for AVPlayer, which it can fail the item over rather
    /// than retry. So every playlist the master references — the video variant
    /// and each rendition — has to be there, carry an `EXTINF`, and have its
    /// `EXT-X-MAP` init segment on disk.
    private func readyPlaylistName() -> String? {
        let master = workDirectory.appendingPathComponent(HLSRemuxer.masterPlaylistFileName)
        guard let masterText = try? String(contentsOf: master, encoding: .utf8) else {
            return isPlayable(playlist: HLSRemuxer.mediaPlaylistFileName)
                ? HLSRemuxer.mediaPlaylistFileName
                : nil
        }
        let referenced = Self.playlistURIs(inMaster: masterText)
        guard !referenced.isEmpty, referenced.allSatisfy(isPlayable(playlist:)) else { return nil }
        return HLSRemuxer.masterPlaylistFileName
    }

    /// Every media playlist a master refers to: the `URI` of each `EXT-X-MEDIA`
    /// rendition, plus the plain URI line that follows each `EXT-X-STREAM-INF`.
    static func playlistURIs(inMaster text: String) -> [String] {
        var uris: [String] = []
        var expectingVariantURI = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if expectingVariantURI, !line.hasPrefix("#") {
                uris.append(line)
                expectingVariantURI = false
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                expectingVariantURI = true
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:"), let uri = attribute("URI", in: line) {
                uris.append(uri)
            }
        }
        return uris
    }

    /// One quoted attribute value out of a tag line. Deliberately minimal — the
    /// only attribute read back is `URI`, and the builder wrote it.
    private static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Does this relative media playlist exist, list a segment, and have the
    /// init segment it maps to?
    private func isPlayable(playlist relativePath: String) -> Bool {
        let url = workDirectory.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.contains("#EXTINF")
        else { return false }
        guard let mapLine = text.split(separator: "\n").first(where: {
            $0.hasPrefix("#EXT-X-MAP:")
        }) else { return true }
        guard let mapURI = Self.attribute("URI", in: String(mapLine)) else { return true }
        let initSegment = url.deletingLastPathComponent().appendingPathComponent(mapURI)
        return FileManager.default.fileExists(atPath: initSegment.path)
    }

    private func watchForTerminalError(_ task: Task<Void, Error>) {
        Task { [weak self] in
            do {
                try await task.value
            } catch {
                await self?.record(error: error)
            }
        }
    }

    private func record(error: Error) {
        remuxError = error
    }
}
