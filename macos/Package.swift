// swift-tools-version: 6.0
import PackageDescription

// MyPLaMo SnapTrans for macOS. The UI (SnapTransApp) depends on UI-free modules:
//   SnapTransCore   – model catalog, download/verification, PFML3 prompt, OCR text joining, languages
//   SnapTransEngine – llama-server child process (loopback, random port, API key, PID check, engine hashes)
//   SnapTransOCR    – Vision text recognition
// Test-only code paths (debug commands, image injection, engine/guard overrides, raw engine log, profile override) are
// compiled only with SNAPTRANS_TEST_HOOKS: always in debug builds, and in release builds only when build-app.sh is run
// with --dev (it passes -Xswiftc -DSNAPTRANS_TEST_HOOKS). The distribution build never contains them.
let testHooks: [SwiftSetting] = [.define("SNAPTRANS_TEST_HOOKS", .when(configuration: .debug))]

let package = Package(
    name: "SnapTrans",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SnapTrans", targets: ["SnapTransApp"]),
        .executable(name: "snaptrans-engine-guard", targets: ["snaptrans-engine-guard"]),
        .executable(name: "snaptrans-cli", targets: ["snaptrans-cli"]),
        .library(name: "SnapTransCore", targets: ["SnapTransCore"]),
    ],
    targets: [
        .target(name: "SnapTransCore", resources: [.copy("Resources/catalog.json")], swiftSettings: testHooks),
        .target(name: "SnapTransEngine", dependencies: ["SnapTransCore"], resources: [.copy("Resources/engine-manifest.json")], swiftSettings: testHooks),
        .target(name: "SnapTransOCR", dependencies: ["SnapTransCore"], swiftSettings: testHooks),
        .executableTarget(name: "SnapTransApp", dependencies: ["SnapTransCore", "SnapTransEngine", "SnapTransOCR"], swiftSettings: testHooks),
        .executableTarget(name: "snaptrans-engine-guard"),
        .executableTarget(name: "snaptrans-cli", dependencies: ["SnapTransCore", "SnapTransEngine", "SnapTransOCR"], swiftSettings: testHooks),
        .testTarget(name: "SnapTransCoreTests", dependencies: ["SnapTransCore", "SnapTransEngine"]),
    ],
    swiftLanguageModes: [.v5]
)
