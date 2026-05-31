// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftIMAP",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(
            name: "SwiftIMAP",
            targets: ["SwiftIMAP"]
        ),
        .executable(
            name: "swift-imap-tester",
            targets: ["IMAPCLITool"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.3.0"),
        // HokuNZ-maintained fork pinned by semver. SwiftPM won't let a version-resolved package
        // depend on a branch/revision pin, so consumers pinning SwiftIMAP by any version
        // requirement (from:, exact:, ranges) couldn't resolve it; see issues #12, #13.
        .package(url: "https://github.com/HokuNZ/MimeParser.git", .upToNextMinor(from: "0.2.6"))
    ],
    targets: [
        .target(
            name: "SwiftIMAP",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "MimeParser", package: "MimeParser")
            ]
        ),
        .executableTarget(
            name: "IMAPCLITool",
            dependencies: [
                "SwiftIMAP",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "SwiftIMAPTests",
            dependencies: [
                "SwiftIMAP",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio")
            ]
        )
    ]
)
