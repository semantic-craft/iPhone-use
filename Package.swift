// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iphone-use",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iphone-use", targets: ["iPhoneUse"])
    ],
    targets: [
        .executableTarget(
            name: "iPhoneUse",
            path: "Sources/iPhoneUse",
            exclude: [
                "README.md",
                "API/README.md",
                "App/README.md",
                "Bluetooth/README.md",
                "CLI/README.md",
                "Capture/README.md",
                "Devices/README.md",
                "Input/README.md",
                "Input/LegacyPointer/README.md",
                "Localization/README.md",
                "MCP/README.md",
                "Task/README.md",
                "UI/README.md",
                "USB/README.md",
            ],
            resources: [.copy("Resources/AppIcon.icns")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "iPhoneUseTests",
            dependencies: ["iPhoneUse"],
            path: "Tests/iPhoneUseTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
