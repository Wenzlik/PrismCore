import Foundation

/// The display mode a playback session wants the panel in *before* AVPlayer
/// sees the playlist — and the refresh rate that should ride along with it.
///
/// This is the pure half of the display-criteria story: given what the source
/// is and what the display can do, which criteria should be programmed. The
/// impure half — writing `preferredDisplayCriteria` and waiting out the HDMI
/// handshake — is `DisplayCriteriaController`, which only exists on tvOS.
/// Splitting them keeps every decision testable on any host.
///
/// ## Why the decision has to be made at all
///
/// tvOS validates an HLS variant's `VIDEO-RANGE` against the panel's *current*
/// mode synchronously, at variant selection — before any media is fetched. A
/// PQ variant offered to an SDR-parked panel fails the item with `-11848` /
/// `-11868` outright; nothing tone-maps, nothing retries. The order that works
/// (Apple Tech Talk 503, and still the only one) is: program
/// `preferredDisplayCriteria`, wait for the switch, and only then hand the
/// item to the player. AVKit's automatic criteria
/// (`appliesPreferredDisplayCriteriaAutomatically`) cannot provide this for
/// HLS: it derives criteria from the chosen variant's format description,
/// which only exists after the variant passes the very validation the switch
/// has to precede.
public struct DisplayCriteriaChoice: Sendable, Equatable {

    /// The panel mode being asked for.
    public enum Target: String, Sendable, Equatable {
        case dolbyVision
        case hdr10
        case hlg
        case sdr
    }

    public let target: Target

    /// The source's frame rate, when it is known — programming it is what
    /// makes tvOS's Match Frame Rate engage. `nil` means "mode only".
    ///
    /// Deliberately carried for SDR too. The tempting early-return ("SDR needs
    /// no HDMI handshake") is exactly the bug that keeps SDR 24 fps content on
    /// a 60 Hz panel: the criteria write is *also* the channel Match Frame
    /// Rate rides on, so an SDR source with a known rate still wants its
    /// rate-only write.
    public let refreshRate: Float?

    public init(target: Target, refreshRate: Float?) {
        self.target = target
        self.refreshRate = refreshRate
    }

    /// The choice for a probed source on a given display.
    ///
    /// - A display that isn't HDR-ready gets `.sdr` (rate-only) no matter what
    ///   the source carries: the session serves such a source media-direct and
    ///   AVPlayer tone-maps it, so asking the panel to leave SDR would be
    ///   asking for the very mode mismatch the criteria exist to prevent.
    /// - Dolby Vision is asked for only when the *declared* configuration
    ///   actually presents as DV on this display. Profile 8.2's Rec.709 base
    ///   is signaled plain SDR (the same honesty rule the playlist follows),
    ///   and a DV-incapable display gets the base layer's own range — HDR10
    ///   for 8.1, HLG for 8.4, and for profile 5 (no base layer) the PQ its
    ///   bitstream carries, which AVPlayer tone-maps from the `dvh1` sample
    ///   entry on the media-direct route.
    ///
    /// - Parameter declaredDolbyVision: the configuration the session
    ///   *declares* — the converted 8.1 record when a P7 conversion is
    ///   running, the source's own otherwise. Mirrors `MasterPlaylistBuilder`.
    public static func forSource(
        dynamicRange: DynamicRange,
        declaredDolbyVision: DolbyVisionConfiguration?,
        display: DisplayCapabilities,
        frameRate: Double?
    ) -> DisplayCriteriaChoice {
        let rate = frameRate.map { Float($0) }
        guard display.isHDRReady || display.panelIsCurrentlyHDR == true else {
            return DisplayCriteriaChoice(target: .sdr, refreshRate: rate)
        }
        if let dv = declaredDolbyVision,
           !dv.hasSDRCompatibleBase,
           display.isDolbyVisionCapable {
            return DisplayCriteriaChoice(target: .dolbyVision, refreshRate: rate)
        }
        switch dynamicRange {
        case .pq:
            return DisplayCriteriaChoice(target: .hdr10, refreshRate: rate)
        case .hlg:
            return DisplayCriteriaChoice(target: .hlg, refreshRate: rate)
        case .sdr:
            return DisplayCriteriaChoice(target: .sdr, refreshRate: rate)
        }
    }

    /// Whether this target needs the panel out of SDR. This is the half of
    /// the handshake that is ever observable from the app's side (EDR headroom
    /// rises around the transition); a rate-only switch reports nothing.
    public var wantsHDRPanel: Bool { target != .sdr }
}
