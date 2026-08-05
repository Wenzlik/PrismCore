import Foundation
import AVFoundation
#if canImport(AppKit)
import AppKit
#endif

/// What the display this session plays to can actually present.
///
/// Phase 4's groundwork made HDR/DV readiness two caller-supplied booleans,
/// with a deliberate `false` default — an over-claiming manifest is rejected
/// outright (`-11868` / `-11848`) rather than degraded, so "don't know" had to
/// mean "don't claim". This type is the read that replaces the guess.
///
/// ## Why this is a *readiness* question, not a capability one
///
/// `displayIsHDRReady` documents itself as "is in, **or will switch into**, the
/// source's dynamic range" — which is what makes tvOS's Match Content the happy
/// path: the panel is SDR-parked right up until playback starts, then follows the
/// content. So the honest read is what the display *supports*, not what it is
/// showing this instant, and that is exactly what `AVPlayer.availableHDRModes`
/// reports.
///
/// The gap that survives: a tvOS panel that supports HDR with Match Content
/// **off** stays SDR-parked, accepts nothing PQ, and fails the item with
/// `-11848`. No API distinguishes that from the Match-Content case, which is
/// precisely why `MasterRejection` exists — the read is the optimistic half, the
/// rejection fallback is the half that catches it being wrong.
public struct DisplayCapabilities: Sendable, Equatable {

    /// Where the values came from — surfaced because a `.unavailable` read and a
    /// genuinely-SDR display produce identical booleans, and only the first one
    /// is worth logging when a host wonders why it never sees HDR.
    public enum Source: String, Sendable, Equatable {
        /// `AVPlayer.availableHDRModes` (iOS / tvOS / visionOS).
        case availableHDRModes
        /// `NSScreen`'s EDR headroom (macOS).
        case extendedDynamicRange
        /// No display to ask — headless test host, or an OS below the floor.
        case unavailable
        /// A host vouched for the display itself.
        case caller
    }

    /// Whether an HDR (`PQ` / `HLG`) variant may be offered.
    public let isHDRReady: Bool
    /// Whether Dolby Vision may be claimed on top of it.
    public let isDolbyVisionCapable: Bool
    public let source: Source

    public init(isHDRReady: Bool, isDolbyVisionCapable: Bool, source: Source = .caller) {
        self.isHDRReady = isHDRReady
        self.isDolbyVisionCapable = isDolbyVisionCapable
        self.source = source
    }

    /// Everything off — what a session gets when nobody asked and nothing could
    /// be read. Keeps v0's media-direct shape for HDR sources.
    public static let conservative = DisplayCapabilities(
        isHDRReady: false, isDolbyVisionCapable: false, source: .unavailable
    )

    /// Read the current display.
    ///
    /// `@MainActor` because both underlying reads are: `NSScreen.main` is
    /// main-thread-only, and `availableHDRModes` reflects UIKit's current screen
    /// state. A session is created from the host's playback code, which is
    /// already on the main actor, so this costs nothing in practice.
    @MainActor
    public static func current() -> DisplayCapabilities {
        #if os(macOS)
        // AVPlayer.availableHDRModes doesn't exist on macOS. The equivalent
        // question is whether the screen has EDR headroom to render into:
        // > 1.0 means values above SDR white are presentable, which is what an
        // HDR10/HLG variant needs.
        //
        // `maximumPotential…` rather than `maximumExtendedDynamicRange…` on
        // purpose: the latter is the headroom available *right now* (it drops to
        // 1.0 on battery, under thermal pressure, or when no EDR content is on
        // screen), and this is a readiness question — the same reasoning as
        // Match Content above.
        guard let screen = NSScreen.main else { return .conservative }
        let headroom = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        return DisplayCapabilities(
            isHDRReady: headroom > 1.0,
            // Deliberately never true on macOS. A Mac plays profile 8.1 fine —
            // as its HDR10 base, through EDR — but there is no HDMI DV
            // handshake to engage and no API that says a DV claim would be
            // honoured, so claiming `dvh1` here risks -11868 to buy a
            // presentation the base layer already gives us. Revisit with a
            // device, not with a guess.
            isDolbyVisionCapable: false,
            source: .extendedDynamicRange
        )
        #else
        // On tvOS this is the read that matters: it reflects the display across
        // the HDMI link, so it changes with the TV the box is plugged into.
        let modes = AVPlayer.availableHDRModes
        guard !modes.isEmpty else {
            // An empty set is a real answer (SDR display), not a failure —
            // report it as such so a host can tell it from "couldn't ask".
            return DisplayCapabilities(
                isHDRReady: false, isDolbyVisionCapable: false, source: .availableHDRModes
            )
        }
        return DisplayCapabilities(
            // .hlg / .hdr10 / .dolbyVision — any of them means the panel can
            // leave SDR, which is what gates offering a PQ or HLG variant.
            isHDRReady: true,
            isDolbyVisionCapable: modes.contains(.dolbyVision),
            source: .availableHDRModes
        )
        #endif
    }
}
