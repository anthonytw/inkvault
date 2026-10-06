// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sempere-core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Age", targets: ["Age"]),
        .library(name: "Sempere", targets: ["Sempere"]),
        .library(name: "SempereRender", targets: ["SempereRender"]),
        .library(name: "SempereImport", targets: ["SempereImport"]),
        .library(name: "SempereWebDAV", targets: ["SempereWebDAV"]),
        .executable(name: "sempere", targets: ["SempereCLI"]),
    ],
    dependencies: [
        // 4.0 adds X-Wing (ML-KEM-768 + X25519) and HPKE with it, for the
        // post-quantum age recipient (Sources/Age/MLKEM768X25519.swift).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]
        ),
        .target(
            name: "Age",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            // scrypt and X25519 are ~70x slower unoptimized: debug-build tests that
            // unlock a passphrase-wrapped key took minutes on CI (docs/HANDOFF.md "CI").
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "Sempere",
            dependencies: ["Age", "CZlib", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "SempereRender",
            dependencies: ["Sempere", "CZlib"]
        ),
        .target(
            name: "SempereImport",
            dependencies: ["Sempere", "CZlib", .product(name: "Crypto", package: "swift-crypto")]
        ),
        // The only target allowed network code (CLAUDE.md).
        .target(
            name: "SempereWebDAV",
            dependencies: ["Sempere", .product(name: "Crypto", package: "swift-crypto")]
        ),
        // Noto fonts for text in CLI exports (OFL 1.1); the app does not link them.
        .target(name: "SempereFonts", resources: [.copy("Fonts")]),
        .executableTarget(
            name: "SempereCLI",
            dependencies: [
                "Age", "Sempere", "SempereRender", "SempereImport", "SempereWebDAV", "SempereFonts",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Seeded mutation fuzzer shared by the test targets (Foundation only).
        .target(name: "FuzzSupport", path: "Tests/FuzzSupport"),
        .testTarget(name: "AgeTests", dependencies: ["Age", "CZlib", "FuzzSupport"],
                    resources: [.copy("Vectors")]),
        .testTarget(name: "SempereTests", dependencies: ["Sempere", "FuzzSupport"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SempereRenderTests", dependencies: ["SempereRender", "SempereFonts", "Age", "FuzzSupport"],
                    exclude: ["generate_sample_note.py", "generate_qr_vectors.py", "generate_image_fixtures.py", "generate_shaping_fixtures.py"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SempereImportTests",
                    dependencies: ["SempereImport", "Sempere", "SempereRender", "Age", "CZlib", "FuzzSupport"]),
        .testTarget(name: "SempereWebDAVTests", dependencies: ["SempereWebDAV", "Sempere", "Age", "FuzzSupport"]),
        .testTarget(name: "CLITests", dependencies: ["Age", "Sempere"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
