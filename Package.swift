// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "lua4swift",
    platforms: [.macOS(.v10_13), .iOS(.v12), .visionOS(.v1)],
    products: [
        .library(
            name: "lua4swift",
            targets: ["lua4swift"]),
        .library(name: "CLua", targets: ["CLua"])
    ],
    dependencies: [
        .package(url: "https://github.com/neoneye/SwiftyRelativePath", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "CLua",
            dependencies: [],
            path: "Sources/CLua",
            cSettings: [
                .define("LUA_USE_MACOSX", .when(platforms: [.macOS])),
                .define("LUA_USE_IOS", .when(platforms: [.iOS, .visionOS]))
            ]),
        .target(
            name: "lua4swift",
            dependencies: [
                "CLua",
                .product(
                    name: "SwiftyRelativePath",
                    package: "SwiftyRelativePath"
                ),
            ],
            path: "Sources/lua4swift"
        ),
        .testTarget(
            name: "lua4swiftTests",
            dependencies: [
                "lua4swift",
            ],
            resources: [
                .copy("Resources/test.lua")
            ]),
    ]
)
