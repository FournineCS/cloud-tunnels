// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CloudTunnels",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CloudTunnels", targets: ["CloudTunnels"]),
        .executable(name: "ctun", targets: ["ctun"]),
        .executable(name: "CloudTunnelsProxyHelper", targets: ["CloudTunnelsProxyHelper"]),
        .library(name: "TunnelCore", targets: ["TunnelCore"]),
        .library(name: "ProxyHelperShared", targets: ["ProxyHelperShared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "TunnelCore",
            path: "Sources/TunnelCore"
        ),
        .target(
            name: "ProxyHelperShared",
            path: "Sources/ProxyHelperShared"
        ),
        .executableTarget(
            name: "CloudTunnels",
            dependencies: [
                "TunnelCore",
                "ProxyHelperShared",
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Sources/CloudTunnels"
        ),
        .executableTarget(
            name: "ctun",
            dependencies: [
                "TunnelCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ctun"
        ),
        .executableTarget(
            name: "CloudTunnelsProxyHelper",
            dependencies: [
                "ProxyHelperShared",
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Sources/CloudTunnelsProxyHelper"
        ),
        .testTarget(
            name: "CloudTunnelsTests",
            dependencies: [
                "CloudTunnels",
                "TunnelCore",
                "ProxyHelperShared",
                "CloudTunnelsProxyHelper",
            ],
            path: "Tests/CloudTunnelsTests"
        ),
    ]
)
