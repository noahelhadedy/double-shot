// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoubleShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DoubleShot", targets: ["DoubleShot"]),
        .library(name: "DoubleShotCore", targets: ["DoubleShotCore"]),
    ],
    targets: [
        .target(name: "DoubleShotCore", path: "Sources/DoubleShotCore"),
        .executableTarget(
            name: "DoubleShot",
            dependencies: ["DoubleShotCore"],
            path: "Sources/DoubleShot",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "DoubleShotCoreTests",
            dependencies: ["DoubleShotCore"],
            path: "Tests/DoubleShotCoreTests"
        ),
    ]
)
