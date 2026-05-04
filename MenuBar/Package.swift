// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetmonMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NetmonMenuBar",
            path: "Sources/MenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
            ]
        )
    ]
)
