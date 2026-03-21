// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nest",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "NestLib",
            path: "Sources/NestLib",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Nest",
            dependencies: ["NestLib", "Sparkle"],
            path: "Sources/Nest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NestTests",
            dependencies: ["NestLib"],
            path: "Tests/NestTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
