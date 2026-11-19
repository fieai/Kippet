// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kippet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Kippet", targets: ["Kippet"])],
    targets: [
        .executableTarget(name: "Kippet"),
        .testTarget(name: "KippetTests", dependencies: ["Kippet"]),
    ]
)
