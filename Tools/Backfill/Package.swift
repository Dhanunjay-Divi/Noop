// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "backfill",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandImport"),
        .package(path: "../../Packages/WhoopStore"),
        .package(path: "../../Packages/WhoopProtocol"),
    ],
    targets: [
        .executableTarget(name: "backfill", dependencies: ["StrandImport", "WhoopStore"]),
        .target(
            name: "HistoryHarnessCore",
            dependencies: ["WhoopStore", "WhoopProtocol"]
        ),
        .executableTarget(
            name: "history-harness",
            dependencies: ["HistoryHarnessCore"]
        ),
        .testTarget(
            name: "HistoryHarnessCoreTests",
            dependencies: ["HistoryHarnessCore"]
        ),
    ]
)
