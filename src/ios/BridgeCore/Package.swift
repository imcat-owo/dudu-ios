// swift-tools-version: 6.1
import PackageDescription

// BridgeCore: 「桥」的平台无关内核层。
// 依赖：官方 MCP Swift SDK（精确 pin 0.12.1）+ apple/swift-nio（精确 pin，仅作
// HTTP 承载层，不在其上自创协议）。将来在 Linux CI 上跑构建与单测。
let package = Package(
    name: "BridgeCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.103.0"
        )
    ],
    targets: [
        .target(
            name: "BridgeCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: [
                "BridgeCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ]
        )
    ]
)
