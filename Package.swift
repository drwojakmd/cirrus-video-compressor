// swift-tools-version:5.9
//
// Cirrus Video Compressor
//
//   CirrusCore  – UI-independent engine: probing, content analysis, planning,
//                encoder back-ends, target-size optimisation, VMAF.
//   CirrusApp   – the SwiftUI macOS application.
//   cirrus       – command-line driver for the engine (used by the test suite
//                and handy for scripting).
//   cirrus-tests – unit tests for the pure planning logic.
//
import PackageDescription

let package = Package(
    name: "CirrusVideoCompressor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CirrusApp", targets: ["CirrusApp"]),
        .executable(name: "cirrus", targets: ["cirrus"]),
        .library(name: "CirrusCore", targets: ["CirrusCore"]),
    ],
    targets: [
        .target(name: "CirrusCore", path: "Sources/CirrusCore"),
        .executableTarget(name: "CirrusApp", dependencies: ["CirrusCore"], path: "Sources/CirrusApp"),
        .executableTarget(name: "cirrus", dependencies: ["CirrusCore"], path: "Sources/cirrus"),
        // Unit tests as a plain executable (`swift run cirrus-tests`): works with Command Line
        // Tools alone, which ship neither XCTest nor a SwiftPM-visible Testing module.
        .executableTarget(name: "cirrus-tests", dependencies: ["CirrusCore"], path: "Sources/cirrus-tests"),
    ]
)
