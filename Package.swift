// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneDeck",
    platforms: [.macOS(.v14)],
    targets: [
        // Declarations for macOS's private CGVirtualDisplay API (lives in CoreGraphics).
        .target(name: "CGVirtualDisplayPrivate", path: "Sources/CGVirtualDisplayPrivate"),
        .executableTarget(
            name: "phonedeck",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/phonedeck",
            exclude: ["Info.plist"],
            resources: [.copy("web")],
            linkerSettings: [
                // Embed Info.plist so privacy prompts (Calendar) have usage text in a command-line tool.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/phonedeck/Info.plist"]),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
