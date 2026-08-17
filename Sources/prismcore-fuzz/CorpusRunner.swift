#if !LIBFUZZER
import Foundation
import PrismCore

/// The standalone fuzzer: replay corpus files through a target, or hunt with
/// the seeded mutator for a bounded time.
///
/// Two modes because this machine class has two capabilities. Coverage-guided
/// libFuzzer (`LibFuzzerEntry`) is strictly better at *finding*, but Xcode's
/// Swift toolchain ships no fuzzer runtime — `-sanitize=fuzzer` is rejected
/// outright — so it needs a swift.org toolchain. `hunt` is the mode that runs
/// anywhere: blind mutation over the same seeds the smoke test uses, just for
/// as long as you give it. Every run prints its RNG seed up front, so a crash
/// reproduces with `hunt <target> <seconds> <seed>`.
@main
struct CorpusRunner {
    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let mode = arguments.isEmpty ? "" : arguments.removeFirst()

        switch mode {
        case "run":
            try replay(arguments)
        case "hunt":
            hunt(arguments)
        default:
            usage()
        }
    }

    private static func usage() -> Never {
        let names = FuzzTargets.all.keys.sorted().joined(separator: ", ")
        print(
            """
            usage: prismcore-fuzz run <target> <file-or-directory …>
                   prismcore-fuzz hunt <target|all> [seconds] [rng-seed]

            Targets: \(names)

            `run` replays saved inputs (e.g. a crash artifact) through a
            target. `hunt` mutates the built-in seed corpus for a bounded
            time (default 60 s per target), crashing on the first invariant
            violation; the printed rng-seed makes any crash reproducible.
            For coverage-guided fuzzing use a swift.org toolchain and the
            libFuzzer build in AGENTS.md — Xcode's toolchain has no fuzzer
            runtime.
            """
        )
        exit(64)  // EX_USAGE
    }

    // MARK: run

    private static func replay(_ arguments: [String]) throws {
        guard let targetName = arguments.first,
              let target = FuzzTargets.all[targetName]
        else { usage() }

        var inputs: [URL] = []
        for path in arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                FileHandle.standardError.write(Data("no such input: \(path)\n".utf8))
                exit(66)  // EX_NOINPUT
            }
            if isDirectory.boolValue {
                let children = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil
                )
                inputs.append(contentsOf: children.sorted { $0.path < $1.path })
            } else {
                inputs.append(url)
            }
        }
        guard !inputs.isEmpty else { usage() }

        for url in inputs {
            let bytes = [UInt8](try Data(contentsOf: url))
            // The file name prints BEFORE the run so a fatalError's abort
            // still identifies which input tripped it.
            print("\(targetName): \(url.lastPathComponent) (\(bytes.count) bytes)")
            target(bytes)
        }
        print("\(inputs.count) input(s), no invariant violated")
    }

    // MARK: hunt

    private static func hunt(_ arguments: [String]) {
        let requested = arguments.first ?? "all"
        let names = requested == "all"
            ? FuzzTargets.all.keys.sorted()
            : [requested]
        guard names.allSatisfy({ FuzzTargets.all[$0] != nil }) else { usage() }

        let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 60 : 60
        // Seeded from the clock unless told otherwise: a hunt WANTS fresh
        // territory each run, unlike the smoke test — reproducibility comes
        // from printing the seed, not from fixing it.
        let rngSeed = arguments.count > 2
            ? UInt64(arguments[2]) ?? 0
            : UInt64(Date().timeIntervalSince1970 * 1000)

        for name in names {
            let target = FuzzTargets.all[name]!
            let seeds = FuzzSeeds.corpus[name] ?? []
            var rng = SplitMix64(seed: rngSeed)
            print("hunt \(name): \(Int(seconds)) s, rng-seed \(rngSeed)")

            var executions = 0
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                // Checking the clock per input would dominate the parsers
                // themselves; a 4096-input batch is fractions of a second.
                for _ in 0..<4096 {
                    // Stacked mutations (1–4 rounds) drift further from the
                    // seed than the smoke test's single round — that distance
                    // is what a long run buys over CI.
                    var input = seeds.isEmpty
                        ? rng.bytes(count: Int(rng.next() % 512))
                        : seeds[Int(rng.next() % UInt64(seeds.count))]
                    for _ in 0...(rng.next() % 4) { input = rng.mutate(input) }
                    target(input)
                    executions += 1
                }
            }
            print("hunt \(name): \(executions) execution(s), no invariant violated")
        }
    }
}
#endif
