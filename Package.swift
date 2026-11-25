// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nooklet",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nooklet", targets: ["Nooklet"]),
        .executable(name: "NookletFinderExtension", targets: ["NookletFinderExtension"]),
        .library(name: "NookletCore", targets: ["NookletCore"]),
    ],
    targets: [
        .target(name: "NookletCore", resources: [.process("Resources")]),
        .target(name: "NookletMenuBarBridge"),
        .executableTarget(
            name: "Nooklet",
            dependencies: ["NookletCore", "NookletMenuBarBridge"],
            resources: [.copy("Resources/BundledPlugins"), .copy("Resources/RunCat")]
        ),
        .executableTarget(
            name: "NookletFinderExtension",
            dependencies: ["NookletCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(name: "NookletChecks", dependencies: ["NookletCore"], path: "Tests/NookletCoreTests"),
    ]
)
