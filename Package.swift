// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Posturr",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PosturrCore", targets: ["PosturrCore"])
    ],
    targets: [
        // Core logic library - testable, no main entry point
        .target(
            name: "PosturrCore",
            path: "Sources",
            exclude: ["App", "Icons"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMotion"),
                .linkedFramework("IOBluetooth")
            ]
        ),
        // Executable target
        .executableTarget(
            name: "Posturr",
            dependencies: ["PosturrCore"],
            path: "Sources/App"
        ),
        // Test target
        .testTarget(
            name: "PosturrTests",
            dependencies: ["PosturrCore"],
            path: "Tests"
        )
    ]
)
