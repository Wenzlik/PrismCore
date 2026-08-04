import Testing
@testable import PrismCore

/// `AudioClock` is where the software path's audio either abuts sample-exactly
/// or crackles, so every rule in its doc comment gets a test. No media needed —
/// that's the point of the type being pure.
@Suite("AudioClock")
struct AudioClockTests {

    /// 48 kHz, 100 ms tolerance — the decoder's own configuration.
    private func clock() -> AudioClock {
        AudioClock(sampleRate: 48_000)
    }

    @Test("Tolerance defaults to 100 ms of samples")
    func defaultTolerance() {
        #expect(AudioClock(sampleRate: 48_000).tolerance == 4_800)
        #expect(AudioClock(sampleRate: 44_100).tolerance == 4_410)
    }

    @Test("The first buffer anchors on the source, not on zero")
    func anchorsOnSource() {
        var clock = clock()
        // A pipeline that opened 60 s in: the source PTS is 2_880_000 samples,
        // and audio has to land there or it sits a minute away from the video.
        #expect(clock.timestamp(forSourceSample: 2_880_000, sampleCount: 1024) == 2_880_000)
        clock.commit()
        #expect(clock.nextSample == 2_880_000 + 1024)
    }

    /// The bug this type exists for: 1024 samples at 44.1 kHz is 23.2199 ms, so
    /// a 1 ms container timebase can only say 23 or 24 — and the rounding walks.
    /// Stamping those quantized values straight through leaves a gap or an
    /// overlap at every single buffer; the running count must not.
    @Test("Container-quantized timestamps produce sample-exact, abutting buffers")
    func absorbsContainerQuantization() {
        var clock = AudioClock(sampleRate: 44_100)
        let frameSamples = 1024
        var stamps: [Int64] = []
        for index in 0..<40 {
            // What Matroska would carry: the true time rounded to whole ms,
            // rescaled back to samples.
            let milliseconds = Int64((Double(index * frameSamples) / 44_100.0 * 1000).rounded())
            let quantized = milliseconds * 44_100 / 1000
            stamps.append(clock.timestamp(forSourceSample: quantized, sampleCount: frameSamples))
            clock.commit()
        }
        // Every buffer starts exactly where the previous one ended.
        for index in 1..<stamps.count {
            #expect(stamps[index] - stamps[index - 1] == Int64(frameSamples))
        }
        // And no re-anchor happened, so the timeline never drifts away from the
        // source either: 40 buffers later we are still where the source says.
        #expect(stamps.last == Int64(39 * frameSamples))
    }

    @Test("A gap larger than the tolerance re-anchors instead of being absorbed")
    func reanchorsAcrossGap() {
        var clock = clock()
        #expect(clock.timestamp(forSourceSample: 0, sampleCount: 4_800) == 0)
        clock.commit()
        // 150 ms later than predicted (predicted 4_800, actual 12_000): a real
        // hole in the audio, not quantization.
        #expect(clock.timestamp(forSourceSample: 12_000, sampleCount: 4_800) == 12_000)
        clock.commit()
        #expect(clock.nextSample == 16_800)
    }

    @Test("A jump inside the tolerance is absorbed, in both directions")
    func absorbsSmallJitter() {
        var clock = clock()
        _ = clock.timestamp(forSourceSample: 100_000, sampleCount: 1_024)
        clock.commit()
        // 50 ms late: still quantization/jitter territory, so the count wins.
        #expect(clock.timestamp(forSourceSample: 101_024 + 2_400, sampleCount: 1_024) == 101_024)
        clock.commit()
        // 50 ms early (an overlapping timestamp): same.
        #expect(clock.timestamp(forSourceSample: 102_048 - 2_400, sampleCount: 1_024) == 102_048)
    }

    @Test("A dropped buffer injects no phantom samples")
    func droppedBufferDoesNotAdvance() {
        var clock = clock()
        _ = clock.timestamp(forSourceSample: 0, sampleCount: 1_024)
        clock.commit()
        // This buffer never reaches the renderer: no commit.
        _ = clock.timestamp(forSourceSample: 1_024, sampleCount: 1_024)
        // The next one takes the slot the dropped buffer would have had, so the
        // timeline does not run ahead of the audio anybody heard.
        #expect(clock.timestamp(forSourceSample: 2_048, sampleCount: 1_024) == 1_024)
        clock.commit()
        #expect(clock.nextSample == 2_048)
    }

    @Test("Reset drops the anchor so the next buffer re-anchors")
    func resetDropsAnchor() {
        var clock = clock()
        _ = clock.timestamp(forSourceSample: 0, sampleCount: 1_024)
        clock.commit()
        clock.reset()
        #expect(clock.isAnchored == false)
        #expect(clock.nextSample == 0)
        // Post-seek: the source PTS is 30 s in and the clock follows it.
        #expect(clock.timestamp(forSourceSample: 1_440_000, sampleCount: 1_024) == 1_440_000)
    }

    @Test("Timestampless buffers keep counting and don't fake a gap afterwards")
    func toleratesMissingTimestamps() {
        var clock = clock()
        #expect(clock.timestamp(forSourceSample: nil, sampleCount: 1_024) == 0)
        clock.commit()
        #expect(clock.timestamp(forSourceSample: nil, sampleCount: 1_024) == 1_024)
        clock.commit()
        // A timestamp reappears: there is no prediction to compare against, so
        // it anchors rather than being judged a discontinuity of unknown size.
        #expect(clock.timestamp(forSourceSample: 500_000, sampleCount: 1_024) == 500_000)
    }

    @Test("Long runs don't drift: N buffers advance by exactly N × frame size")
    func noDrift() {
        var clock = clock()
        let frameSamples = 1_536
        for index in 0..<1_000 {
            // Perfectly regular source, expressed exactly.
            _ = clock.timestamp(forSourceSample: Int64(index * frameSamples), sampleCount: frameSamples)
            clock.commit()
        }
        #expect(clock.nextSample == Int64(1_000 * frameSamples))
    }
}
