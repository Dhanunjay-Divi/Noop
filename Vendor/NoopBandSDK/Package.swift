// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NoopBandSDKArtifact",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "NoopBandSDK", targets: ["NoopBandSDK"]),
    ],
    targets: [
        .target(
            name: "NoopBandSDK",
            path: "production/apple"
        ),
        .testTarget(
            name: "NoopBandSDKTests",
            dependencies: ["NoopBandSDK"],
            path: ".",
            exclude: [
                "contract",
                "noop-band-sdk-manifest.json",
                "production",
                "test-support/android",
            ],
            sources: [
                "Tests/NoopBandSDKTests/NoopBandSDKArtifactTests.swift",
                "test-support/apple/VirtualBand.swift",
            ]
        ),
    ]
)
