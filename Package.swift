// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TeXSnap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TeXSnap",
            path: "Sources/TeXSnap"
        ),
    ]
)
