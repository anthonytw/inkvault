// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "inkvault-core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Age", targets: ["Age"]),
        .library(name: "InkVault", targets: ["InkVault"]),
        .library(name: "InkRender", targets: ["InkRender"]),
        .library(name: "InkImport", targets: ["InkImport"]),
        .library(name: "InkWebDAV", targets: ["InkWebDAV"]),
        .executable(name: "inkvault", targets: ["InkVaultCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
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
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "InkVault",
            dependencies: ["Age", "CZlib", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "InkRender",
            dependencies: ["InkVault", "CZlib"]
        ),
        .target(
            name: "InkImport",
            dependencies: ["InkVault", "CZlib"]
        ),
        // The only target allowed network code (CLAUDE.md).
        .target(
            name: "InkWebDAV",
            dependencies: ["InkVault", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .executableTarget(
            name: "InkVaultCLI",
            dependencies: [
                "Age", "InkVault", "InkRender", "InkImport", "InkWebDAV",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AgeTests", dependencies: ["Age", "CZlib"],
                    resources: [.copy("Vectors")]),
        .testTarget(name: "InkVaultTests", dependencies: ["InkVault"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "InkRenderTests", dependencies: ["InkRender"],
                    exclude: ["generate_sample_note.py"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "InkImportTests", dependencies: ["InkImport", "InkVault", "InkRender", "Age", "CZlib"]),
        .testTarget(name: "InkWebDAVTests", dependencies: ["InkWebDAV", "InkVault", "Age"]),
        .testTarget(name: "CLITests", dependencies: ["Age", "InkVault"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
