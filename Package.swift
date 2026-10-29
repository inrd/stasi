// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stasi",
    platforms: [
        .macOS("14.2")
    ],
    targets: [
        .executableTarget(
            name: "Stasi",
            path: "Sources/Stasi"
        )
    ]
)
