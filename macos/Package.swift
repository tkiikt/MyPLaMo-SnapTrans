// swift-tools-version: 6.0
import PackageDescription

// MyPLaMo SnapTrans for macOS. The UI (SnapTransApp) depends on UI-free modules:
//   SnapTransCore   – model catalog, download/verification, PFML3 prompt, OCR text joining, languages
//   SnapTransEngine – llama-server child process (loopback, random port, API key, PID check, engine hashes)
//   SnapTransOCR    – Vision text recognition
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
        .target(name: "SnapTransCore", resources: [.copy("Resources/catalog.json")]),
        .target(name: "SnapTransEngine", dependencies: ["SnapTransCore"], resources: [.copy("Resources/engine-manifest.json")]),
        .target(name: "SnapTransOCR", dependencies: ["SnapTransCore"]),
        .executableTarget(name: "SnapTransApp", dependencies: ["SnapTransCore", "SnapTransEngine", "SnapTransOCR"]),
        .executableTarget(name: "snaptrans-engine-guard"),
        .executableTarget(name: "snaptrans-cli", dependencies: ["SnapTransCore", "SnapTransEngine", "SnapTransOCR"]),
        .testTarget(name: "SnapTransCoreTests", dependencies: ["SnapTransCore", "SnapTransEngine"]),
    ],
    swiftLanguageModes: [.v5]
)
