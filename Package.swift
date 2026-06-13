// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CleanShotClone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CleanShotClone",
            path: "Sources/CleanShotClone",
            linkerSettings: [
                // Embed Info.plist (camera/mic usage descriptions) into the bare
                // executable so TCC permission prompts work without an app bundle.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        )
    ]
)
