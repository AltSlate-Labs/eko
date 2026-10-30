// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "eko",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "EkoCore", targets: ["EkoCore"]),
        .executable(name: "eko", targets: ["eko"]),
        .executable(name: "EkoApp", targets: ["EkoApp"]),
    ],
    targets: [
        .target(name: "EkoCore"),
        .executableTarget(name: "eko", dependencies: ["EkoCore"]),
        .executableTarget(name: "EkoApp", dependencies: ["EkoCore"]),
        .testTarget(name: "EkoCoreTests", dependencies: ["EkoCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
