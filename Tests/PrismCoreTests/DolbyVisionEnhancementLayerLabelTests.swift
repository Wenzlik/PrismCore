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

    // MARK: - Capture and commit, through the converter

    // A synthetic P7 access unit: RPU (unspec62), EL (unspec63), one VCL
    // slice (TRAIL_R). The RPU body is junk on purpose — the injected
    // processor stands in for libdovi, which is what lets these run without
    // a real P7 fixture.
    private let rpu: [UInt8] = [62 << 1, 0x01, 0xAA, 0xBB]
    private let el: [UInt8] = [63 << 1, 0x01, 0xCC]
    private let slice: [UInt8] = [1 << 1, 0x01, 0xDD]
    private let rewrittenRPU: [UInt8] = [62 << 1, 0x01, 0x81]

    private func lengthPrefixed(_ units: [[UInt8]]) -> [UInt8] {
        units.flatMap { unit in
            [0, 0, UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit
        }
    }

    private var packet: [UInt8] { lengthPrefixed([rpu, el, slice]) }

    private func converter(
        converted: [UInt8]?, elType: String?
    ) throws -> DolbyVisionRPUConverter {
        try #require(DolbyVisionRPUConverter(lengthSize: 4) { _ in (converted, elType) })
    }

    @Test("a FEL header is tallied once the packet's rewrite lands")
    func felCommittedWithRewrite() throws {
        let c = try converter(converted: rewrittenRPU, elType: "FEL")
        let out = c.convert(packet: packet)
        #expect(out == lengthPrefixed([rewrittenRPU, slice]))
        #expect(c.felRPUs == 1)
        #expect(c.melRPUs == 0)
        #expect(c.convertedRPUs == 1)
    }

    @Test("a MEL header is tallied as MEL")
    func melCommittedWithRewrite() throws {
        let c = try converter(converted: rewrittenRPU, elType: "MEL")
        _ = c.convert(packet: packet)
        #expect(c.felRPUs == 0)
        #expect(c.melRPUs == 1)
    }

    @Test("no el_type means neither counter moves")
    func unknownElTypeCountsNothing() throws {
        let c = try converter(converted: rewrittenRPU, elType: nil)
        _ = c.convert(packet: packet)
        #expect(c.convertedRPUs == 1)
        #expect(c.felRPUs == 0)
        #expect(c.melRPUs == 0)
    }

    @Test("a refused allocation commits no FEL; the next landed packet commits only its own")
    func refusedAllocationDoesNotCommitFEL() throws {
        let c = try converter(converted: rewrittenRPU, elType: "FEL")
        let rewrote = packet.withUnsafeBufferPointer { buffer in
            c.convert(packet: buffer, into: { _ in nil })
        }
        #expect(!rewrote)
        #expect(c.staleUnconvertedPackets == 1)
        #expect(c.felRPUs == 0)
        #expect(c.convertedRPUs == 0)

        // The refused packet's pending FEL must not leak into this one.
        #expect(c.convert(packet: packet) != nil)
        #expect(c.felRPUs == 1)
        #expect(c.convertedRPUs == 1)
        #expect(c.staleUnconvertedPackets == 1)
    }

    @Test("an RPU libdovi refuses still counts FEL — it is dropped, and the packet rewrite lands")
    func refusedRPUStillLabelsSource() throws {
        // Documented in `dispose`: the header describes the SOURCE, so a
        // refused RPU says which kind of P7 this is as well as a converted
        // one. "Committed only on a landed rewrite" is about the PACKET
        // rewrite, which here still happens (the RPU and EL are dropped).
        let c = try converter(converted: nil, elType: "FEL")
        let out = c.convert(packet: packet)
        #expect(out == lengthPrefixed([slice]))
        #expect(c.failedRPUs == 1)
        #expect(c.convertedRPUs == 0)
        #expect(c.felRPUs == 1)
        #expect(c.melRPUs == 0)
    }
}
