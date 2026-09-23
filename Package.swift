// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mterm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mterm", targets: ["mterm"]),
    ],
    dependencies: [
        // SwiftTerm 1.2.3 hits a Swift 6.1.2 (CommandLineTools) compiler bug
        // when any NSObject subclass conforms to LocalProcessTerminalViewDelegate:
        // "type does not conform to protocol" with byte-identical method
        // signatures. Re-enable once the toolchain catches up.
        // .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "mterm",
            dependencies: [],
            path: "Sources/mterm",
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