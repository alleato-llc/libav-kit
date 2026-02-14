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
        .package(url: "git@github.com:aalleato/pickle-kit.git", branch: "main"),
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
