// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoleRebuild",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoleCore", targets: ["MoleCore"]),
        .executable(name: "MoleRebuild", targets: ["MoleRebuild"])
    ],
    targets: [
        .target(name: "MoleCore", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security"), .linkedFramework("AppKit"), .linkedFramework("SystemConfiguration")]),
        .executableTarget(name: "MoleRebuild", dependencies: ["MoleCore"], linkerSettings: [.linkedFramework("AppKit")]),
        .executableTarget(name: "MoleRebuildAdmin", dependencies: ["MoleCore"]),
        .testTarget(name: "MoleCoreTests", dependencies: ["MoleCore"]),
        .testTarget(name: "MoleAppTests", dependencies: ["MoleRebuild"])
    ],
    swiftLanguageModes: [.v5]
)
