import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Release guard for the legacy `DailyMetric.steps` provenance gap. A strap-computed value can be
/// WHOOP 5/MG @57 motion ticks divided by a preference; consumers that speak as factual wellness inputs
/// must omit it until they can join a validated/imported step source explicitly.
@MainActor
final class StepProvenanceSafetyTests: XCTestCase {
    private func day(_ index: Int, steps: Int = 54_321) -> DailyMetric {
        DailyMetric(
            day: String(format: "2026-07-%02d", index),
            totalSleepMin: 450,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: 55,
            avgHrv: 42,
            recovery: 70,
            strain: 12,
            exerciseCount: nil,
            steps: steps,
            activeKcalEst: 500)
    }

    func testVitalityInputsOmitUnprovenancedDailySteps() {
        let inputs = IntelligenceEngine.vitalityInputs(
            days: (1...14).map { day($0) }, chronoAge: 40)

        XCTAssertNil(inputs.steps)
        XCTAssertFalse(VitalityEngine.contributions(inputs).contains { $0.key == "steps" })
        XCTAssertNotNil(VitalityEngine.compute(inputs),
                        "Other sufficiently covered domains should still produce Vitality.")
    }

    func testUpgradePurgesOnlyComputedStepsDependentVitalityWhenV2IsIneligible() async throws {
        let store = try await WhoopStore.inMemory()
        let computedId = "my-whoop-noop"
        let importedId = "my-whoop"
        let vendorId = "oura"
        let scoreDay = "2026-07-11"
        let legacyInputs = VitalityEngine.Inputs(
            chronoAge: 40,
            restingHR: 55,
            sleepHours: 7.5,
            sleepConsistency: 1,
            rmssd: nil,
            rmssdNorm: nil,
            steps: 10_000)
        XCTAssertNotNil(VitalityEngine.compute(legacyInputs),
                        "The fixture must represent a score whose third domain was legacy steps.")

        let sparseDays = (1...14).map {
            DailyMetric(
                day: String(format: "2026-07-%02d", $0),
                totalSleepMin: 450,
                efficiency: nil,
                deepMin: nil,
                remMin: nil,
                lightMin: nil,
                disturbances: nil,
                restingHr: 55,
                avgHrv: nil,
                recovery: nil,
                strain: nil,
                exerciseCount: nil,
                steps: 10_000,
                activeKcalEst: nil)
        }
        XCTAssertNil(VitalityEngine.compute(IntelligenceEngine.vitalityInputs(
            days: sparseDays, chronoAge: 40)),
            "Without unprovenanced steps, the fixture has only two independent domains.")

        let legacyRows = [
            MetricPoint(day: scoreDay, key: "vitality", value: 68),
            MetricPoint(day: scoreDay, key: "body_age", value: 36),
            MetricPoint(day: scoreDay, key: AgeMetricProfile.legacyVitalityKey, value: 40),
        ]
        try await store.upsertMetricSeries(legacyRows, deviceId: computedId)
        try await store.upsertMetricSeries(legacyRows, deviceId: importedId)
        try await store.upsertMetricSeries(legacyRows, deviceId: vendorId)

        let wrote = await IntelligenceEngine.reconcileVitalityV2(
            store: store,
            computedReadIds: [computedId],
            writeId: computedId,
            days: sparseDays,
            age: 40,
            inputsUsable: true,
            saturdayKey: scoreDay)

        XCTAssertFalse(wrote)
        for key in ["vitality", "body_age", AgeMetricProfile.legacyVitalityKey,
                    AgeMetricProfile.vitalityKey] {
            let rows = try await store.metricSeries(
                deviceId: computedId, key: key, from: "0000-01-01", to: "9999-12-31")
            XCTAssertTrue(rows.isEmpty,
                "Only computed \(key) rows should be invalidated.")
        }
        for preservedId in [importedId, vendorId] {
            let vitalityRows = try await store.metricSeries(
                deviceId: preservedId, key: "vitality",
                from: "0000-01-01", to: "9999-12-31")
            let markerRows = try await store.metricSeries(
                deviceId: preservedId, key: AgeMetricProfile.legacyVitalityKey,
                from: "0000-01-01", to: "9999-12-31")
            XCTAssertEqual(vitalityRows.last?.value, 68)
            XCTAssertEqual(markerRows.last?.value, 40)
        }
    }

    func testVitalityV2RequiresItsVersionedMarker() {
        let token = AgeMetricProfile.vitalityToken(age: 40)
        XCTAssertNotEqual(AgeMetricProfile.legacyVitalityKey, AgeMetricProfile.vitalityKey)
        XCTAssertFalse(AgeMetricProfile.acceptsVitalityV2(stored: nil, current: token))
        XCTAssertFalse(AgeMetricProfile.acceptsVitalityV2(stored: 39, current: token))
        XCTAssertTrue(AgeMetricProfile.acceptsVitalityV2(stored: token, current: token))
    }

    func testCoachContextDoesNotStateDailyMetricStepsAsFact() {
        let repo = Repository(deviceId: "test-step-provenance")
        repo.days = (1...14).map { day($0) }
        let context = AICoachEngine(repo: repo).buildContext()

        XCTAssertFalse(context.localizedCaseInsensitiveContains("steps:"))
        XCTAssertFalse(context.contains("54321"))
        XCTAssertTrue(context.contains("active energy: 500kcal/day"))
    }
}
