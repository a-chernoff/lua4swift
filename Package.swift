// swift-tools-version:6.0

// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "lua4swift",
  platforms: [.macOS(.v10_13), .iOS(.v12), .visionOS(.v1)],
  products: [
    // Products define the executables and libraries a package produces, and make them visible to other packages.
    .library(
      name: "lua4swift",
      targets: ["lua4swift"]),
  ],
  dependencies: [
    // Dependencies declare other packages that this package depends on.
    // .package(url: /* package url */, from: "1.0.0"),
    .package(url: "https://github.com/a-chernoff/CLua", branch: "platform-support"),
    .package(url: "https://github.com/Quick/Quick", from: "7.6.2"),
    .package(url: "https://github.com/Quick/Nimble", from: "13.7.1")
  ],
  targets: [
    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
    // Targets can depend on other targets in this package, and on products in packages this package depends on.
    .target(
      name: "lua4swift",
      dependencies: [
        "CLua"
      ]),
    .testTarget(
      name: "lua4swiftTests",
      dependencies: [
        "lua4swift",
        "Quick",
        "Nimble"
      ]),
  ]
)
