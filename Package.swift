// swift-tools-version:5.9
import PackageDescription

// MPCKit is the platform-neutral core (SSH transport, storage rules, file operations).
// It builds and is tested on Linux as well as macOS. The SwiftUI app only exists on macOS.
var products: [Product] = [
    .library(name: "MPCKit", targets: ["MPCKit"]),
]

var targets: [Target] = [
    .target(name: "MPCKit", path: "Sources/MPCKit"),
    .testTarget(name: "MPCKitTests", dependencies: ["MPCKit"], path: "Tests/MPCKitTests"),
]

#if os(macOS)
products.append(.executable(name: "MPCLoader", targets: ["MPCLoader"]))
targets.append(
    .executableTarget(
        name: "MPCLoader",
        dependencies: ["MPCKit"],
        path: "Sources/MPCLoader"
    )
)
#endif

let package = Package(
    name: "MPCLoader",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
