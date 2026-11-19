import Testing
@testable import PrismCore

/// The P7 FEL / MEL stats label. Pure on purpose: the FEL/MEL answer comes
/// from libdovi's RPU header, which these tests cannot assume is linked, so
/// they pin the two halves that are ours — the string mapping and the label
/// arithmetic — without it.
@Suite("Profile 7 FEL / MEL label")
struct DolbyVisionEnhancementLayerLabelTests {

    @Test("libdovi's el_type maps to FEL, MEL, or unknown — exact match only")
    func classifyElType() {
        #expect(DolbyVisionRPUConverter.classify(elType: "FEL") == .fel)
        #expect(DolbyVisionRPUConverter.classify(elType: "MEL") == .mel)
        // nil is what libdovi reports for a non-P7 RPU; a different spelling
        // is not something libdovi writes, so it is not guessed at either.
        #expect(DolbyVisionRPUConverter.classify(elType: nil) == nil)
        #expect(DolbyVisionRPUConverter.classify(elType: "fel") == nil)
        #expect(DolbyVisionRPUConverter.classify(elType: "") == nil)
    }

    private func stats(fel: Int, mel: Int) -> DolbyVisionConversionStats {
        DolbyVisionConversionStats(
            convertedRPUs: 10, failedRPUs: 0, droppedEnhancementLayerNALs: 10,
            felRPUs: fel, melRPUs: mel
        )
    }

    @Test("FEL RPUs label the stats FEL")
    func felLabel() {
        let s = stats(fel: 3, mel: 0)
        #expect(s.enhancementLayerType == .fel)
        #expect(s.statsLabel == "P7 FEL → 8.1")
    }

    @Test("only MEL RPUs label the stats MEL")
    func melLabel() {
        let s = stats(fel: 0, mel: 3)
        #expect(s.enhancementLayerType == .mel)
        #expect(s.statsLabel == "P7 MEL → 8.1")
    }

    @Test("a single FEL RPU outranks any number of MEL ones")
    func felWinsOverMel() {
        let s = stats(fel: 1, mel: 500)
        #expect(s.enhancementLayerType == .fel)
        #expect(s.statsLabel == "P7 FEL → 8.1")
    }

    @Test("no RPU said which, so the label stays generic")
    func unknownLabel() {
        let s = stats(fel: 0, mel: 0)
        #expect(s.enhancementLayerType == nil)
        #expect(s.statsLabel == "Profile 7 → 8.1")
    }

    @Test("the pre-label initializer still compiles and reads generic")
    func legacyInitializerIsGeneric() {
        let s = DolbyVisionConversionStats(
            convertedRPUs: 1, failedRPUs: 0, droppedEnhancementLayerNALs: 1,
            staleUnconvertedPackets: 0
        )
        #expect(s.felRPUs == 0)
        #expect(s.melRPUs == 0)
        #expect(s.statsLabel == "Profile 7 → 8.1")
    }

    @Test("isClean ignores the label: same tallies, same verdict")
    func isCleanIndependentOfLabel() {
        let fel = stats(fel: 5, mel: 0)
        let mel = stats(fel: 0, mel: 5)
        let none = stats(fel: 0, mel: 0)
        #expect(fel.isClean)
        #expect(fel.isClean == mel.isClean)
        #expect(mel.isClean == none.isClean)

        // And a dirty conversion stays dirty whatever the label says.
        let dirty = DolbyVisionConversionStats(
            convertedRPUs: 10, failedRPUs: 1, droppedEnhancementLayerNALs: 10, felRPUs: 5
        )
        #expect(!dirty.isClean)
    }
}
