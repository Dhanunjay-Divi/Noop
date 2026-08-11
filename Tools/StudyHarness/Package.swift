// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoopStudyHarness",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NoopStudyCore", targets: ["NoopStudyCore"]),
        .executable(name: "noop-study", targets: ["NoopStudyCLI"]),
    ],
    dependencies: [
        .package(path: "../../Packages/StrandImport"),
        .package(path: "../../Packages/StrandAnalytics"),
    ],
    targets: [
        .target(
            name: "NoopStudyCore",
            dependencies: ["StrandImport", "StrandAnalytics"]
        ),
        .executableTarget(
            name: "NoopStudyCLI",
            dependencies: ["NoopStudyCore"]
        ),
        .testTarget(
            name: "NoopStudyCoreTests",
            dependencies: ["NoopStudyCore", "StrandImport", "StrandAnalytics"]
        ),
    ]
)
