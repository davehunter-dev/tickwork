// swift-tools-version: 6.2

import PackageDescription

// Warnings in this package fail the build.
let warningsAsErrors: [SwiftSetting] = [.treatAllWarnings(as: .error)]

// The loop's board vocabulary, as a program rather than as shell.
//
// Nobody builds this by hand to run the loop. `install.sh` builds Tickwork's
// `main` into `~/.cache/tickwork/tool/` and puts `bin/tickwork` beside the
// build — see "Installing and updating" in docs/loop.md.
//
// **`BoardCore` is a library so that the tool can be tested.** An executable
// target's `main.swift` carries top-level code and nothing can import it, so
// everything that is not argument dispatch lives in the library and `board` is a
// shell over it. The split exists for parsing: `blockers` reads the
// `## Dependencies` section out of an issue body, and string handling with no
// tests is where the epic-link bug came from.
//
// `check-loop` is the second executable. A consumer's CI runs it against its
// `loop.json`, and this repository's CI against the sample in `Tests/`. Its
// rules are `BoardCore`'s, so `next` refuses exactly what it reports.
let package = Package(
    name: "Tickwork",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .target(
            name: "BoardCore",
            path: "Sources/BoardCore",
            swiftSettings: warningsAsErrors
        ),
        .executableTarget(
            name: "board",
            dependencies: ["BoardCore"],
            path: "Sources/board",
            swiftSettings: warningsAsErrors
        ),
        .executableTarget(
            name: "check-loop",
            dependencies: ["BoardCore"],
            path: "Sources/check-loop",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "BoardCoreTests",
            dependencies: ["BoardCore"],
            path: "Tests/BoardCoreTests",
            swiftSettings: warningsAsErrors
        ),
    ]
)
