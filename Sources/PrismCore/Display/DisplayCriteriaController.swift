import Foundation
import AVFoundation
import CoreMedia
#if os(tvOS)
import UIKit
import AVKit
#endif

/// The pure decisions `DisplayCriteriaController` acts on, split out so they
/// compile — and test — on every platform, while the controller itself only
/// exists where `AVDisplayManager` does (tvOS).
public enum DisplayCriteriaLogic {

    /// What a criteria write asked the panel for, reduced to the fields whose
    /// equality means "the panel is already there". Re-writing identical
    /// criteria is not a no-op: it starts a redundant HDMI mode switch, and on
    /// panels whose Dolby Vision switch is unobservable that redundant switch
    /// makes every settle wait run to its cap.
    public struct WrittenCriteria: Sendable, Equatable {
        public let target: DisplayCriteriaChoice.Target
        public let refreshRate: Float

        public init(target: DisplayCriteriaChoice.Target, refreshRate: Float) {
            self.target = target
            self.refreshRate = refreshRate
        }
    }

    /// Skip the write when the previously-written criteria are still active
    /// and identical. `previous` is `nil` after a reset (or before the first
    /// write), and then the write always happens.
    public static func writeIsRedundant(
        previous: WrittenCriteria?, next: WrittenCriteria
    ) -> Bool {
        previous == next
    }

    /// Will the panel present this session in HDR?
    ///
    /// `UIScreen.currentEDRHeadroom` is **not** a readout of the panel's HDMI
    /// mode — it rises around a dynamic-range *transition* and decays back to
    /// 1.0 while the panel keeps presenting HDR. So a raised headroom is
    /// trusted as a positive, and its absence is answered by history: once a
    /// criteria write has demonstrably driven *this* display into HDR, an HDR
    /// write that ended quietly means "already there", not "refused". A panel
    /// that never proved itself (Match Dynamic Range off, genuinely SDR
    /// display) keeps the conservative answer and is never offered a PQ master
    /// it would reject.
    public static func panelPresentsHDR(
        headroomIsRaised: Bool,
        wroteHDRCriteria: Bool,
        panelHasProvenHDR: Bool
    ) -> Bool {
        if headroomIsRaised { return true }
        return wroteHDRCriteria && panelHasProvenHDR
    }

    /// How long `waitForSwitch` may spend on each stage, by what the last
    /// write asked of the panel.
    ///
    /// A dynamic-range switch is a real HDMI renegotiation — HDCP re-auth,
    /// mode engage, often through an AVR — and on living-room chains it
    /// routinely takes 2–5 s to *end*, and over a second to visibly *start*.
    /// The old flat 1 s + 2 s bounds lost that race often enough to matter:
    /// the master loaded against the panel's old mode, tvOS refused the DV
    /// claim (`-11868`), and the rejection fallback silently replayed the
    /// title as HDR10 — a different HDMI mode with the TV's other picture
    /// preset. One play engaged Dolby Vision, the next didn't, and which one
    /// a viewer got was a coin flip (found on an Apple TV 4K driving a real
    /// panel, 2026-08-07).
    ///
    /// Both waits exit on the first positive signal (mode-switch-end, raised
    /// headroom, in-progress flag clearing), so generous caps cost nothing on
    /// panels that report their switches; the caps only bind where the switch
    /// is genuinely still running or unobservable. Rate-only writes keep the
    /// old bounds — a refresh-rate switch has no range claim to lose a race
    /// for, and stretching every SDR load would be pure dead time.
    public static func settleBounds(
        wantsHDRPanel: Bool
    ) -> (startGrace: Duration, settleCap: Duration) {
        wantsHDRPanel
            ? (startGrace: .seconds(2), settleCap: .seconds(6))
            : (startGrace: .seconds(1), settleCap: .seconds(2))
    }
}

#if os(tvOS)

/// Programs the HDMI dynamic-range / refresh-rate handshake for a session,
/// via `AVDisplayManager` — the piece of the playback contract that has to
/// run **before** the host hands `AVPlayer` the playlist URL.
///
/// ```swift
/// let controller = DisplayCriteriaController(window: window)
/// let session = try PrismCoreSession(url: source, display: .current())
/// let playlist = try await session.start()
/// if let choice = await session.displayCriteria {
///     controller.apply(choice)
///     await controller.waitForSwitch()
/// }
/// player.replaceCurrentItem(with: AVPlayerItem(url: playlist))
/// ```
///
/// Hosts using `AVPlayerViewController` must also set
/// `appliesPreferredDisplayCriteriaAutomatically = false`: two writers racing
/// the same `preferredDisplayCriteria` slot produce a double handshake, and
/// AVKit's own write cannot arrive early enough for HLS anyway (see
/// `DisplayCriteriaChoice`).
///
/// On teardown call `reset()`. It nils the criteria only when this controller
/// actually wrote them, so a host that never applied anything never disturbs
/// whatever else is managing the panel.
@MainActor
public final class DisplayCriteriaController {

