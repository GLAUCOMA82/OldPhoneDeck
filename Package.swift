// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OldPhoneDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "oldphonedeck",
            path: "Sources/oldphonedeck",
            resources: [.copy("web")],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
    ]
)
