import Foundation
import StrandAnalytics

public enum StudyCohort: String, Codable, CaseIterable, Sendable {
    case discovery
    case validation
}

public struct StudySubject: Codable, Equatable, Sendable {
    public let subjectID: String
    public let cohort: StudyCohort
    /// Path relative to the private study root. Absolute paths are rejected.
    public let whoopExport: String
    /// Optional path, also relative to the private root, to an aggregate daily
    /// output produced from a real NOOP raw-device scoring run.
    public let noopDailyOutput: String?

    public init(
        subjectID: String,
        cohort: StudyCohort,
        whoopExport: String,
        noopDailyOutput: String? = nil
    ) {
        self.subjectID = subjectID
        self.cohort = cohort
        self.whoopExport = whoopExport
        self.noopDailyOutput = noopDailyOutput
    }
}

public struct StudyManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let studyID: String
    public let subjects: [StudySubject]

    public init(schemaVersion: Int = 1, studyID: String, subjects: [StudySubject]) {
        self.schemaVersion = schemaVersion
        self.studyID = studyID
        self.subjects = subjects
    }
}

/// Only fields that define the sealed participant split and official reference
/// inputs. `noopDailyOutput` is intentionally omitted: a raw-device capture may
/// arrive after the subject split is frozen, and its digest is recorded in the
/// private run audit instead.
public struct LockedStudySubject: Codable, Equatable, Sendable {
    public let subjectID: String
    public let cohort: StudyCohort
    public let whoopExport: String
    public let whoopExportSHA256: String
}

public struct StudySplitLock: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let studyID: String
    public let createdAtUTC: String
    public let subjects: [LockedStudySubject]
    /// HMAC-SHA256 over the canonical encoding of every preceding field.
    public let signature: String
}

/// A discovery-only, globally fitted presentation transform.
///
/// This deliberately does not replace NOOP's transparent raw score. It records
/// a small, frozen transform that can be tested against a sealed validation
/// cohort without refitting on that cohort.
public struct StudyCandidateTransform: Codable, Equatable, Sendable {
    public let metric: WhoopComparableMetric
    public let baseRevision: String
    public let slope: Double
    public let offset: Double
    public let discoverySubjectCount: Int
    public let discoveryPairCount: Int
}

public struct StudyCandidate: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let candidateID: String
    public let studyID: String
    public let splitLockSignature: String
    public let createdAtUTC: String
    public let method: String
    public let transforms: [StudyCandidateTransform]
    /// HMAC-SHA256 over every preceding field.
    public let signature: String
}

/// First validation reveal permanently binds the study split to one candidate.
/// Re-running that same candidate is reproducible; trying another candidate
/// fails closed so the holdout cannot silently become a tuning set.
public struct StudyValidationRevealReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let studyID: String
    public let splitLockSignature: String
    public let candidateSignature: String
    public let validationInputs: [StudyValidationInputDigest]
    public let revealedAtUTC: String
    /// HMAC-SHA256 over every preceding field.
    public let signature: String
}

public struct StudyValidationInputDigest: Codable, Equatable, Sendable {
    public let subjectID: String
    public let whoopExportSHA256: String
    public let noopDailyOutputSHA256: String?

    public init(
        subjectID: String,
        whoopExportSHA256: String,
        noopDailyOutputSHA256: String?
    ) {
        self.subjectID = subjectID
        self.whoopExportSHA256 = whoopExportSHA256
        self.noopDailyOutputSHA256 = noopDailyOutputSHA256
    }
}

public enum NoopDailyOutputSource: String, Codable, Sendable {
    /// The values were generated from a genuine raw capture / NOOP database
    /// scoring pass. This is the only accepted external source.
    case noopOnDevice = "noop-on-device"
}

/// Aggregate daily values exported by the real NOOP device pipeline.
///
/// Metric keys are `WhoopComparableMetric.rawValue`. Each score must name its
/// exact algorithm revision in `metricRevisions`; direct measured/derived
/// metrics use `measurementPipelineRevision`.
public struct NoopDailyOutputFile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let subjectID: String
    public let source: NoopDailyOutputSource
    public let measurementPipelineRevision: String
    public let metricRevisions: [String: String]
    public let days: [NoopDailyOutputRow]

    public init(
        schemaVersion: Int = 1,
        subjectID: String,
        source: NoopDailyOutputSource = .noopOnDevice,
        measurementPipelineRevision: String,
        metricRevisions: [String: String],
        days: [NoopDailyOutputRow]
    ) {
        self.schemaVersion = schemaVersion
        self.subjectID = subjectID
        self.source = source
        self.measurementPipelineRevision = measurementPipelineRevision
        self.metricRevisions = metricRevisions
        self.days = days
    }
}

public struct NoopDailyOutputRow: Codable, Equatable, Sendable {
    public let day: String
    public let metrics: [String: Double]

