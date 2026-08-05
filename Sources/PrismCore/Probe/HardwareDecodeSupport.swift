import Foundation
import CoreMedia
#if canImport(VideoToolbox)
import VideoToolbox
#endif

/// What *this* device can decode in hardware.
///
/// One codec needs this today, and needs it as a correctness question rather than
/// a performance one: **AV1**. Apple's hardware AV1 decoder arrived with the
/// A17 Pro and the M3, and there is no software AV1 decoder in VideoToolbox
/// behind it — Safari plays AV1 on an M1 or M2 through its own dav1d, not through
/// the system. So on those chips (Vision Pro's M2 included) an AV1 track handed to
/// `AVPlayer` doesn't play *slowly*, it doesn't play at all.
///
/// Which makes the gate the difference between offering AV1 on the native path and
/// serving an unplayable stream. Asked of the device rather than inferred from a
/// chip name: the same binary runs on an A16 and an M4, and a table of model
/// identifiers is a table that goes stale.
public enum HardwareDecodeSupport {

    /// Whether this device decodes AV1 in hardware, and therefore whether AV1 can
    /// ride the remux path at all.
    ///
    /// `false` is not a failure — it routes AV1 to PrismCore's own software path,
    /// which decodes it with libdav1d. That is the only way AV1 plays on an M2,
    /// and it is why the software path matters most on the platform (visionOS)
    /// that has the least of it wired up.
    public static var isAV1Supported: Bool { supportsAV1 }

    #if canImport(VideoToolbox)
    private static let supportsAV1: Bool = {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }()
    #else
    // No VideoToolbox to ask (a Linux host running the pure-logic tests). Claiming
    // support we can't verify would put an unplayable variant in a manifest.
    private static let supportsAV1 = false
    #endif
}
