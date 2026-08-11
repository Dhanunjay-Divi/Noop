import CryptoKit
import Foundation
import StrandAnalytics

private struct UnsignedStudyCandidate: Codable, Equatable {
    let schemaVersion: Int
    let candidateID: String
    let studyID: String
    let splitLockSignature: String
    let createdAtUTC: String
    let method: String
    let transforms: [StudyCandidateTransform]
}

private struct UnsignedValidationRevealReceipt: Codable, Equatable {
    let schemaVersion: Int
    let studyID: String
    let splitLockSignature: String
    let candidateSignature: String
    let validationInputs: [StudyValidationInputDigest]
    let revealedAtUTC: String
}

public enum StudyCandidateLocker {
    public static let method = "equal-subject-bias-only-v1"

    public static func fit(
        manifest: StudyManifest,
        lock: StudySplitLock,
        privateRoot: URL,
        keyURL: URL,
        candidateID: String,
        now: Date = Date()
    ) throws -> StudyCandidate {
        try StudySplitLocker.verify(
            manifest: manifest,
            lock: lock,
            privateRoot: privateRoot,
            keyURL: keyURL
        )
        guard safeIdentifier(candidateID) else { throw StudyError.invalidCandidateID }

        var comparisons: [SubjectMetricComparison] = []
        for subject in manifest.subjects
            .filter({ $0.cohort == .discovery })
            .sorted(by: { $0.subjectID < $1.subjectID }) {
            let exportURL = try StudyPaths.resolveInput(
                subject.whoopExport,
                under: privateRoot
            )
            let reference = try WhoopReferenceAdapter.load(from: exportURL)
            let prediction = WalkForwardExportEmulator.predict(reference.featureDays)
            comparisons += StudySubjectComparator.compare(
                subjectID: subject.subjectID,
                reference: reference,
                prediction: prediction
            )
        }

        var transforms: [StudyCandidateTransform] = []
        for metric in [WhoopComparableMetric.recoveryScore, .restScore] {
            let eligible = comparisons.filter {
                $0.metric == metric
                    && $0.sourceMode == .exportFeatureEmulator
                    && $0.pairCount >= 7
            }
            guard !eligible.isEmpty else { continue }
            let revisions = Set(eligible.map(\.revision))
            guard revisions.count == 1, let baseRevision = revisions.first else {
                throw StudyError.invalidCandidateTransform(
                    "\(metric.rawValue) has inconsistent base revisions"
                )
            }

            // Every participant contributes one bias estimate, regardless of
            // history length. The offset is bounded so a tiny discovery cohort
            // cannot radically remap an otherwise transparent 0...100 score.
            let meanSubjectBias = eligible.map(\.bias).reduce(0, +)
                / Double(eligible.count)
            let offset = min(20, max(-20, -meanSubjectBias))
            transforms.append(StudyCandidateTransform(
                metric: metric,
                baseRevision: baseRevision,
                slope: 1,
                offset: offset,
                discoverySubjectCount: eligible.count,
                discoveryPairCount: eligible.reduce(0) { $0 + $1.pairCount }
            ))
        }
        guard !transforms.isEmpty else { throw StudyError.noComparableData }

        let unsigned = UnsignedStudyCandidate(
            schemaVersion: 1,
            candidateID: candidateID,
            studyID: manifest.studyID,
            splitLockSignature: lock.signature,
            createdAtUTC: iso8601.string(from: now),
            method: method,
            transforms: transforms.sorted { $0.metric.rawValue < $1.metric.rawValue }
        )
        return StudyCandidate(
            schemaVersion: unsigned.schemaVersion,
            candidateID: unsigned.candidateID,
            studyID: unsigned.studyID,
            splitLockSignature: unsigned.splitLockSignature,
            createdAtUTC: unsigned.createdAtUTC,
            method: unsigned.method,
            transforms: unsigned.transforms,
            signature: try sign(unsigned, keyURL: keyURL, privateRoot: privateRoot)
        )
    }

    public static func load(from url: URL) throws -> StudyCandidate {
        do {
            return try JSONDecoder().decode(StudyCandidate.self, from: Data(contentsOf: url))
        } catch {
            throw StudyError.malformedCandidate(error.localizedDescription)
        }
    }

    public static func verify(
        _ candidate: StudyCandidate,
        lock: StudySplitLock,
        privateRoot: URL,
        keyURL: URL
    ) throws {
        guard candidate.schemaVersion == 1 else {
            throw StudyError.unsupportedSchema(candidate.schemaVersion)
        }
        guard safeIdentifier(candidate.candidateID) else { throw StudyError.invalidCandidateID }
        guard candidate.studyID == lock.studyID,
              candidate.splitLockSignature == lock.signature
        else {
            throw StudyError.candidateStudyMismatch
        }
        try validateTransforms(candidate.transforms, method: candidate.method)
        let unsigned = UnsignedStudyCandidate(
            schemaVersion: candidate.schemaVersion,
            candidateID: candidate.candidateID,
            studyID: candidate.studyID,
            splitLockSignature: candidate.splitLockSignature,
            createdAtUTC: candidate.createdAtUTC,
            method: candidate.method,
            transforms: candidate.transforms
        )
        let expected = try sign(unsigned, keyURL: keyURL, privateRoot: privateRoot)
        guard constantTimeEqual(expected, candidate.signature) else {
            throw StudyError.candidateSignatureMismatch
        }
    }

