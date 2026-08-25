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
            ],
            // Toolchain-environment workaround (NOT a third-party dependency): this machine has
            // only Apple CommandLineTools. swift-testing's runtime ships there but is not on any
            // default @rpath, so the .xctest bundle fails to dlopen Testing.framework /
            // lib_TestingInterop.dylib. Embedding the two absolute CLT paths as rpaths lets
            // `swift test` load the swift-testing runtime and actually execute the suite. On a
            // full Xcode toolchain these paths are simply unused.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