    public init(day: String, metrics: [String: Double]) {
        self.day = day
        self.metrics = metrics
    }
}

public enum StudySourceMode: String, Codable, Sendable {
    /// A real NOOP output file was paired with the official export.
    case pairedOnDevice = "paired-on-device"
    /// NOOP Charge/Rest were evaluated from WHOOP-processed non-outcome
    /// features. Useful for formula exploration, never end-to-end validation.
    case exportFeatureEmulator = "export-feature-emulator"
}

public enum StudyShareability: String, Codable, Sendable {
    case privateExploratory = "private-exploratory-do-not-share"
    case aggregateShareable = "aggregate-shareable"
}

public struct StudyCohortAudit: Codable, Equatable, Sendable {
    public let cohort: StudyCohort
    public let subjectCount: Int
    public let cycleRows: Int
    public let officialCycleRows: Int
    public let sleepRows: Int
    public let workoutRows: Int
    public let journalRowsDiscarded: Int
    public let duplicateOfficialDaysDropped: Int
    public let quarantinedNonOfficialRows: Int
    public let subjectsWithPairedDeviceOutput: Int
}

public struct StudyAuditReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let studyID: String
    public let privacy: String
    public let splitLockVerified: Bool
    public let cohorts: [StudyCohortAudit]
    public let warnings: [String]
}

public struct ConfidenceInterval: Codable, Equatable, Sendable {
    public let lower: Double
    public let upper: Double
}

public struct LimitsOfAgreement: Codable, Equatable, Sendable {
    public let lower: Double
    public let upper: Double
}

public struct ScoreBandConfusion: Codable, Equatable, Sendable {
    /// Rows are official red/yellow/green; columns are NOOP red/yellow/green.
    public let matrix: [[Int]]
    public let accuracy: Double
}

/// Sanitized aggregate DTO. It deliberately has no subject identifier, dates,
/// paths, raw values, pairs, journal content, or archive hashes.
public struct AggregateMetricReport: Codable, Equatable, Sendable {
    public let metric: WhoopComparableMetric
    public let sourceMode: StudySourceMode
    public let algorithmRevisions: [String]
    public let subjectCount: Int
    public let pairedDayCount: Int
    public let eligibleDayCount: Int
    public let coveragePercent: Double

    /// Equal-participant metrics are primary so a long-tenure member cannot
    /// dominate a new member.
    public let macroBias: Double
    public let macroMeanAbsoluteError: Double
    public let macroRootMeanSquaredError: Double
    public let macroMAE95CI: ConfidenceInterval
    public let medianSubjectAbsoluteError: Double
    public let subjectAbsoluteErrorIQR: ConfidenceInterval

    /// Pooled-day metrics are secondary diagnostics.
    public let pooledBias: Double
    public let pooledMeanAbsoluteError: Double
    public let pooledMedianAbsoluteError: Double
    public let pooledRootMeanSquaredError: Double
    public let pooledP90AbsoluteError: Double
    public let pooledP95AbsoluteError: Double
    /// Equal-subject Fisher-z mean of each usable within-subject Pearson r.
    public let macroFisherPearsonCorrelation: Double?
    public let pooledPearsonCorrelation: Double?
    public let pooledSpearmanCorrelation: Double?
    public let pooledConcordanceCorrelation: Double?
    public let blandAltman95Limits: LimitsOfAgreement?
    public let calibrationIntercept: Double?
    public let calibrationSlope: Double?
    public let recoveryBandConfusion: ScoreBandConfusion?
}

public struct StudyComparisonReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let studyID: String
    public let cohort: StudyCohort
    public let shareability: StudyShareability
    public let splitLockVerified: Bool
    public let subjectCount: Int
    public let pairedOnDeviceSubjectCount: Int
    public let exportEmulatorSubjectCount: Int
    public let candidateID: String?
    public let candidateSignature: String?
    public let candidateMethod: String?
    public let metrics: [AggregateMetricReport]
    public let warnings: [String]
}

/// Private reproducibility receipt. Unlike the aggregate report this is not
/// shareable; it stays in the study vault and intentionally carries pseudonyms
/// and input digests, but still no biometric values or journal content.
public struct StudyPrivateRunAudit: Codable, Equatable, Sendable {
    public struct Input: Codable, Equatable, Sendable {
        public let subjectID: String
        public let sourceMode: StudySourceMode
        public let whoopExportSHA256: String
        public let noopDailyOutputSHA256: String?
    }

    public let schemaVersion: Int
    public let studyID: String
    public let cohort: StudyCohort
    public let createdAtUTC: String
    public let candidateID: String?
    public let candidateSignature: String?
    public let inputs: [Input]
    public let algorithmRevisions: [String]
}

public struct StudyRunArtifacts: Equatable, Sendable {
    public let report: StudyComparisonReport
    public let privateAudit: StudyPrivateRunAudit
}

