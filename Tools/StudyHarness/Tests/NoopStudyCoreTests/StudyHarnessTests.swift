import Foundation
import StrandAnalytics
import XCTest
@testable import NoopStudyCore

final class StudyHarnessTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots = []
    }

    func testSplitLockRejectsCohortReassignment() throws {
        let root = try makeRoot()
        try makeExport(at: root.appendingPathComponent("subjects/P-AAA/export"))
        try makeExport(
            at: root.appendingPathComponent("subjects/P-BBB/export"),
            subjectOffset: 1
        )
        let manifest = StudyManifest(
            studyID: "study-v1",
            subjects: [
                StudySubject(
                    subjectID: "P-AAA",
                    cohort: .discovery,
                    whoopExport: "subjects/P-AAA/export"
                ),
                StudySubject(
                    subjectID: "P-BBB",
                    cohort: .validation,
                    whoopExport: "subjects/P-BBB/export"
                ),
            ]
        )
        let keyURL = try makeKeyURL(beside: root)
        let lock = try StudySplitLocker.create(
            manifest: manifest,
            privateRoot: root,
            keyURL: keyURL,
            now: Date(timeIntervalSince1970: 0)
        )
        try StudySplitLocker.verify(
            manifest: manifest,
            lock: lock,
            privateRoot: root,
            keyURL: keyURL
        )

        let reassigned = StudyManifest(
            studyID: manifest.studyID,
            subjects: [
                StudySubject(
                    subjectID: "P-AAA",
                    cohort: .validation,
                    whoopExport: "subjects/P-AAA/export"
                ),
                StudySubject(
                    subjectID: "P-BBB",
                    cohort: .discovery,
                    whoopExport: "subjects/P-BBB/export"
                ),
            ]
        )
        XCTAssertThrowsError(
            try StudySplitLocker.verify(
                manifest: reassigned,
                lock: lock,
                privateRoot: root,
                keyURL: keyURL
            )
        ) {
            XCTAssertEqual($0 as? StudyError, .splitLockMismatch)
        }
    }

    func testSplitLockRejectsChangedReferenceExport() throws {
        let root = try makeRoot()
        let a = root.appendingPathComponent("subjects/P-AAA/export")
        let b = root.appendingPathComponent("subjects/P-BBB/export")
        try makeExport(at: a)
        try makeExport(at: b, subjectOffset: 1)
        let manifest = twoSubjectManifest()
        let keyURL = try makeKeyURL(beside: root)
        let lock = try StudySplitLocker.create(
            manifest: manifest,
            privateRoot: root,
            keyURL: keyURL
        )

        let changed = "changed\n".data(using: .utf8)!
        let changedURL = a.appendingPathComponent("extra.txt")
        try changed.write(to: changedURL)
        try setMode(changedURL, 0o600)

        XCTAssertThrowsError(
            try StudySplitLocker.verify(
                manifest: manifest,
                lock: lock,
                privateRoot: root,
                keyURL: keyURL
            )
        ) {
            XCTAssertEqual($0 as? StudyError, .referenceDigestMismatch("P-AAA"))
        }
    }

    func testSplitLockRejectsSameReferenceUnderTwoPseudonyms() throws {
        let root = try makeRoot()
        let first = root.appendingPathComponent("subjects/P-AAA/export")
        let second = root.appendingPathComponent("subjects/P-BBB/export")
        try makeExport(at: first)
        try FileManager.default.createDirectory(
            at: second.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: first, to: second)
        try setMode(second, 0o700)
        let keyURL = try makeKeyURL(beside: root)
        XCTAssertThrowsError(
            try StudySplitLocker.create(
                manifest: twoSubjectManifest(),
                privateRoot: root,
                keyURL: keyURL
            )
        ) {
            XCTAssertEqual(
                $0 as? StudyError,
                .duplicateReferenceInput(first: "P-AAA", second: "P-BBB")
            )
        }
    }

    func testSplitLockKeyMustLiveOutsideStudyRoot() throws {
        let root = try makeRoot()
        try makeExport(at: root.appendingPathComponent("subjects/P-AAA/export"))
        try makeExport(
            at: root.appendingPathComponent("subjects/P-BBB/export"),
            subjectOffset: 1
        )
        XCTAssertThrowsError(
            try StudySplitLocker.create(
                manifest: twoSubjectManifest(),
                privateRoot: root,
                keyURL: root.appendingPathComponent("locks/secret.key")
            )
        ) {
            XCTAssertEqual($0 as? StudyError, .lockKeyMustBeOutsidePrivateRoot)
        }
    }

    func testWalkForwardPredictionCannotSeeFutureNight() {
        let original = featureDays(count: 12)
        let first = WalkForwardExportEmulator.predict(original)
        var changed = original
        let last = changed.removeLast()
        changed.append(ExportFeatureDay(
            day: last.day,
            restingHeartRate: 110,
            hrvRMSSD: 8,
            respiratoryRate: 35,
            totalSleepMinutes: 90,
            inBedMinutes: 400,
            deepSleepMinutes: 0,
            remSleepMinutes: 0,
            lightSleepMinutes: 90,
            sleepEfficiencyPercent: 22
        ))
        let second = WalkForwardExportEmulator.predict(changed)

        for metric in [WhoopComparableMetric.recoveryScore, .restScore] {
            let before = first.valuesByMetric[metric] ?? [:]
            let after = second.valuesByMetric[metric] ?? [:]
            for day in original.dropLast().map(\.day) {
                XCTAssertEqual(before[day], after[day], "future input changed \(metric) on \(day)")
            }
        }
    }

    func testWalkForwardChargeHasHonestColdStart() {
        let prediction = WalkForwardExportEmulator.predict(featureDays(count: 8))
        let charge = prediction.valuesByMetric[.recoveryScore] ?? [:]
        XCTAssertNil(charge["2026-01-01"])
        XCTAssertNil(charge["2026-01-04"])
        XCTAssertNotNil(charge["2026-01-05"])
    }

    func testNoopOutputRequiresMatchingPseudonymAndUniqueDays() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("output.json")
        let output = NoopDailyOutputFile(
            subjectID: "P-WRONG",
            measurementPipelineRevision: "device-v1",
            metricRevisions: [
                WhoopComparableMetric.recoveryScore.rawValue: NoopScoreAlgorithmRevision.charge,
            ],
            days: [
                NoopDailyOutputRow(
                    day: "2026-01-01",
                    metrics: [WhoopComparableMetric.recoveryScore.rawValue: 70]
                ),
            ]
        )
        try writeJSON(output, to: url)
        XCTAssertThrowsError(
            try NoopDailyOutputAdapter.load(from: url, expectedSubjectID: "P-RIGHT")
        ) {
            XCTAssertEqual(
                $0 as? StudyError,
                .outputSubjectMismatch(expected: "P-RIGHT", actual: "P-WRONG")
            )
        }

        let duplicate = NoopDailyOutputFile(
            subjectID: "P-RIGHT",
            measurementPipelineRevision: "device-v1",
            metricRevisions: [
                WhoopComparableMetric.recoveryScore.rawValue: NoopScoreAlgorithmRevision.charge,
            ],
            days: [
                NoopDailyOutputRow(
                    day: "2026-01-01",
                    metrics: [WhoopComparableMetric.recoveryScore.rawValue: 70]
                ),
                NoopDailyOutputRow(
                    day: "2026-01-01",
                    metrics: [WhoopComparableMetric.recoveryScore.rawValue: 71]
                ),
            ]
        )
        try writeJSON(duplicate, to: url)
        XCTAssertThrowsError(
            try NoopDailyOutputAdapter.load(from: url, expectedSubjectID: "P-RIGHT")
        ) {
            XCTAssertEqual($0 as? StudyError, .duplicateOutputDay("2026-01-01"))
        }
    }

    func testAggregateUsesEqualSubjectWeightAndContainsNoIdentifiersOrPairs() throws {
        let long = comparison(
            subjectID: "P-LONG",
            errors: Array(repeating: 1.0, count: 100)
        )
        let short = comparison(
            subjectID: "P-SHORT",
            errors: Array(repeating: 9.0, count: 2)
        )
        let report = try XCTUnwrap(StudyAggregateEngine.aggregate([long, short]).first)
        XCTAssertEqual(report.macroMeanAbsoluteError, 5, accuracy: 1e-12)
        XCTAssertEqual(report.pooledMeanAbsoluteError, 118.0 / 102.0, accuracy: 1e-12)
        XCTAssertEqual(report.macroMAE95CI.lower, 1, accuracy: 1e-12)
        XCTAssertEqual(report.macroMAE95CI.upper, 9, accuracy: 1e-12)

        let encoded = String(
            data: try JSONEncoder().encode(report),
            encoding: .utf8
        )!
        XCTAssertFalse(encoded.contains("P-LONG"))
        XCTAssertFalse(encoded.contains("P-SHORT"))
        XCTAssertFalse(encoded.contains("2026-"))
        XCTAssertFalse(encoded.contains("\"pairs\""))
        XCTAssertFalse(encoded.contains("\"official\""))
        XCTAssertFalse(encoded.contains("\"noop\""))
    }

    func testRunnerMarksSmallCohortPrivateAndRequiresValidationAcknowledgement() throws {
        let root = try makeRoot()
        try makeExport(at: root.appendingPathComponent("subjects/P-AAA/export"), days: 10)
        try makeExport(
            at: root.appendingPathComponent("subjects/P-BBB/export"),
            days: 10,
            subjectOffset: 1
        )
        let manifest = twoSubjectManifest()
        let keyURL = try makeKeyURL(beside: root)
        let lock = try StudySplitLocker.create(
            manifest: manifest,
            privateRoot: root,
            keyURL: keyURL
        )
        let discovery = try StudyRunner.compare(
            manifest: manifest,
            lock: lock,
            cohort: .discovery,
            privateRoot: root,
            keyURL: keyURL
        )
        XCTAssertEqual(discovery.report.shareability, .privateExploratory)
        XCTAssertEqual(discovery.report.subjectCount, 1)
        XCTAssertEqual(discovery.report.exportEmulatorSubjectCount, 1)

        XCTAssertThrowsError(
            try StudyRunner.compare(
                manifest: manifest,
                lock: lock,
                cohort: .validation,
                privateRoot: root,
                keyURL: keyURL
            )
        ) {
            XCTAssertEqual($0 as? StudyError, .holdoutAcknowledgementRequired)
        }
    }

    func testCandidateIsDiscoveryOnlySignedAndRevisionBound() throws {
        let firstRoot = try makeRoot()
        try makeExport(
            at: firstRoot.appendingPathComponent("subjects/P-AAA/export"),
            days: 12
        )
        try makeExport(
            at: firstRoot.appendingPathComponent("subjects/P-BBB/export"),
            days: 12,
            subjectOffset: 1
        )
        let firstManifest = twoSubjectManifest()
        let firstKey = try makeKeyURL(beside: firstRoot)
        let firstLock = try StudySplitLocker.create(
            manifest: firstManifest,
            privateRoot: firstRoot,
            keyURL: firstKey,
            now: Date(timeIntervalSince1970: 0)
        )
        let firstCandidate = try StudyRunner.fitCandidate(
            manifest: firstManifest,
            lock: firstLock,
            privateRoot: firstRoot,
            keyURL: firstKey,
            candidateID: "candidate-v1",
            now: Date(timeIntervalSince1970: 1)
        )
        try StudyCandidateLocker.verify(
            firstCandidate,
            lock: firstLock,
            privateRoot: firstRoot,
            keyURL: firstKey
        )
        XCTAssertFalse(firstCandidate.transforms.isEmpty)

        // A completely different validation subject does not alter fitted
        // discovery transforms.
        let secondRoot = try makeRoot()
        try makeExport(
            at: secondRoot.appendingPathComponent("subjects/P-AAA/export"),
            days: 12
        )
        try makeExport(
            at: secondRoot.appendingPathComponent("subjects/P-BBB/export"),
            days: 12,
            subjectOffset: 40
        )
        let secondManifest = twoSubjectManifest()
        let secondKey = try makeKeyURL(beside: secondRoot)
        let secondLock = try StudySplitLocker.create(
            manifest: secondManifest,
            privateRoot: secondRoot,
            keyURL: secondKey,
            now: Date(timeIntervalSince1970: 0)
        )
        let secondCandidate = try StudyRunner.fitCandidate(
            manifest: secondManifest,
            lock: secondLock,
            privateRoot: secondRoot,
            keyURL: secondKey,
            candidateID: "candidate-v1",
            now: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(firstCandidate.transforms, secondCandidate.transforms)

        let transform = try XCTUnwrap(firstCandidate.transforms.first)
        let changed = StudyCandidateTransform(
            metric: transform.metric,
            baseRevision: transform.baseRevision,
            slope: transform.slope,
            offset: transform.offset == 20 ? 19 : transform.offset + 1,
            discoverySubjectCount: transform.discoverySubjectCount,
            discoveryPairCount: transform.discoveryPairCount
        )
        let tampered = StudyCandidate(
            schemaVersion: firstCandidate.schemaVersion,
            candidateID: firstCandidate.candidateID,
            studyID: firstCandidate.studyID,
            splitLockSignature: firstCandidate.splitLockSignature,
            createdAtUTC: firstCandidate.createdAtUTC,
            method: firstCandidate.method,
            transforms: [changed] + Array(firstCandidate.transforms.dropFirst()),
            signature: firstCandidate.signature
        )
        XCTAssertThrowsError(
            try StudyCandidateLocker.verify(
                tampered,
                lock: firstLock,
                privateRoot: firstRoot,
                keyURL: firstKey
            )
        ) {
            XCTAssertEqual($0 as? StudyError, .candidateSignatureMismatch)
        }
    }

    func testValidationRevealLocksOneCandidate() throws {
        let root = try makeRoot()
        try makeExport(
            at: root.appendingPathComponent("subjects/P-AAA/export"),
            days: 12
        )
        try makeExport(
            at: root.appendingPathComponent("subjects/P-BBB/export"),
            days: 12,
            subjectOffset: 1
        )
        let manifest = twoSubjectManifest()
        let keyURL = try makeKeyURL(beside: root)
        let lock = try StudySplitLocker.create(
            manifest: manifest,
            privateRoot: root,
            keyURL: keyURL
        )
        let first = try StudyRunner.fitCandidate(
            manifest: manifest,
            lock: lock,
            privateRoot: root,
            keyURL: keyURL,
            candidateID: "candidate-a",
            now: Date(timeIntervalSince1970: 1)
        )
        let second = try StudyRunner.fitCandidate(
            manifest: manifest,
            lock: lock,
            privateRoot: root,
            keyURL: keyURL,
            candidateID: "candidate-b",
            now: Date(timeIntervalSince1970: 2)
        )
        let receipt = try StudyPaths.resolveOutput(
            "locks/reveal.json",
            under: root
        )
        try StudyCandidateLocker.reserveValidationReveal(
            candidate: first,
            lock: lock,
            validationInputs: [],
            receiptURL: receipt,
            privateRoot: root,
            keyURL: keyURL,
            now: Date(timeIntervalSince1970: 3)
        )
        try StudyCandidateLocker.reserveValidationReveal(
            candidate: first,
            lock: lock,
            validationInputs: [],
            receiptURL: receipt,
            privateRoot: root,
            keyURL: keyURL,
            now: Date(timeIntervalSince1970: 4)
        )
        XCTAssertThrowsError(
            try StudyCandidateLocker.reserveValidationReveal(
                candidate: first,
                lock: lock,
                validationInputs: [
                    StudyValidationInputDigest(
                        subjectID: "P-BBB",
                        whoopExportSHA256: "changed",
                        noopDailyOutputSHA256: nil
                    ),
                ],
                receiptURL: receipt,
                privateRoot: root,
                keyURL: keyURL
            )
        ) {
            XCTAssertEqual(
                $0 as? StudyError,
                .validationAlreadyRevealedWithDifferentCandidate
            )
        }
        XCTAssertThrowsError(
            try StudyCandidateLocker.reserveValidationReveal(
                candidate: second,
                lock: lock,
                validationInputs: [],
                receiptURL: receipt,
                privateRoot: root,
                keyURL: keyURL
            )
        ) {
            XCTAssertEqual(
                $0 as? StudyError,
                .validationAlreadyRevealedWithDifferentCandidate
            )
        }
    }

    func testValidationReportIsCandidateBoundAndDoesNotSuggestARefit() throws {
        let root = try makeRoot()
        try makeExport(
            at: root.appendingPathComponent("subjects/P-AAA/export"),
            days: 12
        )
        try makeExport(
            at: root.appendingPathComponent("subjects/P-BBB/export"),
            days: 12,
            subjectOffset: 1
        )
        let manifest = twoSubjectManifest()
        let keyURL = try makeKeyURL(beside: root)
        let lock = try StudySplitLocker.create(
            manifest: manifest,
            privateRoot: root,
            keyURL: keyURL
        )
        let candidate = try StudyRunner.fitCandidate(
            manifest: manifest,
            lock: lock,
            privateRoot: root,
            keyURL: keyURL,
            candidateID: "candidate-v1"
        )
        let receiptURL = try StudyPaths.resolveOutput(
            "locks/validation-reveal.json",
            under: root
        )
        let validation = try StudyRunner.compare(
            manifest: manifest,
            lock: lock,
            cohort: .validation,
            privateRoot: root,
            keyURL: keyURL,
            candidate: candidate,
            acknowledgeHoldoutReveal: true,
            validationRevealURL: receiptURL
        )
        XCTAssertEqual(validation.report.candidateID, candidate.candidateID)
        XCTAssertEqual(validation.report.candidateSignature, candidate.signature)
        XCTAssertTrue(validation.report.metrics.allSatisfy {
            $0.calibrationIntercept == nil && $0.calibrationSlope == nil
        })
        XCTAssertEqual(validation.privateAudit.candidateSignature, candidate.signature)
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-study-\(UUID().uuidString)", isDirectory: true)
        try StudyPaths.ensurePrivateDirectory(url)
        temporaryRoots.append(url)
        return url
    }

    private func makeKeyURL(beside root: URL) throws -> URL {
        let directory = root.deletingLastPathComponent()
            .appendingPathComponent("noop-study-key-\(UUID().uuidString)", isDirectory: true)
        try StudyPaths.ensurePrivateDirectory(directory)
        temporaryRoots.append(directory)
        return directory.appendingPathComponent("lock.key")
    }

    private func twoSubjectManifest() -> StudyManifest {
        StudyManifest(
            studyID: "study-v1",
            subjects: [
                StudySubject(
                    subjectID: "P-AAA",
                    cohort: .discovery,
                    whoopExport: "subjects/P-AAA/export"
                ),
                StudySubject(
                    subjectID: "P-BBB",
                    cohort: .validation,
                    whoopExport: "subjects/P-BBB/export"
                ),
            ]
        )
    }

    private func makeExport(
        at url: URL,
        days: Int = 2,
        subjectOffset: Int = 0
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try setMode(url, 0o700)
        var lines = [
            "Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Day Strain,Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Sleep efficiency %",
        ]
        for index in 0..<days {
            let day = index + 1
            let wakeDay = day + 1
            lines.append(
                String(
                    format: "2026-01-%02d 22:00:00,2026-01-%02d 22:00:00,UTC+00:00,%d,%d,%d,10,2026-01-%02d 22:30:00,2026-01-%02d 06:30:00,80,14,420,450,210,90,120,93",
                    day,
                    wakeDay,
                    60 + subjectOffset + (index % 20),
                    50 + (index % 3),
                    60 + (index % 8),
                    day,
                    wakeDay
                )
            )
        }
        let cycles = url.appendingPathComponent("physiological_cycles.csv")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: cycles)
        try setMode(cycles, 0o600)
    }

    private func featureDays(count: Int) -> [ExportFeatureDay] {
        var result: [ExportFeatureDay] = []
        for index in 0..<count {
            let day = String(format: "2026-01-%02d", index + 1)
            let restingHeartRate = Double(52 + (index % 3))
            let hrv = Double(55 + (index % 7))
            let respiration = 14.0 + Double(index % 2) * 0.2
            let totalSleep = Double(390 + (index % 5) * 10)
            let inBed = Double(430 + (index % 5) * 10)
            result.append(ExportFeatureDay(
                day: day,
                restingHeartRate: restingHeartRate,
                hrvRMSSD: hrv,
                respiratoryRate: respiration,
                totalSleepMinutes: totalSleep,
                inBedMinutes: inBed,
                deepSleepMinutes: 80,
                remSleepMinutes: 100,
                lightSleepMinutes: 220,
                sleepEfficiencyPercent: 92
            ))
        }
        return result
    }

    private func comparison(subjectID: String, errors: [Double]) -> SubjectMetricComparison {
        let official = errors.indices.map { Double(50 + ($0 % 20)) }
        let noop = zip(official, errors).map(+)
        return SubjectMetricComparison(
            subjectID: subjectID,
            metric: .recoveryScore,
            sourceMode: .pairedOnDevice,
            revision: NoopScoreAlgorithmRevision.charge,
            eligibleOfficialDays: errors.count,
            official: official,
            noop: noop
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try setMode(url, 0o600)
    }

    private func setMode(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(mode))],
            ofItemAtPath: url.path
        )
    }
}