    public static func apply(
        _ candidate: StudyCandidate,
        to prediction: StudyPredictionSet
    ) throws -> StudyPredictionSet {
        var values = prediction.valuesByMetric
        var revisions = prediction.revisionByMetric
        for transform in candidate.transforms {
            guard let baseRevision = revisions[transform.metric],
                  baseRevision == transform.baseRevision
            else {
                throw StudyError.candidateRevisionMismatch(
                    metric: transform.metric.rawValue
                )
            }
            guard let raw = values[transform.metric] else { continue }
            values[transform.metric] = raw.mapValues {
                min(100, max(0, transform.offset + transform.slope * $0))
            }
            revisions[transform.metric] =
                "\(baseRevision)+candidate-\(candidate.signature.prefix(12))"
        }
        return StudyPredictionSet(
            sourceMode: prediction.sourceMode,
            valuesByMetric: values,
            revisionByMetric: revisions
        )
    }

    public static func reserveValidationReveal(
        candidate: StudyCandidate,
        lock: StudySplitLock,
        validationInputs: [StudyValidationInputDigest],
        receiptURL: URL,
        privateRoot: URL,
        keyURL: URL,
        now: Date = Date()
    ) throws {
        try verify(candidate, lock: lock, privateRoot: privateRoot, keyURL: keyURL)
        let sortedInputs = validationInputs.sorted { $0.subjectID < $1.subjectID }
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            try StudyPaths.requirePrivatePermissions(receiptURL)
            let receipt: StudyValidationRevealReceipt
            do {
                receipt = try JSONDecoder().decode(
                    StudyValidationRevealReceipt.self,
                    from: Data(contentsOf: receiptURL)
                )
            } catch {
                throw StudyError.malformedCandidate(
                    "validation reveal receipt: \(error.localizedDescription)"
                )
            }
            try verifyReceipt(
                receipt,
                lock: lock,
                candidate: candidate,
                validationInputs: sortedInputs,
                keyURL: keyURL,
                privateRoot: privateRoot
            )
            return
        }

        let unsigned = UnsignedValidationRevealReceipt(
            schemaVersion: 1,
            studyID: lock.studyID,
            splitLockSignature: lock.signature,
            candidateSignature: candidate.signature,
            validationInputs: sortedInputs,
            revealedAtUTC: iso8601.string(from: now)
        )
        let receipt = StudyValidationRevealReceipt(
            schemaVersion: unsigned.schemaVersion,
            studyID: unsigned.studyID,
            splitLockSignature: unsigned.splitLockSignature,
            candidateSignature: unsigned.candidateSignature,
            validationInputs: unsigned.validationInputs,
            revealedAtUTC: unsigned.revealedAtUTC,
            signature: try sign(unsigned, keyURL: keyURL, privateRoot: privateRoot)
        )
        try StudySplitLocker.write(receipt, to: receiptURL)
    }

    private static func verifyReceipt(
        _ receipt: StudyValidationRevealReceipt,
        lock: StudySplitLock,
        candidate: StudyCandidate,
        validationInputs: [StudyValidationInputDigest],
        keyURL: URL,
        privateRoot: URL
    ) throws {
        let unsigned = UnsignedValidationRevealReceipt(
            schemaVersion: receipt.schemaVersion,
            studyID: receipt.studyID,
            splitLockSignature: receipt.splitLockSignature,
            candidateSignature: receipt.candidateSignature,
            validationInputs: receipt.validationInputs,
            revealedAtUTC: receipt.revealedAtUTC
        )
        let expected = try sign(unsigned, keyURL: keyURL, privateRoot: privateRoot)
        guard constantTimeEqual(expected, receipt.signature) else {
            throw StudyError.candidateSignatureMismatch
        }
        guard receipt.schemaVersion == 1,
              receipt.studyID == lock.studyID,
              receipt.splitLockSignature == lock.signature,
              receipt.candidateSignature == candidate.signature,
              receipt.validationInputs == validationInputs
        else {
            throw StudyError.validationAlreadyRevealedWithDifferentCandidate
        }
    }

    private static func validateTransforms(
        _ transforms: [StudyCandidateTransform],
        method: String
    ) throws {
        guard method == Self.method, !transforms.isEmpty else {
            throw StudyError.invalidCandidateTransform("unsupported or empty method")
        }
        var metrics = Set<WhoopComparableMetric>()
        for transform in transforms {
            guard metrics.insert(transform.metric).inserted,
                  transform.metric == .recoveryScore || transform.metric == .restScore,
                  !transform.baseRevision.isEmpty,
                  transform.slope.isFinite,
                  abs(transform.slope - 1) < 1e-12,
                  transform.offset.isFinite,
                  (-20...20).contains(transform.offset),
                  transform.discoverySubjectCount > 0,
                  transform.discoveryPairCount >= transform.discoverySubjectCount * 7
            else {
                throw StudyError.invalidCandidateTransform(transform.metric.rawValue)
            }
        }
    }

    private static func sign<T: Encodable>(
        _ value: T,
        keyURL: URL,
        privateRoot: URL
    ) throws -> String {
        try requireKeyOutsidePrivateRoot(keyURL, privateRoot: privateRoot)
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            throw StudyError.missingFile(keyURL.path)
        }
        try StudyPaths.requirePrivatePermissions(keyURL)
        let keyData = try Data(contentsOf: keyURL)
        guard keyData.count == 32 else {
            throw StudyError.malformedLock("The HMAC key must contain exactly 32 bytes.")
        }
        let code = HMAC<SHA256>.authenticationCode(
            for: try canonicalData(value),
            using: SymmetricKey(data: keyData)
        )
        return StudyFileDigest.hex(code)
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    private static func requireKeyOutsidePrivateRoot(
        _ keyURL: URL,
        privateRoot: URL
    ) throws {
        let root = privateRoot.standardizedFileURL.resolvingSymlinksInPath()
        let key = keyURL.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if key.path == root.path || key.path.hasPrefix(prefix) {
            throw StudyError.lockKeyMustBeOutsidePrivateRoot
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
