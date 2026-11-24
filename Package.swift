// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Picget",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Picget", path: "Picget"),
        .testTarget(name: "PicgetTests", dependencies: ["Picget"], path: "PicgetTests")
    ]
)
