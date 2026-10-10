// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Frame",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Frame", targets: ["Frame"]),
    ],
    targets: [
        // Localization, the interface language (InterfaceLanguage.swift is the family's shared file) and the engine of
        // the recordings: the writers, the edit, the compositor and the export (Engine/), tested without a screen
        .target(
            name: "FrameCore",
            path: "Sources/FrameCore"
        ),
        // The menu bar app: the icon, its menu and panel, Settings, updates, sounds; the recorder and the editor
        .executableTarget(
            name: "Frame",
            dependencies: ["FrameCore"],
            path: "Sources/Frame"
        ),
        .testTarget(
            name: "FrameTests",
            dependencies: ["Frame", "FrameCore"],
            path: "Tests/FrameTests"
        ),
    ]
)
