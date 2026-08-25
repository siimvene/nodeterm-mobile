// swift-tools-version:6.0
import PackageDescription

// NodetermKit is the dependency-free, platform-neutral core: wire types (SPEC §11) and the
// fixed protocols (SPEC §5/§7/§8) that the five parallel builders implement against.
// It MUST stay free of third-party dependencies (SwiftTerm lives in the App target only).
let package = Package(
    name: "NodetermKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "NodetermKit", targets: ["NodetermKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "NodetermKit",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "NodetermKitTests",
            dependencies: ["NodetermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
