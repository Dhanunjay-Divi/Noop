import Foundation

public enum StudyRunner {
    public static func fitCandidate(
        manifest: StudyManifest,
        lock: StudySplitLock,
        privateRoot: URL,
        keyURL: URL,
        candidateID: String,
        now: Date = Date()
    ) throws -> StudyCandidate {
        try StudyCandidateLocker.fit(
            manifest: manifest,
            lock: lock,
            privateRoot: privateRoot,
            keyURL: keyURL,
            candidateID: candidateID,
            now: now
        )
    }

    public static func audit(
        manifest: StudyManifest,
        lock: StudySplitLock,
        privateRoot: URL,
        keyURL: URL
    ) throws -> StudyAuditReport {
        try StudySplitLocker.verify(
            manifest: manifest,
            lock: lock,
            privateRoot: privateRoot,
            keyURL: keyURL
        )

        var output: [StudyCohortAudit] = []
        // Pre-freeze audit deliberately avoids opening validation rows. The
        // validation report itself carries coverage after the one-time reveal.
        for cohort in [StudyCohort.discovery] {
            let subjects = manifest.subjects.filter { $0.cohort == cohort }
            var cycles = 0
            var officialCycles = 0
            var sleeps = 0
            var workouts = 0
            var journals = 0
            var duplicates = 0
            var quarantined = 0
            var paired = 0
            for subject in subjects {
                let exportURL = try StudyPaths.resolveInput(
                    subject.whoopExport,
                    under: privateRoot
                )
                let reference = try WhoopReferenceAdapter.load(from: exportURL)
                cycles += reference.audit.cycleRows
                officialCycles += reference.audit.officialCycleRows
                sleeps += reference.audit.sleepRows
                workouts += reference.audit.workoutRows
                journals += reference.audit.journalRowsDiscarded
                duplicates += reference.audit.duplicateOfficialDaysDropped
                quarantined += reference.audit.quarantinedNonOfficialRows
                if let relative = subject.noopDailyOutput {
                    let candidate = privateRoot.appendingPathComponent(relative).standardizedFileURL
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        _ = try StudyPaths.resolveInput(relative, under: privateRoot)
                        paired += 1
                    }
                }
            }
            output.append(StudyCohortAudit(
                cohort: cohort,
                subjectCount: subjects.count,
                cycleRows: cycles,
                officialCycleRows: officialCycles,
                sleepRows: sleeps,
                workoutRows: workouts,
                journalRowsDiscarded: journals,
                duplicateOfficialDaysDropped: duplicates,
                quarantinedNonOfficialRows: quarantined,
                subjectsWithPairedDeviceOutput: paired
            ))
        }

