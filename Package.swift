// swift-tools-version: 6.0
import Foundation
import PackageDescription

// TrueHD Atmos heights (`ObjectAudioRendering.heights`) are COMPILED OUT by default
// (since 3.7.1): the default package neither fetches nor links the
// `TrueHDObjects` renderer, nor compiles the Swift that drives it. The sources stay in
// `Rust/TrueHDObjects` and behind `#if PRISMCORE_OBJECT_AUDIO`.
//
// Opt-in is an explicit build action of whoever builds it, from a local checkout only:
//
//   Rust/TrueHDObjects/build-xcframework.sh          # or --mac
//   PRISMCORE_OBJECT_AUDIO=1 swift build
//
// There is no remote binary URL: with the flag on, the framework must exist locally, or
// SwiftPM fails on the missing path. Lossless 7.1 and E-AC-3 (JOC) do not depend on this.
let objectAudio = Context.environment["PRISMCORE_OBJECT_AUDIO"] == "1"
let trueHDObjectsPath = "Rust/TrueHDObjects/build/TrueHDObjects.xcframework"
let objectAudioDefine: [SwiftSetting] = objectAudio ? [.define("PRISMCORE_OBJECT_AUDIO")] : []

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
        .target(
            name: "PrismCore",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit"),
            ] + (objectAudio ? ["TrueHDObjects"] : []),
            swiftSettings: [
                // v0 pragmatism for the C interop layer; the goal is .v6 once
                // the remux session's ownership story has settled.
                .swiftLanguageMode(.v5),
            ] + objectAudioDefine
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
            ],
            // The tests that drive the renderer itself exist only in the opt-in build.
            swiftSettings: objectAudioDefine
        ),
    ] + (objectAudio
        // Only with the opt-in flag (see the top of this file); never in the default graph.
        ? [.binaryTarget(name: "TrueHDObjects", path: trueHDObjectsPath)]
        : [])
)
