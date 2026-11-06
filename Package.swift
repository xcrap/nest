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
        // Pure /etc/pf.conf editing rules, linked statically into the helper and tested by NestTests.
        .target(
            name: "NestPFCore",
            path: "Sources/NestPFCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NestPFHelper",
            dependencies: ["NestPFCore"],
            path: "Sources/NestPFHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "nestctl",
            dependencies: ["NestLib"],
            path: "Sources/NestCTL",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NestTests",
            dependencies: ["NestLib", "NestPFCore"],
            path: "Tests/NestTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
