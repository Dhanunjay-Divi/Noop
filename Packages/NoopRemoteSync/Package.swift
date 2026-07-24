// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoopRemoteSync",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "NoopRemoteSync", targets: ["NoopRemoteSync"]),
    ],
    dependencies: [
        .package(path: "../WhoopStore"),
    ],
    targets: [
        .target(name: "NoopRemoteSync", dependencies: ["WhoopStore"]),
        .testTarget(
            name: "NoopRemoteSyncTests",
            dependencies: ["NoopRemoteSync", "WhoopStore"]
        ),
    ]
)
