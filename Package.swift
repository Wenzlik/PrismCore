// swift-tools-version: 6.0
import Foundation
import PackageDescription

// TrueHD Atmos heights (`ObjectAudioRendering.heights`) need the Rust renderer
// in `Rust/TrueHDObjects`, built from its pinned sources by
// `Rust/TrueHDObjects/build-xcframework.sh` — the one binary this package
// carries beyond MPVKit's, part of the default package (3.7.0, and again since
// 3.7.2; heights stay off at runtime unless a host asks). Hosts resolve the zip
// attached to the release (`.binaryTarget(url:checksum:)`, as MPVKit does for FFmpeg); a local
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
        // FFmpeg (LGPL) as prebuilt xcframeworks: MPVKit 1.0.0 with FFmpeg
        // rebuilt from the same n8.1.2 source and configure line plus the
        // `eac3` encoder (the audio bridge's EAC3 5.1; stock MPVKit falls
        // back to AAC) and `yadif_videotoolbox`. libmpv and every other
        // binary stay upstream's 1.0.0. The fork keeps the package identity
        // `mpvkit` (the URL's last component) on purpose: a graph holds ONE
        // package per identity, so a host that also uses MPVKit for libmpv
        // still links one FFmpeg, and a host's local `MPVKit` checkout still
        // overrides this the way it overrode upstream. The URL, not the
        // version, is what selects the fork: a root package that names
        // upstream's URL wins the identity, and today fails this floor only
        // because upstream has no 1.0.1 yet. See README *Requirements*.
        .package(url: "https://github.com/Wenzlik/MPVKit.git", .upToNextMinor(from: "1.0.1")),
    ],
    targets: [
        // A local build of the framework wins (development); otherwise the
        // released zip, checksum-pinned, which is what hosts resolve.
        linksTrueHDObjects
            ? .binaryTarget(name: "TrueHDObjects", path: trueHDObjectsPath)
            : .binaryTarget(
                name: "TrueHDObjects",
                url: "https://github.com/Wenzlik/PrismCore/releases/download/3.9.0/TrueHDObjects.xcframework.zip",
                checksum: "5f65ad1b1864a31838ae998ba8902f569161656f555f23c81f2b470d01c7e895"
            ),
    ] + [
        .target(
            name: "PrismCore",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit"),
                "TrueHDObjects",
            ],
            // Apple's privacy manifest, so an app linking PrismCore declares
            // the required-reason APIs it uses (file timestamps: the keyframe
            // index cache; system uptime: stall and deadline clocks).
            resources: [.copy("PrivacyInfo.xcprivacy")],
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
