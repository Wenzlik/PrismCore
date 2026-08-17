#if LIBFUZZER
import Foundation
import PrismCore

/// The coverage-guided entry point. libFuzzer's runtime provides `main` (which
/// is why `CorpusRunner` is compiled out of this shape) and calls this once
/// per generated input.
///
/// The target is chosen by `PRISMCORE_FUZZ_TARGET` rather than an argument
/// because libFuzzer owns the argument list. Resolved once — a per-call
/// dictionary lookup would be measurable at fuzzer call rates, and a fuzzer
/// that changes targets mid-run has no meaningful corpus anyway.
private let selectedTarget: @Sendable ([UInt8]) -> Void = {
    let name = ProcessInfo.processInfo.environment["PRISMCORE_FUZZ_TARGET"] ?? ""
    guard let target = FuzzTargets.all[name] else {
        let names = FuzzTargets.all.keys.sorted().joined(separator: ", ")
        fatalError("set PRISMCORE_FUZZ_TARGET to one of: \(names)")
    }
    return target
}()

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    guard let start, count > 0 else { return 0 }
    selectedTarget(Array(UnsafeBufferPointer(start: start, count: count)))
    return 0
}
#endif
