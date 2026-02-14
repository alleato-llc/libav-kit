// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "libav-kit",
    platforms: [
        .macOS("14.4"),
    ],
    products: [
        .library(name: "LibAVKit", targets: ["LibAVKit"]),
    ],
    dependencies: [
        .package(url: "git@github.com:nycjv321/pickle-kit.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(path: "../tint"),
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg",
            pkgConfig: "libavcodec libavformat libavutil libswresample",
            providers: [
                .brew(["ffmpeg"]),
            ]
        ),
        .target(
            name: "LibAVKit",
            dependencies: ["CFFmpeg"],
            path: "Sources/LibAVKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "libav-play",
            dependencies: [
                "LibAVKit",
                .product(name: "Tint", package: "tint"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/libav-play"
        ),
        .testTarget(
            name: "LibAVKitTests",
            dependencies: [
                "LibAVKit",
                .product(name: "PickleKit", package: "pickle-kit"),
            ],
            path: "Tests/LibAVKitTests",
            resources: [
                .copy("Features"),
                .copy("Fixtures"),
            ]
        ),
    ]
)