public enum StudyError: Error, Equatable, LocalizedError {
    case badArguments(String)
    case unsupportedSchema(Int)
    case invalidStudyID
    case invalidSubjectID(String)
    case duplicateSubjectID(String)
    case missingCohort(StudyCohort)
    case pathMustBeRelative(String)
    case pathEscapesPrivateRoot(String)
    case missingFile(String)
    case unsafeSymlink(String)
    case insecurePermissions(String)
    case malformedManifest(String)
    case malformedLock(String)
    case malformedCandidate(String)
    case lockSignatureMismatch
    case lockKeyMustBeOutsidePrivateRoot
    case splitLockMismatch
    case invalidCandidateID
    case invalidCandidateTransform(String)
    case candidateSignatureMismatch
    case candidateStudyMismatch
    case candidateRevisionMismatch(metric: String)
    case candidateRequiredForValidation
    case validationRevealReceiptRequired
    case validationAlreadyRevealedWithDifferentCandidate
    case duplicateReferenceInput(first: String, second: String)
    case referenceDigestMismatch(String)
    case outputSubjectMismatch(expected: String, actual: String)
    case duplicateOutputDay(String)
    case unknownMetric(String)
    case missingMetricRevision(String)
    case invalidMetricValue(metric: String, day: String)
    case holdoutAcknowledgementRequired
    case noComparableData

    public var errorDescription: String? {
        switch self {
        case .badArguments(let message): return message
        case .unsupportedSchema(let version): return "Unsupported study schema version \(version)."
        case .invalidStudyID: return "Study ID must use 1–64 letters, digits, dots, dashes, or underscores."
        case .invalidSubjectID(let id):
            return "Invalid pseudonymous subject ID '\(id)'. Use 1–40 letters, digits, dashes, or underscores; never use an email or name."
        case .duplicateSubjectID(let id): return "Subject ID '\(id)' appears more than once."
        case .missingCohort(let cohort): return "The manifest has no \(cohort.rawValue) subjects."
        case .pathMustBeRelative(let path): return "Study input paths must be relative to the private root: \(path)"
        case .pathEscapesPrivateRoot(let path): return "Path escapes the private study root: \(path)"
        case .missingFile(let path): return "Required study input is missing: \(path)"
        case .unsafeSymlink(let path): return "Symlinks are not accepted as study inputs: \(path)"
        case .insecurePermissions(let path):
            return "Private study input is group/world accessible. Restrict it to mode 0600 (or a directory to 0700): \(path)"
        case .malformedManifest(let message): return "Malformed study manifest: \(message)"
        case .malformedLock(let message): return "Malformed study split lock: \(message)"
        case .malformedCandidate(let message): return "Malformed frozen candidate: \(message)"
        case .lockSignatureMismatch: return "Study split lock signature does not match. The split, lock, or key was changed."
        case .lockKeyMustBeOutsidePrivateRoot:
            return "The split-lock HMAC key must live outside the study root."
        case .splitLockMismatch: return "The manifest's subject allocation no longer matches the signed split lock."
        case .invalidCandidateID:
            return "Candidate ID must use 1–64 letters, digits, dots, dashes, or underscores."
        case .invalidCandidateTransform(let message):
            return "Invalid frozen candidate transform: \(message)"
        case .candidateSignatureMismatch:
            return "Frozen candidate signature does not match. The candidate was changed."
        case .candidateStudyMismatch:
            return "Frozen candidate belongs to a different study split."
        case .candidateRevisionMismatch(let metric):
            return "Frozen candidate expects a different base revision for \(metric)."
        case .candidateRequiredForValidation:
            return "Validation requires a signed candidate fitted and frozen from discovery data."
        case .validationRevealReceiptRequired:
            return "Validation requires a private reveal-receipt path."
        case .validationAlreadyRevealedWithDifferentCandidate:
            return "This holdout was already revealed with another candidate. Use new unseen subjects for further tuning."
        case .duplicateReferenceInput(let first, let second):
            return "Subjects \(first) and \(second) point to identical reference content. One participant must never cross cohorts under two pseudonyms."
        case .referenceDigestMismatch(let id): return "The sealed WHOOP reference input changed for subject \(id)."
        case .outputSubjectMismatch(let expected, let actual):
            return "NOOP output belongs to \(actual), but the manifest expected \(expected)."
        case .duplicateOutputDay(let day): return "NOOP output contains duplicate day \(day)."
        case .unknownMetric(let metric): return "NOOP output contains unsupported metric '\(metric)'."
        case .missingMetricRevision(let metric): return "NOOP output is missing an algorithm revision for \(metric)."
        case .invalidMetricValue(let metric, let day): return "NOOP output has an invalid \(metric) value on \(day)."
        case .holdoutAcknowledgementRequired:
            return "Validation is a sealed holdout reveal. Re-run with --acknowledge-holdout-reveal only after freezing the candidate."
        case .noComparableData: return "No exact-day official/NOOP metric pairs were available."
        }
    }
}
