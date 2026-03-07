// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Minga",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "minga-mac",
            path: "Sources",
            resources: [
                .process("Renderer/Shaders.metal"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .testTarget(
            name: "MingaTests",
            dependencies: ["minga-mac"],
            path: "Tests"
        ),
    ]
)
