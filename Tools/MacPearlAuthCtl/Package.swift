// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPearlAuthCtl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacPearlAuthCtlCore", targets: ["MacPearlAuthCtlCore"]),
        .executable(name: "macpearl-authctl", targets: ["macpearl-authctl"]),
    ],
    targets: [
        .target(name: "MacPearlAuthCtlCore"),
        .executableTarget(name: "macpearl-authctl", dependencies: ["MacPearlAuthCtlCore"]),
        .testTarget(name: "MacPearlAuthCtlCoreTests", dependencies: ["MacPearlAuthCtlCore"]),
    ]
)
