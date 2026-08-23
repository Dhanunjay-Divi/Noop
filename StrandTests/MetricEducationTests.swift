import XCTest
@testable import Strand

final class MetricEducationTests: XCTestCase {
    func testBaselineNeedsEnoughPriorReadings() {
        let read = MetricBaselineRead.analyze([50, 51, 52, 53], minimumSamples: 7)
        XCTAssertEqual(read.position, .building)
        XCTAssertEqual(read.latest, 53)
        XCTAssertEqual(read.sampleCount, 3)
    }

    func testBaselineCallsClearStandardDeviationShiftAbove() {
        let read = MetricBaselineRead.analyze([48, 49, 50, 51, 52, 50, 49, 65], minimumSamples: 7)
        XCTAssertEqual(read.position, .above)
        XCTAssertEqual(read.sampleCount, 7)
        XCTAssertNotNil(read.zScore)
    }

    func testBaselineKeepsSmallMovementWithinRecentRange() {
        let read = MetricBaselineRead.analyze([50, 51, 49, 50, 50, 51, 49, 50], minimumSamples: 7)
        XCTAssertEqual(read.position, .within)
    }

    func testFitnessAgeEducationNeverCallsItBiologicalAge() {
        let metric = try! XCTUnwrap(MetricCatalog.all.first { $0.key == "fitness_age" })
        let education = MetricKnowledge.education(for: metric)
        XCTAssertTrue(education.whatItIs.localizedCaseInsensitiveContains("not biological age"))
        XCTAssertEqual(education.cadence, "Updated weekly")
    }

    func testFitnessAgeCalibrationCopyIncludesBothRequiredCoverageGates() {
        XCTAssertEqual(
            fitnessReadyLeadCopy(
                rhrDays: 4, activityDays: 1, hasAge: true, hasSex: true
            ),
            "Calibration progress: resting heart rate 4 of 4 nights; activity 1 of 4 days."
        )
        XCTAssertEqual(
            fitnessCalibrationCompactCopy(
                rhrDays: 2, activityDays: 3, hasAge: true, hasSex: true
            ),
            "RHR 2/4 · Activity 3/4"
        )
    }

    func testFitnessAgeCalibrationCopyReportsReadyAndUnsupportedProfileStates() {
        XCTAssertEqual(
            fitnessReadyLeadCopy(
                rhrDays: 7, activityDays: 7, hasAge: true, hasSex: true
            ),
            "Resting heart rate and activity coverage are ready. Refresh to calculate your Fitness Age."
        )
        XCTAssertEqual(
            fitnessReadyLeadCopy(
                rhrDays: 7, activityDays: 7, hasAge: false, hasSex: true
            ),
            "Fitness Age needs a supported profile: age 20–80 and a male or female model coefficient."
        )
    }

    func testVitalityAndWellnessAgeDoNotClaimBodyCompositionInputs() {
        for key in ["vitality", "body_age"] {
            let metric = try! XCTUnwrap(MetricCatalog.all.first { $0.key == key })
            let education = MetricKnowledge.education(for: metric)
            let copy = (education.commonInfluences + education.actions).joined(separator: " ")
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("body composition"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("body-composition"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("steps"))
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("activity"))
        }
    }

    func testVitalityChangelogNamesOnlyCurrentV2Inputs() throws {
        let release = try XCTUnwrap(AppChangelog.releases.first { $0.version == "4.0.0" })
        let claim = try XCTUnwrap(release.items.first {
            $0.localizedCaseInsensitiveContains("Vitality + Wellness Age")
        })
        XCTAssertFalse(claim.localizedCaseInsensitiveContains("steps"))
        XCTAssertFalse(claim.localizedCaseInsensitiveContains("activity"))
        XCTAssertTrue(claim.localizedCaseInsensitiveContains("profile age"))
    }

