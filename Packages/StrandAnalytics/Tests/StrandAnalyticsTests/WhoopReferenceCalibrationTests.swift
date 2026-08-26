import XCTest
@testable import StrandAnalytics
import WhoopStore

final class WhoopReferenceCalibrationTests: XCTestCase {

    func testCurrentChargeAlgorithmContractIsV2() {
        XCTAssertEqual(NoopScoreAlgorithmRevision.charge, "noop-charge-v2")
        XCTAssertEqual(NoopScoreAlgorithmRevision.effort, "noop-effort-v1")
        XCTAssertEqual(NoopScoreAlgorithmRevision.rest, "noop-rest-v1")
    }

    private func day(_ offset: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let date = calendar.date(byAdding: .day, value: offset, to: start)!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func observations(
        count: Int,
        metric: WhoopComparableMetric = .recoveryScore,
        algorithm: String = "charge-v1",
        noop: (Int) -> Double,
        official: (Int) -> Double
    ) -> [ReferenceMetricObservation] {
        (0..<count).flatMap { i in
            [
                .whoopExport(day: day(i), metric: metric, value: official(i),
                             schemaRevision: "whoop-import-v1"),
                .noopComputed(day: day(i), metric: metric, value: noop(i),
                              algorithmVersion: algorithm),
            ]
        }
    }

    func testPairsExactDaysAndAuditsUnsafeRows() {
        var rows = observations(count: 3, noop: { Double(10 + $0) },
                                official: { Double(11 + $0) })
        // Duplicate official day: the whole ambiguous day is excluded.
        rows.append(.whoopExport(day: day(0), metric: .recoveryScore, value: 99))
        // Different NOOP algorithm revision never mixes into this report.
        rows.append(.noopComputed(day: day(1), metric: .recoveryScore, value: 30,
                                  algorithmVersion: "charge-v2"))
        // Wrong metric, invalid day and implausible value.
        rows.append(.noopComputed(day: day(2), metric: .restScore, value: 50,
                                  algorithmVersion: "charge-v1"))
        rows.append(.noopComputed(day: "2026-02-31", metric: .recoveryScore, value: 50,
                                  algorithmVersion: "charge-v1"))
        rows.append(.whoopExport(day: day(3), metric: .recoveryScore, value: 101))

        let result = WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: rows, noopAlgorithmVersion: "charge-v1")

        XCTAssertEqual(result.pairs.map(\.day), [day(1), day(2)])
        XCTAssertEqual(result.audit.pairedDays, 2)
        XCTAssertEqual(result.audit.duplicateOfficialDays, 1)
        XCTAssertEqual(result.audit.wrongNoopAlgorithmVersion, 1)
        XCTAssertEqual(result.audit.invalidOrWrongMetric, 3)
        XCTAssertEqual(result.pairs[0].official.provenance,
                       .whoopCSVExport(schemaRevision: "whoop-import-v1"))
        XCTAssertEqual(result.pairs[0].noop.provenance,
                       .noopOnDevice(algorithmVersion: "charge-v1"))
    }

    func testStatisticsUseNoopMinusOfficialAndCorrelationIsSafe() {
        let official = [10.0, 20.0, 30.0]
        let noop = [12.0, 18.0, 33.0]
        let rows = observations(count: 3, noop: { noop[$0] }, official: { official[$0] })

        let stats = WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: rows,
            noopAlgorithmVersion: "charge-v1").statistics!

        XCTAssertEqual(stats.sampleCount, 3)
        XCTAssertEqual(stats.firstDay, day(0))
        XCTAssertEqual(stats.lastDay, day(2))
        XCTAssertEqual(stats.officialMean, 20, accuracy: 1e-12)
        XCTAssertEqual(stats.noopMean, 21, accuracy: 1e-12)
        XCTAssertEqual(stats.bias, 1, accuracy: 1e-12)
        XCTAssertEqual(stats.meanAbsoluteError, 7.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(stats.rootMeanSquaredError, (17.0 / 3.0).squareRoot(), accuracy: 1e-12)
        XCTAssertNotNil(stats.correlation)
        XCTAssertGreaterThan(stats.correlation!, 0.95)
    }

    func testCorrelationIsNilForConstantOrTooShortSeries() {
        let constant = observations(count: 5, noop: { _ in 50 }, official: { Double(40 + $0) })
        let constantStats = WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: constant,
            noopAlgorithmVersion: "charge-v1").statistics!
        XCTAssertNil(constantStats.correlation)

