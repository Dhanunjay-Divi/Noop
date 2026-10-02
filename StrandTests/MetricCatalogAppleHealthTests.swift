import XCTest
@testable import Strand

final class MetricCatalogAppleHealthTests: XCTestCase {
    func testEveryPersistedAppleHealthMetricHasASourceQualifiedDescriptor() {
        let persistedKeys: Set<String> = [
            "resting_hr", "hrv", "spo2", "resp_rate", "avg_hr", "max_hr",
            "walking_hr", "steps", "active_kcal", "basal_kcal", "vo2max",
            "hydration", "weight", "body_fat", "lean_mass", "bmi", "body_temp",
            "wrist_temp", "asleep_min", "deep_min", "rem_min", "core_min",
            "awake_min", "in_bed_min",
        ]
        let catalogKeys = Set(
            MetricCatalog.all
                .filter { $0.source == "apple-health" }
                .map(\.key)
        )

        XCTAssertTrue(
            persistedKeys.isSubset(of: catalogKeys),
            "Missing Apple Health descriptors: \(persistedKeys.subtracting(catalogKeys).sorted())"
        )
    }

    func testAppleHealthAndBandMetricsRemainSourceDistinct() throws {
        let apple = try XCTUnwrap(
            MetricCatalog.metric(key: "hrv", source: "apple-health")
        )
        let band = try XCTUnwrap(
            MetricCatalog.metric(key: "hrv", source: "my-whoop")
        )

        XCTAssertNotEqual(apple.id, band.id)
        XCTAssertEqual(apple.sourceLabel, "Apple Health")
        XCTAssertEqual(band.sourceLabel, "Compatible band")
    }

    func testAppleSleepAndTemperatureSemanticsStaySeparate() throws {
        XCTAssertNotNil(MetricCatalog.metric(key: "asleep_min", source: "apple-health"))
        XCTAssertNotNil(MetricCatalog.metric(key: "awake_min", source: "apple-health"))
        XCTAssertNotNil(MetricCatalog.metric(key: "wrist_temp", source: "apple-health"))
        XCTAssertNotNil(MetricCatalog.metric(key: "skin_temp", source: "my-whoop"))
    }
}
