// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "WeChatTweak",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "wechattweak",
            targets: [
                "WeChatTweak"
            ]
        ),
        .library(
            name: "WeChatTweakRuntime",
            type: .dynamic,
            targets: [
                "WeChatTweakRuntime"
            ]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0")
    ],
    targets: [
        .executableTarget(
            name: "WeChatTweak",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .target(
            name: "WeChatTweakRuntime",
            cxxSettings: [
                .unsafeFlags(["-std=gnu++17"])
            ],
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        )
    ]
)
