// swift-tools-version: 6.0
import Foundation
import PackageDescription

// TrueHD Atmos heights (`ObjectAudioRendering.heights`) need the Rust renderer
// in `Rust/TrueHDObjects`, built from its pinned sources by
// `Rust/TrueHDObjects/build-xcframework.sh` — the one binary this package
// carries beyond MPVKit's. Since 3.7.0 hosts resolve the zip attached to the
// release (`.binaryTarget(url:checksum:)`, as MPVKit does for FFmpeg); a local
// build of the framework, when present, wins for development. A release that
// rebuilds it attaches the new zip and updates the URL and checksum below.
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
    targets: [
        // A local build of the framework wins (development); otherwise the
        // released zip, checksum-pinned, which is what hosts resolve.
        linksTrueHDObjects
            ? .binaryTarget(name: "TrueHDObjects", path: trueHDObjectsPath)
            : .binaryTarget(
                name: "TrueHDObjects",
                url: "https://github.com/Wenzlik/PrismCore/releases/download/3.7.0/TrueHDObjects.xcframework.zip",
                checksum: "dd82f6b283fef499496f8ebe013a8808d542fa6cfe59c77824172dbf0faec6b7"
            ),
    ] + [
        .target(
            name: "PrismCore",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit"),
                "TrueHDObjects",
            ],
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
