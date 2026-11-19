// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipShelf",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ClipShelf", targets: ["ClipShelf"])],
    targets: [
        .executableTarget(name: "ClipShelf"),
        .testTarget(name: "ClipShelfTests", dependencies: ["ClipShelf"]),
    ]
)
