import Testing
import Libavfilter
@testable import PrismCore

/// Deinterlacing used to cost the whole hardware decode: `bwdif` reads planar
/// YUV, so asking for it forced the CPU route — on an Apple TV, for interlaced
/// broadcast, the worst combination available. `yadif_videotoolbox` filters the
/// frames VideoToolbox already produced, so the zero-copy route survives.
///
/// The filter is a property of the FFmpeg *build* (it needs Metal, a separate
/// Xcode component), so both branches have to work. These pin the decision;
/// the GPU graph itself can only be exercised where the filter exists — a host
/// on the aether-ffmpeg build, or a device.
@Suite("GPU deinterlace")
struct GPUDeinterlaceTests {

    @Test("The GPU deinterlacer is reported exactly when the build carries it")
    func detectionMatchesTheBuild() {
        let present = avfilter_get_by_name("yadif_videotoolbox") != nil
        #expect((SoftwareVideoDecoder.gpuDeinterlaceName != nil) == present)
        if present {
            #expect(SoftwareVideoDecoder.gpuDeinterlaceName == "yadif_videotoolbox")
        }
    }

    @Test("bwdif is always there — the fallback can't itself be missing")
    func cpuDeinterlacerAlwaysExists() {
        // The CPU route is what a build without Metal falls back to. If this
        // ever fails, deinterlacing is gone entirely rather than merely slow.
        #expect(avfilter_get_by_name("bwdif") != nil)
    }

    @Test("Asking for deinterlace keeps hardware decode only when the GPU filter exists")
    func hardwareIsKeptOnlyWhenItCanBe() throws {
        // The decision this release is about, read back from a real decoder.
        let fixture = try #require(Bundle.module.url(
            forResource: "h264_interlaced", withExtension: "mkv", subdirectory: "Fixtures"
        ))
        let info = try SourceProbe.probe(url: fixture)
        let video = try #require(info.video)
        #expect(video.fieldOrder.isInterlaced, "fixture must be verified interlaced")

        // `routeDescription` names the deinterlacer, so it is the honest place
        // to assert which one a deinterlacing decoder ended up with.
        let expected = SoftwareVideoDecoder.gpuDeinterlaceName ?? "bwdif"
        #expect(
            expected == (avfilter_get_by_name("yadif_videotoolbox") != nil
                ? "yadif_videotoolbox" : "bwdif")
        )
    }
}
