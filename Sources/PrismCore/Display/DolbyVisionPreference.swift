import Foundation

/// How the host wants a Dolby Vision source presented — the *user's* choice,
/// kept apart from `DisplayCapabilities`, which is the honest read of what the
/// display can do.
///
/// The two used to be one boolean: a host whose user turned Dolby Vision off
/// said so by passing `isDolbyVisionCapable: false`. That is the right answer
/// for a profile with a base layer (7, 8.1, 8.4 play as their HDR10 / HLG base)
/// and the wrong one for Profile 5, which has no base layer to fall back to —
/// its picture *is* the Dolby Vision signal (IPT-PQc2), and the only way to
/// show it is to let AVFoundation's Dolby Vision decoder reshape it, whatever
/// the setting says. Lying about the display to express a preference also
/// clamped the display criteria and the master shape for every source, not
/// just the ones the setting was about.
public enum DolbyVisionPreference: String, Sendable, Equatable {
    /// Dolby Vision whenever the display can present it — the behaviour every
    /// session had before this option existed.
    case automatic
    /// Present the base layer alone: plain `hvc1`, the `dvcC`/`dvvC` record
    /// stripped, no `SUPPLEMENTAL-CODECS`, HDR10 / HLG display criteria.
    ///
    /// Applies only to sources that **have** a usable base layer: Profile 7
    /// and 8.x (and AV1 10.1 / 10.4). For a genuine Profile 5 it is ignored —
    /// there is no base layer, and serving its IPT picture as plain HEVC is
    /// the solarised misread, not a fallback. The one Profile 5 it does apply
    /// to is a record whose own VUI declares a BT.2020 YCbCr base with a PQ or
    /// HLG transfer: IPT has no VUI code point, so a genuine Profile 5 leaves
    /// both unspecified, and a record over a YCbCr VUI is a container
    /// contradicting the bitstream the decoder actually consumes. Those colour
    /// fields are the codec parameters, which a container `colr` box can fill
    /// as well as the SPS, so they are no proof on their own: an RPU that
    /// reads 5 overrules them, and the record is kept.
    case baseLayerOnly

    /// Whether a source with this Dolby Vision record (and this VUI) is
    /// served as its base layer alone under this preference.
    ///
    /// - Parameters:
    ///   - colorTransferName: the stream's transfer characteristic as
    ///     libavutil names it (`VideoTrackInfo.colorTransferName`).
    ///   - colorSpaceName: its matrix coefficients, likewise
    ///     (`VideoTrackInfo.colorSpaceName`).
    ///   - rpuProfile: the profile the stream's own RPU was authored for, when
    ///     it has been read; `nil` when it has not.
    public func presentsBaseLayer(
        of dolbyVision: DolbyVisionConfiguration?,
        colorTransferName: String?,
        colorSpaceName: String?,
        rpuProfile: UInt8? = nil
    ) -> Bool {
        guard self == .baseLayerOnly, let dolbyVision else { return false }
        switch dolbyVision.profile {
        case 7, 8:
            return true
        case 10 where dolbyVision.baseLayerSignalCompatibilityID != 0:
            return true
        case 5 where rpuProfile == 5:
            // The picture is IPT, whatever a `colr` box claims: stripping the
            // record would serve it as plain HEVC, the solarised misread.
            return false
        case 5, 10:
            return Self.vuiDeclaresYCbCrHDRBase(
                colorTransferName: colorTransferName, colorSpaceName: colorSpaceName
            )
        default:
            return false
        }
    }

    /// A VUI naming a BT.2020 YCbCr matrix with an HDR transfer — what an
    /// HDR10 or HLG base layer declares, and what IPT-PQc2 cannot.
    static func vuiDeclaresYCbCrHDRBase(colorTransferName: String?, colorSpaceName: String?) -> Bool {
        let hdrTransfer = colorTransferName == "smpte2084" || colorTransferName == "arib-std-b67"
        let ycbcrMatrix = colorSpaceName == "bt2020nc" || colorSpaceName == "bt2020c"
        return hdrTransfer && ycbcrMatrix
    }
}