        let short = observations(count: 2, noop: { Double($0) + 50 },
                                 official: { Double($0) + 55 })
        XCTAssertNil(WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: short,
            noopAlgorithmVersion: "charge-v1").statistics!.correlation)
    }

    func testValidatedCalibrationUsesChronologicalHoldoutAndPreservesRawValue() {
        // Official reference follows 5 + 1.2 × raw NOOP. The last ten days are never used to fit.
        let rows = observations(count: 40, noop: { Double(20 + $0) },
                                official: { 5 + 1.2 * Double(20 + $0) })
        let config = PersonalCalibrationConfiguration(
            minimumPairs: 30, minimumTrainingPairs: 20, minimumHoldoutPairs: 8,
            holdoutFraction: 0.25, minimumTrainingCorrelation: 0.5,
            minimumRelativeMAEImprovement: 0.05)
        let result = WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: rows, noopAlgorithmVersion: "charge-v1",
            configuration: config)

        XCTAssertEqual(result.calibration.decision, .validated)
        XCTAssertEqual(result.calibration.confidence, .validated)
        let validation = result.calibration.validation!
        XCTAssertEqual(validation.trainingCount, 30)
        XCTAssertEqual(validation.holdoutCount, 10)
        XCTAssertEqual(validation.trainingLastDay, day(29))
        XCTAssertEqual(validation.holdoutFirstDay, day(30))
        XCTAssertLessThan(validation.calibratedHoldoutMAE, 1e-10)
        XCTAssertGreaterThan(validation.relativeMAEImprovement, 0.99)

        let model = result.calibration.model!
        XCTAssertEqual(model.intercept, 5, accuracy: 1e-10)
        XCTAssertEqual(model.slope, 1.2, accuracy: 1e-10)

        let raw = ReferenceMetricObservation.noopComputed(
            day: day(50), metric: .recoveryScore, value: 60,
            algorithmVersion: "charge-v1")
        let calibrated = model.apply(to: raw)!
        XCTAssertEqual(calibrated.rawNoopValue, 60, accuracy: 0)
        XCTAssertEqual(calibrated.calibratedValue, 77, accuracy: 1e-10)
        XCTAssertEqual(calibrated.rawProvenance, .noopOnDevice(algorithmVersion: "charge-v1"))
        XCTAssertEqual(calibrated.calibratedProvenance,
                       .noopPersonalCalibration(modelVersion: "noop-personal-affine-v1",
                                                basedOnAlgorithmVersion: "charge-v1"))
    }

    func testCalibrationRejectsModelThatFailsLaterHoldoutDays() {
        // Training looks like official = raw + 10, but the unseen final ten days flip to raw - 10.
        // A random/in-sample validation would bless this; the chronological holdout must reject it.
        let rows = observations(
            count: 40,
            noop: { Double(30 + $0) },
            official: { i in i < 30 ? Double(40 + i) : Double(20 + i) })
        let config = PersonalCalibrationConfiguration(
            minimumPairs: 30, minimumTrainingPairs: 20, minimumHoldoutPairs: 8,
            holdoutFraction: 0.25, minimumTrainingCorrelation: 0.5,
            minimumRelativeMAEImprovement: 0.05)
        let result = WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: rows, noopAlgorithmVersion: "charge-v1",
            configuration: config)

        XCTAssertEqual(result.calibration.decision, .failedHoldoutValidation)
        XCTAssertNil(result.calibration.model)
        XCTAssertNotNil(result.calibration.validation)
        XCTAssertGreaterThan(result.calibration.validation!.calibratedHoldoutMAE,
                             result.calibration.validation!.rawHoldoutMAE)
    }

    func testCalibrationNeedsEnoughPairsAndRejectsDegenerateInputs() {
        let tooFew = observations(count: 12, noop: { Double(30 + $0) },
                                  official: { Double(35 + $0) })
        var result = WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: tooFew, noopAlgorithmVersion: "charge-v1")
        XCTAssertEqual(result.calibration.decision, .insufficientData)
        XCTAssertNil(result.calibration.model)

        let constant = observations(count: 30, noop: { _ in 50 },
                                    official: { Double(20 + $0) })
        let config = PersonalCalibrationConfiguration(
            minimumPairs: 28, minimumTrainingPairs: 21, minimumHoldoutPairs: 7)
        result = WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: constant,
            noopAlgorithmVersion: "charge-v1", configuration: config)
        XCTAssertEqual(result.calibration.decision, .degenerateTrainingData)
        XCTAssertNil(result.calibration.model)
    }

    func testModelCannotCrossMetricOrAlgorithmRevision() {
        let rows = observations(count: 40, noop: { Double(20 + $0) },
                                official: { 5 + 1.2 * Double(20 + $0) })
        let model = WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: rows,
            noopAlgorithmVersion: "charge-v1").calibration.model!

        XCTAssertNil(model.apply(to: .noopComputed(
            day: day(50), metric: .restScore, value: 60, algorithmVersion: "charge-v1")))
        XCTAssertNil(model.apply(to: .noopComputed(
            day: day(50), metric: .recoveryScore, value: 60, algorithmVersion: "charge-v2")))
        XCTAssertNil(model.apply(to: .noopComputed(
            day: day(50), metric: .recoveryScore, value: 101, algorithmVersion: "charge-v1")))
    }

    func testCalibratedScoreIsClampedToMetricRange() {
        // 2× is learned perfectly while every paired official value still lives inside 0...100.
        let rows = observations(count: 40, noop: { Double(10 + $0) },
                                official: { 2 * Double(10 + $0) })
        let config = PersonalCalibrationConfiguration(
            minimumPairs: 28, minimumTrainingPairs: 21, minimumHoldoutPairs: 7,
            minimumTrainingCorrelation: 0.3, minimumRelativeMAEImprovement: 0)
        let result = WhoopReferenceCalibration.report(
            metric: .recoveryScore, observations: rows,
            noopAlgorithmVersion: "charge-v1", configuration: config)

        XCTAssertEqual(result.calibration.decision, .validated)
        let value = result.calibration.model!.apply(to: .noopComputed(
            day: day(60), metric: .recoveryScore, value: 100,
            algorithmVersion: "charge-v1"))!
        XCTAssertEqual(value.rawNoopValue, 100, accuracy: 0)
        XCTAssertEqual(value.calibratedValue, 100, accuracy: 0)
    }

    func testStoreLoaderKeepsOfficialAndComputedNamespacesSeparate() async throws {
        let store = try await WhoopStore.inMemory()
        let computedDays = [
            DailyMetric(day: day(0), totalSleepMin: 420, efficiency: 0.90, deepMin: 75,
                        remMin: 90, lightMin: 255, disturbances: nil, restingHr: nil,
                        avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil),
            DailyMetric(day: day(1), totalSleepMin: 450, efficiency: 0.94, deepMin: 90,
                        remMin: 100, lightMin: 260, disturbances: nil, restingHr: nil,
                        avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil),
        ]
        let computedRest = computedDays.compactMap { AnalyticsEngine.Rest.composite(daily: $0) }
        try await store.upsertMetricSeries([
            MetricPoint(day: day(0), key: "sleep_performance", value: computedRest[0] + 4),
            MetricPoint(day: day(1), key: "sleep_performance", value: computedRest[1] + 4),
        ], deviceId: "my-whoop")
        try await store.upsertDailyMetrics(computedDays, deviceId: "my-whoop-noop")
        // A portable NOOP re-import can leave old metricSeries points in the computed namespace.
        // Current-rescore comparison must derive Rest from the fresh DailyMetric and ignore these.
        try await store.upsertMetricSeries([
            MetricPoint(day: day(0), key: "sleep_performance", value: 1),
            MetricPoint(day: day(1), key: "sleep_performance", value: 2),
        ], deviceId: "my-whoop-noop")

        let result = try await WhoopReferenceCalibration.report(
            store: store, metric: .restScore,
            importedDeviceId: "my-whoop", computedDeviceId: "my-whoop-noop",
            from: day(0), to: day(2), noopAlgorithmVersion: "rest-v1",
            verifiedOfficialReferenceDays: [day(0), day(1)],
            verifiedCurrentNoopDays: [day(0), day(1)],
            whoopImportSchemaRevision: "whoop-import-v1")

        XCTAssertEqual(result.pairs.count, 2)
        XCTAssertEqual(result.statistics!.bias, -4, accuracy: 1e-12)
        XCTAssertEqual(result.pairs[0].official.provenance,
                       .whoopCSVExport(schemaRevision: "whoop-import-v1"))
        XCTAssertEqual(result.pairs[0].noop.provenance,
                       .noopOnDevice(algorithmVersion: "rest-v1"))
    }

    func testStoreLoaderRejectsSameNamespace() async throws {
        let store = try await WhoopStore.inMemory()
        do {
            _ = try await WhoopReferenceCalibration.report(
                store: store, metric: .recoveryScore,
                importedDeviceId: "my-whoop", computedDeviceId: "my-whoop",
                from: day(0), to: day(1), noopAlgorithmVersion: "charge-v1",
                verifiedOfficialReferenceDays: [day(0)],
                verifiedCurrentNoopDays: [day(0)])
            XCTFail("Expected source namespace guard")
        } catch {
            XCTAssertEqual(error as? WhoopReferenceCalibrationError,
                           .sourceNamespacesMustBeDistinct)
        }
    }

    func testStoreLoaderExcludesHistoricalRowsNotProvenByCurrentRescore() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([
            DailyMetric(day: day(0), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                        remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                        avgHrv: nil, recovery: 70, strain: nil, exerciseCount: nil),
            DailyMetric(day: day(1), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                        remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                        avgHrv: nil, recovery: 71, strain: nil, exerciseCount: nil),
        ], deviceId: "my-whoop")
        try await store.upsertDailyMetrics([
            DailyMetric(day: day(0), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                        remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                        avgHrv: nil, recovery: 60, strain: nil, exerciseCount: nil),
            DailyMetric(day: day(1), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                        remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                        avgHrv: nil, recovery: 61, strain: nil, exerciseCount: nil),
        ], deviceId: "my-whoop-noop")

        let result = try await WhoopReferenceCalibration.report(
            store: store, metric: .recoveryScore,
            importedDeviceId: "my-whoop", computedDeviceId: "my-whoop-noop",
            from: day(0), to: day(1), noopAlgorithmVersion: "charge-current",
            verifiedOfficialReferenceDays: [day(0), day(1)],
            verifiedCurrentNoopDays: [day(1)])

        XCTAssertEqual(result.pairs.map(\.day), [day(1)])
        XCTAssertEqual(result.audit.unverifiedStoredNoopDays, 1)
        XCTAssertEqual(
            result.latestVerifiedNoopObservation?.provenance,
            .noopOnDevice(algorithmVersion: "charge-current"))
    }

    func testStoreLoaderExcludesOfficialRowsWithoutCurrentImporterManifestEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = [
            DailyMetric(day: day(0), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                        remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                        avgHrv: nil, recovery: 70, strain: nil, exerciseCount: nil),
            DailyMetric(day: day(1), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                        remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                        avgHrv: nil, recovery: 71, strain: nil, exerciseCount: nil),
        ]
        try await store.upsertDailyMetrics(rows, deviceId: "my-whoop")
        try await store.upsertDailyMetrics(rows, deviceId: "my-whoop-noop")

        let result = try await WhoopReferenceCalibration.report(
            store: store, metric: .recoveryScore,
            importedDeviceId: "my-whoop", computedDeviceId: "my-whoop-noop",
            from: day(0), to: day(1), noopAlgorithmVersion: "charge-current",
            verifiedOfficialReferenceDays: [day(1)],
            verifiedCurrentNoopDays: [day(0), day(1)])

        XCTAssertEqual(result.pairs.map(\.day), [day(1)])
        XCTAssertEqual(result.audit.unverifiedStoredOfficialDays, 1)
    }

    func testOnlyValidatedModelPersistsWithSeparateCalibratedEstimate() throws {
        let suite = "noop-calibration-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PersonalCalibrationModelStore(defaults: defaults, namespace: "test.calibration")

        let report = WhoopReferenceCalibration.report(
            metric: .recoveryScore,
            observations: observations(
                count: 40,
                noop: { Double(20 + $0) },
                official: { 5 + 1.2 * Double(20 + $0) }),
            noopAlgorithmVersion: "charge-v1")
        XCTAssertTrue(store.saveValidated(
            report: report, savedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        let persisted = try XCTUnwrap(
            store.load(metric: .recoveryScore, noopAlgorithmVersion: "charge-v1"))
        XCTAssertEqual(persisted.model.metric, .recoveryScore)
        XCTAssertEqual(persisted.latestEstimate.rawNoopValue, 59, accuracy: 1e-12)
        XCTAssertEqual(persisted.latestEstimate.calibratedValue, 75.8, accuracy: 1e-10)
        XCTAssertEqual(
            persisted.latestEstimate.rawProvenance,
            .noopOnDevice(algorithmVersion: "charge-v1"))
        XCTAssertEqual(
            persisted.latestEstimate.calibratedProvenance,
            .noopPersonalCalibration(
                modelVersion: PersonalCalibrationModel.modelVersion,
                basedOnAlgorithmVersion: "charge-v1"))
    }

    func testNonValidatedReportClearsPreviouslyPersistedModel() throws {
        let suite = "noop-calibration-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PersonalCalibrationModelStore(defaults: defaults, namespace: "test.calibration")

        let valid = WhoopReferenceCalibration.report(
            metric: .recoveryScore,
            observations: observations(
                count: 40,
                noop: { Double(20 + $0) },
                official: { 5 + 1.2 * Double(20 + $0) }),
            noopAlgorithmVersion: "charge-v1")
        XCTAssertTrue(store.saveValidated(report: valid))

        let insufficient = WhoopReferenceCalibration.report(
            metric: .recoveryScore,
            observations: observations(
                count: 10,
                noop: { Double(20 + $0) },
                official: { Double(25 + $0) }),
            noopAlgorithmVersion: "charge-v1")
        XCTAssertFalse(store.saveValidated(report: insufficient))
        XCTAssertNil(store.load(metric: .recoveryScore, noopAlgorithmVersion: "charge-v1"))
    }
}