        return StudyAuditReport(
            schemaVersion: 1,
            studyID: manifest.studyID,
            privacy: "aggregate schema/coverage only; journals discarded",
            splitLockVerified: true,
            cohorts: output,
            warnings: [
                "WHOOP exports contain processed daily summaries, not raw BLE/PPG/R-R/IMU streams.",
                "Journal rows are counted for schema audit and immediately discarded; notes never enter reports.",
                "Skin temperature is excluded from comparison until absolute/deviation semantics are normalized.",
                "Validation files are not parsed by audit; validation coverage appears only after its signed reveal.",
            ]
        )
    }

    public static func compare(
        manifest: StudyManifest,
        lock: StudySplitLock,
        cohort: StudyCohort,
        privateRoot: URL,
        keyURL: URL,
        candidate: StudyCandidate? = nil,
        acknowledgeHoldoutReveal: Bool = false,
        validationRevealURL: URL? = nil,
        now: Date = Date()
    ) throws -> StudyRunArtifacts {
        if cohort == .validation, !acknowledgeHoldoutReveal {
            throw StudyError.holdoutAcknowledgementRequired
        }
        try StudySplitLocker.verify(
            manifest: manifest,
            lock: lock,
            privateRoot: privateRoot,
            keyURL: keyURL
        )
        if let candidate {
            try StudyCandidateLocker.verify(
                candidate,
                lock: lock,
                privateRoot: privateRoot,
                keyURL: keyURL
            )
        }
        if cohort == .validation {
            guard let candidate else {
                throw StudyError.candidateRequiredForValidation
            }
            guard let validationRevealURL else {
                throw StudyError.validationRevealReceiptRequired
            }
            let lockedByID = Dictionary(
                uniqueKeysWithValues: lock.subjects.map { ($0.subjectID, $0) }
            )
            let validationInputs = try manifest.subjects
                .filter { $0.cohort == .validation }
                .sorted { $0.subjectID < $1.subjectID }
                .map { subject -> StudyValidationInputDigest in
                    let localDigest: String?
                    if let relative = subject.noopDailyOutput {
                        let outputURL = try StudyPaths.resolveInput(
                            relative,
                            under: privateRoot
                        )
                        // Validate identity, units, ranges, and revisions before
                        // any official validation outcome is parsed.
                        _ = try NoopDailyOutputAdapter.load(
                            from: outputURL,
                            expectedSubjectID: subject.subjectID
                        )
                        localDigest = try StudyFileDigest.sha256(of: outputURL)
                    } else {
                        localDigest = nil
                    }
                    guard let exportDigest =
                        lockedByID[subject.subjectID]?.whoopExportSHA256
                    else {
                        throw StudyError.splitLockMismatch
                    }
                    return StudyValidationInputDigest(
                        subjectID: subject.subjectID,
                        whoopExportSHA256: exportDigest,
                        noopDailyOutputSHA256: localDigest
                    )
                }
            // Reserve the holdout before reading it. If parsing later fails, the
            // conservative interpretation is still that the reveal was spent.
            try StudyCandidateLocker.reserveValidationReveal(
                candidate: candidate,
                lock: lock,
                validationInputs: validationInputs,
                receiptURL: validationRevealURL,
                privateRoot: privateRoot,
                keyURL: keyURL,
                now: now
            )
        }

        let subjects = manifest.subjects
            .filter { $0.cohort == cohort }
            .sorted { $0.subjectID < $1.subjectID }
        let lockedByID = Dictionary(
            uniqueKeysWithValues: lock.subjects.map { ($0.subjectID, $0) }
        )
        var comparisons: [SubjectMetricComparison] = []
        var privateInputs: [StudyPrivateRunAudit.Input] = []
        var pairedCount = 0
        var emulatorCount = 0
        var revisions = Set<String>()

        for subject in subjects {
            let exportURL = try StudyPaths.resolveInput(
                subject.whoopExport,
                under: privateRoot
            )
            let reference = try WhoopReferenceAdapter.load(from: exportURL)
            let basePrediction: StudyPredictionSet
            let localDigest: String?
            if let relative = subject.noopDailyOutput {
                let outputURL = try StudyPaths.resolveInput(relative, under: privateRoot)
                basePrediction = try NoopDailyOutputAdapter.load(
                    from: outputURL,
                    expectedSubjectID: subject.subjectID
                )
                localDigest = try StudyFileDigest.sha256(of: outputURL)
                pairedCount += 1
            } else {
                basePrediction = WalkForwardExportEmulator.predict(reference.featureDays)
                localDigest = nil
                emulatorCount += 1
            }
            let prediction = try candidate.map {
                try StudyCandidateLocker.apply($0, to: basePrediction)
            } ?? basePrediction
            comparisons += StudySubjectComparator.compare(
                subjectID: subject.subjectID,
                reference: reference,
                prediction: prediction
            )
            revisions.formUnion(prediction.revisionByMetric.values)
            let exportDigest: String
            if let sealed = lockedByID[subject.subjectID]?.whoopExportSHA256 {
                exportDigest = sealed
            } else {
                exportDigest = try StudyFileDigest.sha256(of: exportURL)
            }
            privateInputs.append(StudyPrivateRunAudit.Input(
                subjectID: subject.subjectID,
                sourceMode: prediction.sourceMode,
                whoopExportSHA256: exportDigest,
                noopDailyOutputSHA256: localDigest
            ))
        }

        let metrics = StudyAggregateEngine.aggregate(
            comparisons,
            includeCalibrationFit: cohort == .discovery
        )
        guard !metrics.isEmpty else { throw StudyError.noComparableData }
        var warnings = [
            "Primary error summaries are macro/equal-subject; pooled-day results are secondary.",
            "No subject IDs, dates, paths, raw readings, journal content, or input hashes appear in this aggregate report.",
            "Skin temperature is excluded until Fahrenheit conversion and absolute-vs-deviation semantics are explicit.",
            "SpO₂ percentage cannot be end-to-end validated from WHOOP 4 raw optical ADC.",
        ]
        if emulatorCount > 0 {
            warnings.append(
                "Export-feature-emulator results use WHOOP-processed non-outcome inputs with strictly prior walk-forward baselines. They are formula exploration, not raw-device validation."
            )
        }
        if let candidate {
            warnings.append(
                "Frozen candidate \(candidate.candidateID) applies a discovery-only, equal-subject bias correction. Raw transparent NOOP scores remain distinct from this official-reference presentation."
            )
        }
        if pairedCount > 0 {
            warnings.append(
                "Paired-on-device results are end-to-end only if each supplied NOOP file was generated from the same subject/date raw capture, without imported WHOOP outcomes entering the score."
            )
        }
        if metrics.contains(where: { $0.pairedDayCount < 7 }) {
            warnings.append(
                "At least one metric has fewer than seven paired days; its correlation, bands, and error estimates are too unstable for a decision."
            )
        }
        let shareability: StudyShareability
        if subjects.count < 5 {
            shareability = .privateExploratory
            warnings.append(
                "Fewer than five participants: this is private exploratory evidence only and must not support population claims."
            )
        } else {
            shareability = .aggregateShareable
        }
        if cohort == .validation {
            warnings.append(
                "This validation cohort has now been revealed for the frozen candidate. If its result changes the formula, treat this holdout as spent and use new subjects for the next final test."
            )
        }

        let report = StudyComparisonReport(
            schemaVersion: 1,
            studyID: manifest.studyID,
            cohort: cohort,
            shareability: shareability,
            splitLockVerified: true,
            subjectCount: subjects.count,
            pairedOnDeviceSubjectCount: pairedCount,
            exportEmulatorSubjectCount: emulatorCount,
            candidateID: candidate?.candidateID,
            candidateSignature: candidate?.signature,
            candidateMethod: candidate?.method,
            metrics: metrics,
            warnings: warnings
        )
        let audit = StudyPrivateRunAudit(
            schemaVersion: 1,
            studyID: manifest.studyID,
            cohort: cohort,
            createdAtUTC: iso8601.string(from: now),
            candidateID: candidate?.candidateID,
            candidateSignature: candidate?.signature,
            inputs: privateInputs,
            algorithmRevisions: revisions.sorted()
        )
        return StudyRunArtifacts(report: report, privateAudit: audit)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
