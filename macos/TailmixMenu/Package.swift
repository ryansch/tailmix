// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TailmixMenu",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TailmixMenu", targets: ["TailmixMenu"]),
    ],
    targets: [
        // TailmixKit talks to tailmixd and decides what the menu shows. It has
        // no AppKit dependency, so its tests also run on Linux.
        .target(name: "TailmixKit"),
        .executableTarget(name: "TailmixMenu", dependencies: ["TailmixKit"]),
        .testTarget(name: "TailmixKitTests", dependencies: ["TailmixKit"]),
    ]
)
