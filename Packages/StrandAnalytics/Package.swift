// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandAnalytics",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "StrandAnalytics", targets: ["StrandAnalytics"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(path: "../WhoopStore"),
    ],
    targets: [
        .target(name: "StrandAnalytics", dependencies: ["WhoopProtocol", "WhoopStore"]),
        .testTarget(
            name: "StrandAnalyticsTests",
            dependencies: ["StrandAnalytics", "WhoopStore"],
            // Real recorded R-R intervals used by RhythmScreenerRealDataTests. Declared so SwiftPM stops
            // warning about an unhandled file; the test reads it via #filePath, not the bundle.
            resources: [.copy("Resources/rhythm_real_rr.json")]
        ),
    ]
)
