import XCTest
@testable import Strand

final class MetricCatalogStepsTests: XCTestCase {
    func testTodayStepsUsesMotionDerivedWhoopSeriesWhenAvailable() {
        let metric = MetricCatalog.todayStepsMetric(hasMotionDerivedSteps: true)

        XCTAssertEqual(metric?.key, "steps")
        XCTAssertEqual(metric?.source, "my-whoop")
        XCTAssertEqual(metric?.title, "Steps (motion estimate)")
        XCTAssertTrue(metric?.description?.contains("Not a validated pedometer count") == true)
    }

    func testTodayStepsUsesWhoopFourEstimateWhenMotionSeriesIsUnavailable() {
        let metric = MetricCatalog.todayStepsMetric(hasMotionDerivedSteps: false)

        XCTAssertEqual(metric?.key, "steps_est")
        XCTAssertEqual(metric?.source, "my-whoop")
    }

    /// #377 parity: with no measured strap count but an imported Apple Health count for the day, Today
    /// shows and taps through to the imported value — NOT the motion estimate.
    func testTodayStepsPrefersImportedAppleHealthOverEstimate() {
        let metric = MetricCatalog.todayStepsMetric(hasMotionDerivedSteps: false, hasImportedSteps: true)

        XCTAssertEqual(metric?.key, "steps")
        XCTAssertEqual(metric?.source, "apple-health")
    }

    func testMeasuredImportedStepsWinOverMotionDerivedEstimate() {
        let metric = MetricCatalog.todayStepsMetric(hasMotionDerivedSteps: true, hasImportedSteps: true)

        XCTAssertEqual(metric?.key, "steps")
        XCTAssertEqual(metric?.source, "apple-health")
        XCTAssertEqual(metric?.title, "Steps")
    }

    func testTodayStepsValueUsesMeasuredFirstThenBothFallbacks() {
        XCTAssertEqual(MetricCatalog.todayStepsValue(imported: 8_400, motionDerived: 7_100,
                                                     calibratedEstimate: 6_900), 8_400)
        XCTAssertEqual(MetricCatalog.todayStepsValue(imported: nil, motionDerived: 7_100,
                                                     calibratedEstimate: 6_900), 7_100)
        XCTAssertEqual(MetricCatalog.todayStepsValue(imported: nil, motionDerived: nil,
                                                     calibratedEstimate: 6_900), 6_900)
    }

    func testTodayStepsSeriesResolvesPrecedencePerDayWithoutDroppingFallbackDays() {
        let merged = MetricCatalog.todayStepsSeries(
            imported: [("2026-08-10", 8_400)],
            motionDerived: [("2026-08-10", 7_100), ("2026-08-11", 7_500)],
            calibratedEstimate: [("2026-08-10", 6_900), ("2026-08-11", 7_000),
                                 ("2026-08-12", 6_200)]
        )
        XCTAssertEqual(merged.map(\.day), ["2026-08-10", "2026-08-11", "2026-08-12"])
        XCTAssertEqual(merged.map(\.value), [8_400, 7_500, 6_200])
    }

    func testAppleHealthStepsRemainsAnIndependentCatalogMetric() {
        let metric = MetricCatalog.metric(key: "steps", source: "apple-health")

        XCTAssertEqual(metric?.id, "apple-health:steps")
    }

    /// Both WHOOP motion estimates must be resolvable by EXACT source, so the
    /// Today card/tile can route to them (via `.metricSourced` / `todayStepsMetric`) without depending on
    /// catalog declaration order.
    func testWhoopStepsAreResolvableBySource() {
        XCTAssertEqual(MetricCatalog.metric(key: "steps", source: "my-whoop")?.id, "my-whoop:steps")
        XCTAssertEqual(MetricCatalog.metric(key: "steps_est", source: "my-whoop")?.id, "my-whoop:steps_est")
    }

    /// Regression guard: the bare-key `first { $0.key == "steps" }` resolvers that are NOT source-aware
    /// (LabBookView's correlation descriptors, CompareView's default/legacy picks, the TabRoute `.metric`
    /// fallback) must keep resolving Apple Health, exactly as before the measured-WHOOP entry was added.
    /// The measured entry is declared AFTER apple-health precisely so it never captures these lookups —
    /// the Today surface reaches it explicitly instead. If a future edit reorders the catalog, this fails
    /// loudly rather than silently emptying those screens for an Apple-Health-steps user.
    func testBareKeyStepsResolutionStaysAppleHealth() {
        XCTAssertEqual(MetricCatalog.all.first(where: { $0.key == "steps" })?.source, "apple-health")
    }

    /// A catalog row describes a namespace, not necessarily the producer of every resolved point.
    /// `my-whoop` can resolve to measured strap data or a `-noop` computed sibling, so it must never
    /// present an independent score as if it were an official imported value.
    func testSourceLabelsKeepIndependentAndOfficialSeriesDistinct() {
        XCTAssertEqual(
            MetricCatalog.metric(key: "recovery", source: "my-whoop")?.sourceLabel,
            "Noop Band"
        )

        let official = MetricDescriptor(
            key: "recovery",
            title: "Recovery",
            category: "Charge",
            unit: "%",
            source: "whoop-official-reference",
            icon: "heart",
            decimals: 0,
            higherIsBetter: true
        )
        XCTAssertEqual(official.sourceLabel, "Imported")
    }

    func testMetricEmptyStateCopyNamesTheDescriptorSource() {
        let apple = MetricCatalog.metric(key: "weight", source: "apple-health")!
        XCTAssertTrue(MetricEmptyStateCopy.message(for: apple).contains("Apple Health"))
        XCTAssertFalse(MetricEmptyStateCopy.message(for: apple).contains("WHOOP export"))

        let strap = MetricCatalog.metric(key: "hrv", source: "my-whoop")!
        XCTAssertTrue(MetricEmptyStateCopy.message(for: strap).contains("connected band"))
    }
}
