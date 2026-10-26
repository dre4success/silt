// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Silt",
    platforms: [.macOS(.v15)],
    targets: [
        // Everything that touches the disk lives here, with no UI, so the CLI and tests share it.
        .target(name: "SiltCore", linkerSettings: [.linkedFramework("CoreServices")]),
        .executableTarget(name: "Silt", dependencies: ["SiltCore"]),
        .executableTarget(name: "silt-scan", dependencies: ["SiltCore"]),
        // The app target too, so tests can drive AppModel's clearing logic.
        .testTarget(name: "SiltCoreTests", dependencies: ["SiltCore", "Silt"]),
    ]
)
