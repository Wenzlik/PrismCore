// swift-tools-version: 6.0
import Foundation
import PackageDescription

// TrueHD Atmos heights (`ObjectAudioRendering.heights`) need the Rust renderer
// in `Rust/TrueHDObjects`, built from its pinned sources by
// `Rust/TrueHDObjects/build-xcframework.sh` — the one binary this package
// carries beyond MPVKit's, so it is linked only when it has been built.
// Without it PrismCore builds and behaves exactly as before: TrueHD keeps its
// 7.1 bridge and `ObjectAudioRendering.isAvailable` is false. A release that
// ships it publishes the script's zip and switches this to
// `.binaryTarget(name:url:checksum:)`, as MPVKit does for FFmpeg.
let trueHDObjectsPath = "Rust/TrueHDObjects/build/TrueHDObjects.xcframework"
let linksTrueHDObjects = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/" + trueHDObjectsPath
)

let package = Package(
    name: "PrismCore",
    platforms: [
        // Matches Aether's floors.
        .iOS(.v16),
        .tvOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "PrismCore", targets: ["PrismCore"]),
        // A macOS diagnostic tool, not something a host links: probe, serve,
        // bench and verify a source from a terminal, so a field report can be
        // reproduced without a device build. See AGENTS.md *Measuring*.
        .executable(name: "prismcore-cli", targets: ["prismcore-cli"]),
    ],
    dependencies: [
        // FFmpeg (LGPL) as prebuilt xcframeworks — the same package Aether
        // already ships for the Prism (libmpv) engine, so integrating apps add
        // ZERO new binary dependencies. Aether overrides this with its local
        // Vendor/MPVKitLocal fork (same package identity) at integration time.
        .package(url: "https://github.com/mpvkit/MPVKit.git", .upToNextMinor(from: "1.0.0")),
    ],
    targets: (linksTrueHDObjects ? [.binaryTarget(name: "TrueHDObjects", path: trueHDObjectsPath)] : []) + [
        .target(
            name: "PrismCore",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit"),
            ] + (linksTrueHDObjects ? ["TrueHDObjects"] : []),
            swiftSettings: [
                // v0 pragmatism for the C interop layer; the goal is .v6 once
                // the remux session's ownership story has settled.
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "prismcore-fuzz",
            dependencies: ["PrismCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "prismcore-cli",
            dependencies: ["PrismCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "PrismCoreTests",
            // The CLI too, so its stop handling is tested against the same
            // fixtures and scripted origins as the library (`@testable
            // import prismcore_cli`; SwiftPM links an executable into tests).
            dependencies: ["PrismCore", "prismcore-cli"],
            resources: [
                // Synthetic A/V fixtures (ffmpeg-generated testsrc2 + sine,
                // seconds long) — enough to prove the remux round-trip and to
                // pin each routing outcome to a real container. The claims fixtures CAN'T carry — Atmos
                // (EAC3+JOC needs a real object-audio encode) and Dolby
                // Vision (real RPUs) — stay manual smoke tests on real media.
                .copy("Fixtures"),
            ]
        ),
    ]
)
