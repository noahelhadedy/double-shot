// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoubleShot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DoubleShot",
            path: "Sources/DoubleShot",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "DoubleShotTests", dependencies: ["DoubleShot"]),
    ]
)