    /// What `apply(_:)` did, which tells the host whether a settle wait is
    /// worth anything.
    public enum ApplyResult: Sendable, Equatable {
        /// HDR/DV criteria written; a dynamic-range handshake is expected —
        /// call `waitForSwitch()` before starting playback.
        case willSwitch
        /// Rate-only criteria written; the switch is sub-second and needs no
        /// explicit wait.
        case wrote
        /// The identical criteria are already active; nothing was written and
        /// no switch is coming.
        case alreadyActive
        /// Nothing was written: the user has Match Content fully off (both
        /// sub-toggles), so tvOS would ignore the write and no switch can ever
        /// start. The session should be routed as if the panel stays in its
        /// current mode.
        case matchingDisabled
    }

    private let window: UIWindow
    private var written: DisplayCriteriaLogic.WrittenCriteria?
    private var lastWriteWantedHDR = false
    /// Sticky: set the first time a raised EDR headroom is ever observed, and
    /// deliberately never cleared — the headroom is a transition artifact, so
    /// its later absence proves nothing (see `DisplayCriteriaLogic`).
    private var panelHasProvenHDR = false

    public init(window: UIWindow) {
        self.window = window
    }

    /// `isDisplayCriteriaMatchingEnabled` is a *combined* flag: true when
    /// either Match Dynamic Range **or** Match Frame Rate is on, with no
    /// public way to tell which. That makes it usable in exactly one
    /// direction — `false` proves no switch can happen; `true` must never be
    /// read as "the panel will follow HDR content" (match-rate-on /
    /// match-range-off reads `true` and the panel still refuses PQ).
    public var matchingIsEnabled: Bool {
        window.avDisplayManager.isDisplayCriteriaMatchingEnabled
    }