    func testWhoopStepCounterEducationCallsItMotionDerivedNotMeasured() throws {
        let metric = try XCTUnwrap(MetricCatalog.metric(key: "steps", source: "my-whoop"))
        let education = MetricKnowledge.education(for: metric)
        let copy = [metric.title, metric.description ?? "", education.whatItIs,
                    education.method, education.limitations].joined(separator: " ")

        XCTAssertTrue(copy.localizedCaseInsensitiveContains("motion"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("estimate"))
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("not a validated pedometer count"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("measured step counter"))
        XCTAssertEqual(MetricKnowledge.dataKind(for: metric), "Derived on device")
    }

    func testAppleHealthStepsRemainImportedPedometerSteps() throws {
        let metric = try XCTUnwrap(MetricCatalog.metric(key: "steps", source: "apple-health"))
        let education = MetricKnowledge.education(for: metric)

        XCTAssertEqual(metric.title, "Steps")
        XCTAssertTrue(education.whatItIs.localizedCaseInsensitiveContains("imported"))
        XCTAssertFalse(education.method.localizedCaseInsensitiveContains("motion-counter"))
        XCTAssertEqual(MetricKnowledge.dataKind(for: metric), "Imported")
    }

    func testAgeMetricProfileProvenanceRejectsCorrectionsAndWaistRemoval() {
        let original = AgeMetricProfile.fitnessAgeToken(age: 40, sex: "female")
        XCTAssertTrue(AgeMetricProfile.accepts(
            stored: nil, current: original, provenanceRequired: false))
        XCTAssertFalse(AgeMetricProfile.accepts(
            stored: nil, current: original, provenanceRequired: true))
        XCTAssertNotEqual(original, AgeMetricProfile.fitnessAgeToken(age: 41, sex: "female"))
        XCTAssertNotEqual(original, AgeMetricProfile.fitnessAgeToken(age: 40, sex: "male"))
        XCTAssertNotNil(AgeMetricProfile.vo2maxEstimateToken(age: 40, sex: "female", waistCm: 82))
        XCTAssertNil(AgeMetricProfile.vo2maxEstimateToken(age: 40, sex: "female", waistCm: 0))
    }

    func testFitnessAgeV2NeverAcceptsMissingOrLegacyCalibrationMarkers() {
        let fitness = AgeMetricProfile.fitnessAgeToken(age: 40, sex: "female")
        let vo2 = AgeMetricProfile.vo2maxEstimateToken(age: 40, sex: "female", waistCm: 82)

        XCTAssertFalse(AgeMetricProfile.acceptsFitnessAgeV2(stored: nil, current: fitness))
        XCTAssertFalse(AgeMetricProfile.acceptsFitnessAgeV2(stored: 391, current: fitness))
        XCTAssertTrue(AgeMetricProfile.acceptsFitnessAgeV2(stored: fitness, current: fitness))
        XCTAssertFalse(AgeMetricProfile.acceptsVO2maxEstimateV2(stored: nil, current: vo2))
        XCTAssertTrue(AgeMetricProfile.acceptsVO2maxEstimateV2(stored: vo2, current: vo2))
        XCTAssertNotEqual(AgeMetricProfile.legacyFitnessAgeKey, AgeMetricProfile.fitnessAgeKey)
        XCTAssertNotEqual(
            AgeMetricProfile.legacyVO2maxEstimateKey, AgeMetricProfile.vo2maxEstimateKey)
    }

    func testSleepEfficiencyFormatsStoredFractionAsPercent() {
        let metric = try! XCTUnwrap(MetricCatalog.all.first { $0.key == "sleep_efficiency" })
        XCTAssertEqual(metric.format(0.923), "92 %")
        XCTAssertEqual(
            metric.formatDelta(0.05, system: .metric, temperature: .celsius),
            "5 %"
        )
    }

    func testAppleHealthTemperaturesAreCataloguedSeparatelyFromWhoopSkinTemperature() throws {
        let body = try XCTUnwrap(MetricCatalog.metric(key: "body_temp", source: "apple-health"))
        let wrist = try XCTUnwrap(MetricCatalog.metric(key: "wrist_temp", source: "apple-health"))
        let skin = try XCTUnwrap(MetricCatalog.metric(key: "skin_temp", source: "my-whoop"))

        XCTAssertEqual(body.title, "Body Temperature")
        XCTAssertEqual(wrist.title, "Sleeping Wrist Temperature")
        XCTAssertNotEqual(body.id, skin.id)
        XCTAssertTrue(MetricKnowledge.education(for: body).method.localizedCaseInsensitiveContains("never substituted"))
        XCTAssertTrue(MetricKnowledge.education(for: wrist).method.localizedCaseInsensitiveContains("separate"))
    }

    func testWearableImporterNormalizesBothPercentAndFraction() throws {
        XCTAssertEqual(try XCTUnwrap(WearableImporter.storedEfficiency(92)), 0.92, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(WearableImporter.storedEfficiency(0.92)), 0.92, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(WearableImporter.sleepEfficiency(total: 420, awake: 60)),
            0.875,
            accuracy: 0.000_001
        )
    }
}
