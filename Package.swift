// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mooterm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mooterm", targets: ["mooterm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "mooterm",
            dependencies: ["SwiftTerm"],
            path: "Sources/mooterm",
            resources: [
                .copy("Resources/AppIcon.icns")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "mootermTests",
            dependencies: ["mooterm"],
            path: "Tests/mootermTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)