    /// Write `preferredDisplayCriteria` for this choice.
    ///
    /// The criteria are a synthetic `CMVideoFormatDescription` handed to
    /// `AVDisplayCriteria(refreshRate:formatDescription:)`. Two details carry
    /// the whole behavior:
    ///
    /// - The **fourcc picks the mode family**: `dvh1` is what makes the panel
    ///   negotiate Dolby Vision; an HEVC fourcc with the same BT.2020/PQ color
    ///   extensions lands in HDR10 instead. (The extensions alone can't say
    ///   "Dolby Vision" — there is no public way to attach a `dvcC` to a
    ///   synthetic description, which is why criteria built without the
    ///   fourcc kept DV panels in HDR10.)
    /// - **SDR omits the color extensions entirely**: codec + rate only, so
    ///   Match Frame Rate can engage without Match Dynamic Range being asked
    ///   to do anything.
    @discardableResult
    public func apply(_ choice: DisplayCriteriaChoice) -> ApplyResult {
        let manager = window.avDisplayManager
        guard manager.isDisplayCriteriaMatchingEnabled else { return .matchingDisabled }

        // Match Frame Rate keys off the rate even when the range doesn't
        // change, so an unknown rate still needs a plausible value for the
        // description to be well-formed. 24 is film, and wrong-but-plausible
        // beats absent: tvOS ignores the rate when Match Frame Rate is off.
        let rate = choice.refreshRate ?? 24
        let next = DisplayCriteriaLogic.WrittenCriteria(target: choice.target, refreshRate: rate)
        if DisplayCriteriaLogic.writeIsRedundant(previous: written, next: next) {
            lastWriteWantedHDR = choice.wantsHDRPanel
            return .alreadyActive
        }

        guard let description = Self.makeFormatDescription(for: choice) else {
            // A CoreMedia refusal to build a 4-field description is not a
            // state this can recover from; play without the pre-switch and
            // let the media-direct fallback catch a rejection.
            return .matchingDisabled
        }
        manager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(rate), formatDescription: description
        )
        written = next
        lastWriteWantedHDR = choice.wantsHDRPanel
        return choice.wantsHDRPanel ? .willSwitch : .wrote
    }

    /// Block until the HDMI handshake the last `apply(_:)` started has
    /// settled, bounded so a switch the app can't observe never stalls the
    /// first frame.
    ///
    /// Stage 1 waits (up to `startGrace`) for a switch to *start* — the
    /// criteria write kicks the negotiation off asynchronously, and loading
    /// the asset mid-write is exactly the race the whole exercise exists to
    /// avoid. A start is visible as the `AVDisplayManager` mode-switch-start
    /// notification or the in-progress flag. If nothing starts, the panel
    /// already satisfied the criteria and there is nothing to wait for.
    ///
    /// Stage 2 waits (up to `settleCap`) for any reliable "done" signal: the
    /// mode-switch-end notification, the EDR headroom rising (HDR targets), or
    /// the in-progress flag clearing. Some panels complete a Dolby Vision
    /// switch without ever reporting it — headroom stays 1.0, the in-progress
    /// flag sticks — which is why the cap exists and why hitting it is not an
    /// error: the panel is mid re-sync (black) during the handshake anyway,
    /// and shows the correct picture once it locks.
    ///
    /// `nil` bounds (the defaults) resolve per what the last `apply(_:)`
    /// wrote — dynamic-range switches get room for a real HDMI renegotiation,
    /// rate-only switches keep short bounds. See
    /// `DisplayCriteriaLogic.settleBounds` for the numbers and the race they
    /// close; pass explicit values only to override that policy.
    public func waitForSwitch(
        startGrace: Duration? = nil,
        settleCap: Duration? = nil
    ) async {
        let bounds = DisplayCriteriaLogic.settleBounds(wantsHDRPanel: lastWriteWantedHDR)
        let startGrace = startGrace ?? bounds.startGrace
        let settleCap = settleCap ?? bounds.settleCap
        let manager = window.avDisplayManager
        let screen = window.screen
        // Matching off ⇒ tvOS ignored the write; the whole grace would be
        // dead startup time on every load.
        guard manager.isDisplayCriteriaMatchingEnabled else { return }
        if observeHeadroom(screen), lastWriteWantedHDR { return }

        let started = OneShotFlag()
        let ended = OneShotFlag()
        let startToken = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchStart, object: manager, queue: nil
        ) { _ in started.fire() }
        let endToken = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchEnd, object: manager, queue: nil
        ) { _ in ended.fire() }
        defer {
            NotificationCenter.default.removeObserver(startToken)
            NotificationCenter.default.removeObserver(endToken)
        }

        // Stage 1 — did a switch start at all?
        var switchIsRunning = false
        let graceDeadline = ContinuousClock.now.advanced(by: startGrace)
        while ContinuousClock.now < graceDeadline {
            if ended.fired { return }
            if lastWriteWantedHDR, observeHeadroom(screen) { return }
            if started.fired || manager.isDisplayModeSwitchInProgress {
                switchIsRunning = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard switchIsRunning else { return }

        // Stage 2 — bounded settle.
        let settleDeadline = ContinuousClock.now.advanced(by: settleCap)
        while ContinuousClock.now < settleDeadline {
            try? await Task.sleep(for: .milliseconds(50))
            if ended.fired { return }
            if lastWriteWantedHDR, observeHeadroom(screen) { return }
            if !manager.isDisplayModeSwitchInProgress { return }
        }
    }

    /// Whether the panel presents this session in HDR — the input a host
    /// feeds back into `DisplayCapabilities.panelIsCurrentlyHDR` for the
    /// *next* session's routing. Meaningful after `apply` + `waitForSwitch`
    /// have settled; see `DisplayCriteriaLogic.panelPresentsHDR` for why a
    /// quiet headroom is not a "no".
    public func currentPanelIsHDR() -> Bool {
        DisplayCriteriaLogic.panelPresentsHDR(
            headroomIsRaised: observeHeadroom(window.screen),
            wroteHDRCriteria: written != nil && lastWriteWantedHDR,
            panelHasProvenHDR: panelHasProvenHDR
        )
    }

    /// Return the panel to its default criteria — only when this controller
    /// wrote them. Nil-ing criteria somebody else manages races their
    /// in-flight handshake.
    public func reset() {
        guard written != nil else { return }
        window.avDisplayManager.preferredDisplayCriteria = nil
        written = nil
    }

    /// Every headroom read funnels through here so a single observation of a
    /// real HDR engage is remembered after the value decays.
    private func observeHeadroom(_ screen: UIScreen) -> Bool {
        guard screen.currentEDRHeadroom > 1.001 else { return false }
        panelHasProvenHDR = true
        return true
    }

    /// The synthetic description whose fourcc + extensions steer the panel.
    /// The dimensions are a formality (criteria don't resolution-switch), but
    /// the description has to be creatable, so they are a real video size.
    private static func makeFormatDescription(
        for choice: DisplayCriteriaChoice
    ) -> CMVideoFormatDescription? {
        let fourcc: CMVideoCodecType = choice.target == .dolbyVision
            ? 0x64766831  // 'dvh1'
            : kCMVideoCodecType_HEVC
        var extensions: [CFString: Any]? = nil
        if choice.wantsHDRPanel {
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries:
                    kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction:
                    choice.target == .hlg
                        ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                        : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                kCMFormatDescriptionExtension_YCbCrMatrix:
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
        }
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: fourcc,
            width: 3840,
            height: 2160,
            extensions: extensions as CFDictionary?,
            formatDescriptionOut: &description
        )
        return description
    }
}

/// A one-shot boolean set from a notification queue and polled from the
/// settle loop.
private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var fired: Bool { lock.withLock { value } }
    func fire() { lock.withLock { value = true } }
}

#endif
