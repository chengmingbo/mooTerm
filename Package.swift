// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mterm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mterm", targets: ["mterm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "mterm",
            dependencies: ["SwiftTerm"],
            path: "Sources/mterm",
            resources: [
                .copy("Resources/AppIcon.icns")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "mtermTests",
            dependencies: ["mterm"],
            path: "Tests/mtermTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)