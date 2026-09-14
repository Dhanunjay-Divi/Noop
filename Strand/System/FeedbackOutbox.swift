import Foundation

struct FeedbackOutboxLimits: Equatable {
    let maximumReports: Int
    let maximumTerminalReports: Int
    let maximumArchiveBytes: Int64
    let maximumTotalArchiveBytes: Int64
    let retention: TimeInterval
    let terminalRetention: TimeInterval

    static let production = FeedbackOutboxLimits(
        maximumReports: 3,
        maximumTerminalReports: 2,
        maximumArchiveBytes: 20 * 1024 * 1024,
        maximumTotalArchiveBytes: 64 * 1024 * 1024,
        retention: 14 * 24 * 60 * 60,
        terminalRetention: 24 * 60 * 60
    )

    func permitsArchive(byteCount: Int64) -> Bool {
        byteCount > 0 && byteCount <= maximumArchiveBytes
    }
}

enum FeedbackOutboxError: Error, Equatable {
    case invalidRecord
    case outboxFull
    case reportTooLarge
    case archiveMissing
    case archiveIntegrity
    case persistence
}

enum FeedbackDeliveryState: String, Codable, CaseIterable {
    case queued
    case reserving
    case uploading
    case completing
    case retryScheduled = "retry_scheduled"
    case sent
    case failed
    case cancelling
    case cancelled

    var requiresArchive: Bool {
        switch self {
        case .cancelling, .sent, .cancelled:
            return false
        default:
            return true
        }
    }

    var isTerminal: Bool {
        self == .sent || self == .cancelled || self == .failed
    }
}

enum FeedbackFailureKind: String, Codable, CaseIterable {
    case none
    case configuration
    case appCheck = "app_check"
    case identity
    case archiveIntegrity = "archive_integrity"
    case interrupted
    case reservationRejected = "reservation_rejected"
    case reservationUnavailable = "reservation_unavailable"
    case invalidResponse = "invalid_response"
    case uploadRejected = "upload_rejected"
    case uploadUnavailable = "upload_unavailable"
    case completionRejected = "completion_rejected"
    case completionUnavailable = "completion_unavailable"
    case reportRejected = "report_rejected"
    case statusUnavailable = "status_unavailable"
    case cancellationUnavailable = "cancellation_unavailable"
    case capabilityExpired = "capability_expired"
    case retryLimit = "retry_limit"
}

enum FeedbackReservationRecoveryHTTPPolicy {
    static let pendingStatusCodes: Set<Int> = [404]
    static let terminalStatusCodes: Set<Int> = [410]
    static let acceptedStatusCodes =
        Set(200...299).union(terminalStatusCodes)
}

struct FeedbackUploadCapability: Codable, Equatable {
    let method: String
    let url: String
    let headers: [String: String]
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case method, url, headers
        case expiresAt = "expires_at"
    }
}

struct FeedbackUploadTaskContext: Equatable, Hashable, Sendable {
    private static let prefix = "noop-feedback-upload-v1"

    let reportID: UUID
    let attemptID: UUID

    init(reportID: UUID, attemptID: UUID) {
        self.reportID = reportID
        self.attemptID = attemptID
    }

    init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let parts = taskDescription.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              parts[0] == Self.prefix,
              let reportID = UUID(uuidString: String(parts[1])),
              let attemptID = UUID(uuidString: String(parts[2])) else {
            return nil
        }
        self.init(reportID: reportID, attemptID: attemptID)
    }

    var taskDescription: String {
        [
            Self.prefix,
            reportID.uuidString.lowercased(),
            attemptID.uuidString.lowercased(),
        ].joined(separator: "|")
    }
}

struct FeedbackOutboxRecord: Codable, Equatable, Identifiable {
    static let schemaVersion = 1
    static let archiveFileName = "feedback.zip"

    let schemaVersion: Int
    let id: UUID
    let idempotencyKey: String
    let appVersion: String
    let createdAt: Date
    let consentConfirmedAt: Date
    let archiveFileName: String
    let archiveBytes: Int64
    let archiveSHA256: String
    let archiveManifest: FeedbackArchiveManifest

    var updatedAt: Date
    var state: FeedbackDeliveryState
    var uploadProgress: Double
    var attemptCount: Int
    var cancellationAttemptCount: Int?
    var nextRetryAt: Date?
    var failureKind: FeedbackFailureKind?
    var reportID: String?
    var reportToken: String?
    var identitySubjectSHA256: String?
    var upload: FeedbackUploadCapability?
    var retainedUntil: Date?
    var receipt: String?
    var cancelRequested: Bool
    var localArchiveRemoved: Bool?
    var clockAnomalyObservedAt: Date?
    var reservationContinuityStartedAt: Date? = nil
    var uploadAttemptID: UUID? = nil

    var includesUserNote: Bool {
        archiveManifest.includesUserNote
    }

    var includesScreenshot: Bool {
        archiveManifest.includesScreenshot
    }

    var requiresArchive: Bool {
        !cancelRequested && state.requiresArchive
    }

    var cancellationAttempts: Int {
        cancellationAttemptCount ?? 0
    }

    var localArchiveIsRemoved: Bool {
        localArchiveRemoved == true
    }

    var hasRemoteBinding: Bool {
        reportID != nil || reportToken != nil
    }

    enum CodingKeys: String, CodingKey {
        case id, state, upload, receipt
        case schemaVersion = "schema_version"
        case idempotencyKey = "idempotency_key"
        case appVersion = "app_version"
        case createdAt = "created_at"
        case consentConfirmedAt = "consent_confirmed_at"
        case archiveFileName = "archive_file_name"
        case archiveBytes = "archive_bytes"
        case archiveSHA256 = "archive_sha256"
        case archiveManifest = "archive_manifest"
        case updatedAt = "updated_at"
        case uploadProgress = "upload_progress"
        case attemptCount = "attempt_count"
        case cancellationAttemptCount = "cancellation_attempt_count"
        case nextRetryAt = "next_retry_at"
        case failureKind = "failure_kind"
        case reportID = "report_id"
        case reportToken = "report_token"
        case identitySubjectSHA256 = "identity_subject_sha256"
        case retainedUntil = "retained_until"
        case cancelRequested = "cancel_requested"
        case localArchiveRemoved = "local_archive_removed"
        case clockAnomalyObservedAt = "clock_anomaly_observed_at"
        case reservationContinuityStartedAt =
            "reservation_continuity_started_at"
        case uploadAttemptID = "upload_attempt_id"
    }
}

enum FeedbackRetryPolicy {
    static let maximumAutomaticAttempts = 8

    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        switch max(1, attempt) {
        case 1: return 30
        case 2: return 2 * 60
        case 3: return 10 * 60
        case 4: return 30 * 60
        case 5: return 2 * 60 * 60
        default: return 6 * 60 * 60
        }
    }
}

struct FeedbackBackgroundCompletionGate {
    private var completionHandler: (() -> Void)?
    private var eventsFinishedBeforeHandler = false

    mutating func install(
        _ completionHandler: @escaping () -> Void
    ) -> (() -> Void)? {
        if eventsFinishedBeforeHandler {
            eventsFinishedBeforeHandler = false
            return completionHandler
        }
        self.completionHandler = completionHandler
        return nil
    }

    mutating func finishEvents() -> (() -> Void)? {
        guard let completionHandler else {
            eventsFinishedBeforeHandler = true
            return nil
        }
        self.completionHandler = nil
        return completionHandler
    }
}

struct FeedbackStartupRecoveryGate {
    private enum Phase {
        case idle
        case recovering
        case started
    }

    private var phase = Phase.idle
    private var retryRequested = false

    mutating func requestStart() -> Bool {
        switch phase {
        case .idle:
            phase = .recovering
            return true
        case .recovering:
            retryRequested = true
            return false
        case .started:
            return false
        }
    }

    mutating func complete() {
        guard phase == .recovering else { return }
        phase = .started
        retryRequested = false
    }

    mutating func recoveryFailed() -> Bool {
        guard phase == .recovering else { return false }
        phase = .idle
        defer { retryRequested = false }
        return retryRequested
    }
}

struct FeedbackPumpGate {
    private var active = Set<UUID>()
    private var pending = Set<UUID>()

    mutating func begin(_ id: UUID) -> Bool {
        guard active.insert(id).inserted else {
            pending.insert(id)
            return false
        }
        return true
    }

    mutating func finish(_ id: UUID) -> Bool {
        active.remove(id)
        return pending.remove(id) != nil
    }
}

actor FeedbackIdentityAuthorizationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

enum FeedbackUploadStartPolicy {
    static func permitsResume(_ record: FeedbackOutboxRecord) -> Bool {
        record.state == .uploading
            && !record.cancelRequested
            && !record.localArchiveIsRemoved
            && record.hasRemoteBinding
            && record.identitySubjectSHA256 != nil
    }
}

enum FeedbackIdentitySubject {
    static let maximumUTF8Bytes = 256

    static func sha256(_ subject: String) -> String? {
        guard !subject.isEmpty,
              subject.utf8.count <= maximumUTF8Bytes else {
            return nil
        }
        return FeedbackDigest.sha256(Data(subject.utf8))
    }
}

enum FeedbackIdentityContinuityPolicy {
    static func canContactRemote(_ record: FeedbackOutboxRecord) -> Bool {
        !record.hasRemoteBinding || record.identitySubjectSHA256 != nil
    }

    static func permitsAnonymousIdentityReplacement(
        _ record: FeedbackOutboxRecord
    ) -> Bool {
        !record.hasRemoteBinding && record.identitySubjectSHA256 == nil
    }

    static func accepts(
        identitySubjectSHA256: String,
        for record: FeedbackOutboxRecord
    ) -> Bool {
        guard let expected = record.identitySubjectSHA256 else {
            return !record.hasRemoteBinding
        }
        return expected == identitySubjectSHA256
    }
}

enum FeedbackReservationIdentityAction: Equatable {
    case reuse
    case replace
    case deferReservation
}

enum FeedbackAnonymousIdentityLifetimePolicy {
    static let identityPlatformCleanupAge: TimeInterval =
        30 * 24 * 60 * 60
    static let maximumReportRetention: TimeInterval =
        28 * 24 * 60 * 60
    static let replacementSafetyMargin: TimeInterval =
        24 * 60 * 60
    static let maximumClockSkew: TimeInterval = 5 * 60
    static let providerCleanupSafetyReserve: TimeInterval = 60 * 60
    static let maximumExistingIdentityAge: TimeInterval =
        identityPlatformCleanupAge
            - maximumReportRetention
            - replacementSafetyMargin
            - maximumClockSkew
            - providerCleanupSafetyReserve

    static func reservationAction(
        identityCreatedAt: Date?,
        now: Date,
        hasActiveBoundReports: Bool
    ) -> FeedbackReservationIdentityAction {
        let age = identityCreatedAt.map {
            now.timeIntervalSince($0)
        }
        let canCoverRetention =
            age.map {
                $0 >= 0 && $0 <= maximumExistingIdentityAge
            } ?? false
        if canCoverRetention {
            return .reuse
        }
        return hasActiveBoundReports ? .deferReservation : .replace
    }
}

enum FeedbackAnonymousIdentityProviderPolicy {
    static func reservationAction(
        enforceLifetime: Bool,
        identityCreatedAt: Date?,
        now: Date,
        identitySubjectSHA256: String,
        reservationContinuityIdentitySubjectSHA256s: Set<String>
    ) -> FeedbackReservationIdentityAction {
        guard enforceLifetime else { return .reuse }
        return FeedbackAnonymousIdentityLifetimePolicy.reservationAction(
            identityCreatedAt: identityCreatedAt,
            now: now,
            hasActiveBoundReports:
                reservationContinuityIdentitySubjectSHA256s.contains(
                    identitySubjectSHA256
                )
        )
    }

    static func permitsStaleIdentityReplacement(
        identitySubjectSHA256: String,
        reservationContinuityIdentitySubjectSHA256s: Set<String>
    ) -> Bool {
        !reservationContinuityIdentitySubjectSHA256s.contains(
            identitySubjectSHA256
        )
    }
}

enum FeedbackReservationContinuityPolicy {
    static let maximumLocalDelayBeforeCancellation =
        FeedbackOutboxLimits.production.retention
    static let maximumRemoteRetention =
        FeedbackAnonymousIdentityLifetimePolicy.maximumReportRetention
    static let expirySafetyMargin =
        FeedbackAnonymousIdentityLifetimePolicy.replacementSafetyMargin
    static let maximumAmbiguousBindingLifetime =
        maximumRemoteRetention
            + FeedbackAnonymousIdentityLifetimePolicy.maximumClockSkew
            + expirySafetyMargin
    static let maximumRetryDelay: TimeInterval = 6 * 60 * 60
    static let minimumRetryDelay: TimeInterval = 1
    static let activeWorkLease: TimeInterval = 60 * 60
    static let maximumClockSkew =
        FeedbackAnonymousIdentityLifetimePolicy.maximumClockSkew

    // A nonterminal local binding may own an accepted reservation whose
    // response was lost, even when no server report ID has been persisted.
    static func identitySubjectSHA256sRequiringContinuity(
        in records: [FeedbackOutboxRecord],
        now: Date = Date()
    ) -> Set<String> {
        _ = now
        return Set(
            records.compactMap { record in
                guard requiresIdentityProtection(record) else { return nil }
                return record.identitySubjectSHA256
            }
        )
    }

    static func continuityDeadline(
        for record: FeedbackOutboxRecord
    ) -> Date? {
        guard hasPossibleRemoteReservation(record) else { return nil }
        if let retainedUntil = record.retainedUntil {
            return boundedServerRetainedUntil(
                retainedUntil,
                for: record
            ).addingTimeInterval(expirySafetyMargin)
        }
        return reservationContinuityStart(for: record).addingTimeInterval(
            maximumAmbiguousBindingLifetime
        )
    }

    static func maximumServerRetainedUntil(
        for record: FeedbackOutboxRecord
    ) -> Date {
        reservationContinuityStart(for: record).addingTimeInterval(
            maximumRemoteRetention + maximumClockSkew
        )
    }

    static func maximumAcceptedServerRetainedUntil(
        for record: FeedbackOutboxRecord,
        now: Date
    ) -> Date {
        min(
            maximumServerRetainedUntil(for: record),
            now.addingTimeInterval(
                maximumRemoteRetention + maximumClockSkew
            )
        )
    }

    static func boundedServerRetainedUntil(
        _ retainedUntil: Date,
        for record: FeedbackOutboxRecord,
        now: Date? = nil
    ) -> Date {
        let maximum = now.map {
            maximumAcceptedServerRetainedUntil(for: record, now: $0)
        } ?? maximumServerRetainedUntil(for: record)
        return min(retainedUntil, maximum)
    }

    static func serverRetentionIsValid(
        _ retainedUntil: Date,
        for record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        retainedUntil >= now.addingTimeInterval(-maximumClockSkew)
            && retainedUntil <= maximumAcceptedServerRetainedUntil(
                for: record,
                now: now
            )
    }

    static func permitsNewReservation(
        _ record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        !hasClockAnomaly(record, now: now)
            && now >= record.createdAt.addingTimeInterval(-maximumClockSkew)
            && now >= record.updatedAt.addingTimeInterval(-maximumClockSkew)
            && now < record.createdAt.addingTimeInterval(
                maximumLocalDelayBeforeCancellation
            )
    }

    static func requiresContinuity(
        _ record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        guard record.identitySubjectSHA256 != nil,
              let deadline = continuityDeadline(for: record) else {
            return false
        }
        return now < deadline || hasActiveWorkLease(record, now: now)
    }

    static func requiresIdentityProtection(
        _ record: FeedbackOutboxRecord
    ) -> Bool {
        record.identitySubjectSHA256 != nil
            && hasPossibleRemoteReservation(record)
    }

    static func hasExpired(
        _ record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        guard let deadline = continuityDeadline(for: record) else {
            return false
        }
        return now >= deadline && !hasActiveWorkLease(record, now: now)
    }

    static func retryDelay(
        in records: [FeedbackOutboxRecord],
        now: Date
    ) -> TimeInterval {
        let protectedRecords = records.filter(requiresIdentityProtection)
        let earliestRemaining = protectedRecords.compactMap {
            record -> TimeInterval? in
            guard requiresContinuity(record, now: now),
                  let deadline = effectiveRetryTarget(
                      for: record,
                      now: now
                  ) else {
                return nil
            }
            return deadline.timeIntervalSince(now)
        }.min()
        guard let earliestRemaining else {
            return protectedRecords.isEmpty
                ? minimumRetryDelay
                : maximumRetryDelay
        }
        return min(
            maximumRetryDelay,
            max(minimumRetryDelay, earliestRemaining)
        )
    }

    static func requiresIdentityLifetimeCheck(
        _ record: FeedbackOutboxRecord
    ) -> Bool {
        record.identitySubjectSHA256 == nil
    }

    static func hasPossibleRemoteReservation(
        _ record: FeedbackOutboxRecord
    ) -> Bool {
        switch record.state {
        case .sent, .cancelled:
            return false
        default:
            return record.identitySubjectSHA256 != nil
                || record.hasRemoteBinding
                || record.attemptCount > 0
        }
    }

    static func hasActiveWorkLease(
        _ record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        guard record.clockAnomalyObservedAt == nil,
              record.nextRetryAt == nil,
              record.updatedAt <= now.addingTimeInterval(maximumClockSkew),
              now < record.updatedAt.addingTimeInterval(activeWorkLease) else {
            return false
        }
        switch record.state {
        case .reserving, .uploading, .completing, .cancelling:
            return true
        case .queued, .retryScheduled, .sent, .cancelled, .failed:
            return false
        }
    }

    private static func effectiveRetryTarget(
        for record: FeedbackOutboxRecord,
        now: Date
    ) -> Date? {
        guard let deadline = continuityDeadline(for: record) else {
            return nil
        }
        guard hasActiveWorkLease(record, now: now) else {
            return deadline
        }
        return max(
            deadline,
            record.updatedAt.addingTimeInterval(activeWorkLease)
        )
    }

    static func needsClockAnomalyNormalization(
        _ record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        record.clockAnomalyObservedAt == nil
            && (
                record.createdAt > now.addingTimeInterval(maximumClockSkew)
                    || record.consentConfirmedAt
                        > now.addingTimeInterval(maximumClockSkew)
                    || record.updatedAt
                        > now.addingTimeInterval(maximumClockSkew)
            )
    }

    static func hasClockAnomaly(
        _ record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        record.clockAnomalyObservedAt != nil
            || needsClockAnomalyNormalization(record, now: now)
    }

    static func hasSecondaryClockRollback(
        _ record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        guard let observedAt = record.clockAnomalyObservedAt else {
            return false
        }
        let highWater = max(observedAt, record.updatedAt)
        return now < highWater.addingTimeInterval(-maximumClockSkew)
    }

    private static func reservationContinuityStart(
        for record: FeedbackOutboxRecord
    ) -> Date {
        record.reservationContinuityStartedAt
            ?? record.clockAnomalyObservedAt
            ?? record.createdAt
    }
}

enum FeedbackRetryWakePolicy {
    static func shouldWait(
        _ record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        guard let nextRetryAt = record.nextRetryAt,
              nextRetryAt > now else {
            return false
        }
        return !FeedbackReservationContinuityPolicy
            .hasSecondaryClockRollback(record, now: now)
    }
}

enum FeedbackReservationAttemptLane {
    case delivery
    case cancellation
}

enum FeedbackRemoteAbsenceAction: Equatable {
    case retryReservation
    case confirmDeletion
    case rejectIdentity
}

enum FeedbackRemoteAbsencePolicy {
    static func statusAction(
        for record: FeedbackOutboxRecord,
        authorizedIdentitySubjectSHA256: String
    ) -> FeedbackRemoteAbsenceAction {
        hasConfirmedContinuity(
            record,
            authorizedIdentitySubjectSHA256: authorizedIdentitySubjectSHA256
        ) ? .retryReservation : .rejectIdentity
    }

    static func cancellationAction(
        for record: FeedbackOutboxRecord,
        authorizedIdentitySubjectSHA256: String
    ) -> FeedbackRemoteAbsenceAction {
        hasConfirmedContinuity(
            record,
            authorizedIdentitySubjectSHA256: authorizedIdentitySubjectSHA256
        ) ? .confirmDeletion : .rejectIdentity
    }

    private static func hasConfirmedContinuity(
        _ record: FeedbackOutboxRecord,
        authorizedIdentitySubjectSHA256: String
    ) -> Bool {
        record.hasRemoteBinding
            && FeedbackIdentityContinuityPolicy.accepts(
                identitySubjectSHA256: authorizedIdentitySubjectSHA256,
                for: record
            )
    }
}

enum FeedbackCompletionRaceAction: Equatable {
    case markSent
    case cancelRemote
}

enum FeedbackCompletionRacePolicy {
    static func action(
        for latest: FeedbackOutboxRecord
    ) -> FeedbackCompletionRaceAction {
        latest.cancelRequested
            || latest.state == .cancelling
            || latest.state == .cancelled
            ? .cancelRemote
            : .markSent
    }
}

enum FeedbackDiagnosticOutcome: String, CaseIterable {
    case completed
    case deferred
    case failed
    case rejected
}

enum FeedbackDiagnostics {
    static func fields(
        state: FeedbackDeliveryState,
        outcome: FeedbackDiagnosticOutcome,
        failureKind: FeedbackFailureKind = .none
    ) -> [String: String] {
        [
            "state": state.rawValue,
            "outcome": outcome.rawValue,
            "failure_kind": failureKind.rawValue,
        ]
    }

    static func record(
        state: FeedbackDeliveryState,
        outcome: FeedbackDiagnosticOutcome,
        failureKind: FeedbackFailureKind = .none
    ) {
        AppDiagnosticsRecorder.shared.record(
            "feedback.delivery_transition",
            fields: fields(
                state: state,
                outcome: outcome,
                failureKind: failureKind
            )
        )
    }
}

actor FeedbackOutbox {
    static let shared = FeedbackOutbox()

    private static let stateFileName = "state.json"
    private static let temporaryPrefix = ".pending-"

    private let rootURL: URL
    private let limits: FeedbackOutboxLimits
    private let fileManager: FileManager

    init(
        rootURL: URL = FeedbackOutbox.defaultRootURL(),
        limits: FeedbackOutboxLimits = .production,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.limits = limits
        self.fileManager = fileManager
    }

    func enqueue(
        entries: [FileExport.BundleEntry],
        appVersion: String,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        try ensureRoot()
        try cleanup(now: now)
        guard FeedbackProtocolValidation.validAppVersion(appVersion) else {
            throw FeedbackOutboxError.invalidRecord
        }

        let existing = try loadRecords()
        let active = existing.filter { !isTerminal($0.state) }
        guard active.count < limits.maximumReports else {
            throw FeedbackOutboxError.outboxFull
        }

        let id = UUID()
        let temporaryDirectory = rootURL.appendingPathComponent(
            Self.temporaryPrefix + id.uuidString,
            isDirectory: true
        )
        let finalDirectory = reportDirectory(id)
        guard !fileManager.fileExists(atPath: finalDirectory.path) else {
            throw FeedbackOutboxError.persistence
        }

        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false
            )
            try FeedbackOutboxFileSecurity.protectDirectory(temporaryDirectory)
            let archiveURL = temporaryDirectory.appendingPathComponent(
                FeedbackOutboxRecord.archiveFileName
            )
            let package = try FeedbackArchiveBuilder.build(
                entries: entries,
                appVersion: appVersion,
                destinationURL: archiveURL,
                createdAt: now
            )
            guard limits.permitsArchive(byteCount: package.archiveBytes) else {
                throw FeedbackOutboxError.reportTooLarge
            }

            let currentBytes = try active.reduce(Int64(0)) {
                $0 + (try archiveSize(for: $1))
            }
            guard currentBytes + package.archiveBytes
                    <= limits.maximumTotalArchiveBytes else {
                throw FeedbackOutboxError.outboxFull
            }

            let record = FeedbackOutboxRecord(
                schemaVersion: FeedbackOutboxRecord.schemaVersion,
                id: id,
                idempotencyKey: id.uuidString.lowercased(),
                appVersion: appVersion,
                createdAt: now,
                consentConfirmedAt: now,
                archiveFileName: FeedbackOutboxRecord.archiveFileName,
                archiveBytes: package.archiveBytes,
                archiveSHA256: package.archiveSHA256,
                archiveManifest: package.manifest,
                updatedAt: now,
                state: .queued,
                uploadProgress: 0,
                attemptCount: 0,
                cancellationAttemptCount: 0,
                nextRetryAt: nil,
                failureKind: nil,
                reportID: nil,
                reportToken: nil,
                identitySubjectSHA256: nil,
                upload: nil,
                retainedUntil: nil,
                receipt: nil,
                cancelRequested: false,
                localArchiveRemoved: false,
                clockAnomalyObservedAt: nil,
                reservationContinuityStartedAt: nil,
                uploadAttemptID: nil
            )
            try persist(record, in: temporaryDirectory)
            try FeedbackOutboxFileSecurity.protectArchive(archiveURL)
            try fileManager.moveItem(
                at: temporaryDirectory,
                to: finalDirectory
            )
            try FeedbackOutboxFileSecurity.protectDirectory(finalDirectory)
            return record
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            if let archiveError = error as? FeedbackArchiveError {
                switch archiveError {
                case .integrityMismatch, .invalidArchive:
                    throw FeedbackOutboxError.archiveIntegrity
                default:
                    throw archiveError
                }
            }
            throw error
        }
    }

    func recover(now: Date = Date()) throws -> [FeedbackOutboxRecord] {
        try ensureRoot()
        try removeTemporaryDirectories()
        try cleanup(now: now)

        var recovered: [FeedbackOutboxRecord] = []
        for var record in try loadRecords() {
            var changed = false
            if isTerminal(record.state) || record.cancelRequested {
                let removed = cleanupLocalArchive(for: record)
                if record.localArchiveIsRemoved != removed {
                    record.localArchiveRemoved = removed
                    changed = true
                }
            } else if record.requiresArchive {
                do {
                    _ = try verifiedArchiveURL(for: record)
                } catch {
                    record.state = .failed
                    record.failureKind = .archiveIntegrity
                    record.nextRetryAt = nil
                    record.uploadAttemptID = nil
                    record.updatedAt = now
                    changed = true
                }
            }

            if record.state == .reserving {
                record.state = .retryScheduled
                record.failureKind = .interrupted
                record.nextRetryAt = now
                record.uploadAttemptID = nil
                record.updatedAt = now
                changed = true
            } else if record.state == .completing {
                record.failureKind = .interrupted
                record.nextRetryAt = now
                record.uploadAttemptID = nil
                record.updatedAt = now
                changed = true
            }

            if changed {
                try persist(record)
            }
            recovered.append(record)
        }
        return recovered.sorted { $0.createdAt > $1.createdAt }
    }

    func records(now: Date = Date()) throws -> [FeedbackOutboxRecord] {
        try ensureRoot()
        try cleanup(now: now)
        return try loadRecords().sorted { $0.createdAt > $1.createdAt }
    }

    func reservationContinuityIdentitySubjectSHA256s(
        now: Date = Date()
    ) throws -> Set<String> {
        FeedbackReservationContinuityPolicy
            .identitySubjectSHA256sRequiringContinuity(
                in: try records(now: now),
                now: now
            )
    }

    func latestActionable(now: Date = Date()) throws -> FeedbackOutboxRecord? {
        try records(now: now).first { !isTerminal($0.state) }
    }

    func record(
        id: UUID,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord? {
        try ensureRoot()
        try cleanup(now: now)
        return try loadRecord(id)
    }

    func verifiedArchiveURL(id: UUID) throws -> URL {
        guard let record = try loadRecord(id) else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try verifiedArchiveURL(for: record)
    }

    @discardableResult
    func beginAutomaticAttempt(
        id: UUID,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !isTerminal(current.state),
              !FeedbackReservationContinuityPolicy.hasExpired(
                  current,
                  now: now
              ) else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.attemptCount += 1
            record.nextRetryAt = nil
            record.updatedAt = now
        }
    }

    @discardableResult
    func beginCancellationAttempt(
        id: UUID,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              current.cancelRequested,
              !isTerminal(current.state) else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.cancellationAttemptCount = record.cancellationAttempts + 1
            record.nextRetryAt = nil
            record.uploadAttemptID = nil
            record.updatedAt = now
        }
    }

    @discardableResult
    func markReserving(id: UUID, now: Date = Date()) throws -> FeedbackOutboxRecord {
        return try update(id: id) { record in
            record.state = record.cancelRequested ? .cancelling : .reserving
            record.uploadProgress = 0
            record.nextRetryAt = nil
            record.failureKind = nil
            record.uploadAttemptID = nil
            record.updatedAt = now
        }
    }

    @discardableResult
    func bindIdentity(
        id: UUID,
        identitySubjectSHA256: String,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard FeedbackProtocolValidation.validIdentitySubjectSHA256(
            identitySubjectSHA256
        ),
        let current = try loadRecord(id),
        current.identitySubjectSHA256 == nil
            || current.identitySubjectSHA256 == identitySubjectSHA256 else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.identitySubjectSHA256 = identitySubjectSHA256
            if record.reservationContinuityStartedAt == nil {
                record.reservationContinuityStartedAt = now
            }
            record.updatedAt = max(record.updatedAt, now)
        }
    }

    @discardableResult
    func storeReservation(
        id: UUID,
        reportID: String,
        reportToken: String,
        upload: FeedbackUploadCapability?,
        retainedUntil: Date?,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              current.identitySubjectSHA256 != nil,
              current.reportID == nil || current.reportID == reportID,
              current.reportToken == nil || current.reportToken == reportToken else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.reportID = reportID
            record.reportToken = reportToken
            record.upload = upload
            record.retainedUntil = retainedUntil
            record.uploadAttemptID = nil
            if !record.cancelRequested {
                record.state = .queued
                record.uploadProgress = 0
                record.nextRetryAt = nil
                record.failureKind = nil
            }
            record.updatedAt = now
        }
    }

    @discardableResult
    func markUploading(
        id: UUID,
        attemptID: UUID = UUID(),
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !current.cancelRequested,
              !isTerminal(current.state) else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.state = .uploading
            record.uploadProgress = 0
            record.nextRetryAt = nil
            record.failureKind = nil
            record.uploadAttemptID = attemptID
            record.updatedAt = now
        }
    }

    @discardableResult
    func updateProgress(
        id: UUID,
        attemptID: UUID,
        fraction: Double,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id) else {
            throw FeedbackOutboxError.invalidRecord
        }
        let bounded = min(1, max(0, fraction))
        guard current.state == .uploading,
              current.uploadAttemptID == attemptID,
              bounded == 1 || bounded - current.uploadProgress >= 0.02 else {
            if current.state == .uploading,
               current.uploadAttemptID != attemptID {
                throw FeedbackOutboxError.invalidRecord
            }
            return current
        }
        return try update(id: id) { record in
            record.uploadProgress = bounded
            record.updatedAt = now
        }
    }

    @discardableResult
    func markCompleting(
        id: UUID,
        uploadAttemptID: UUID? = nil,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !current.cancelRequested,
              current.uploadAttemptID == uploadAttemptID,
              !isTerminal(current.state) else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.state = .completing
            record.uploadProgress = 1
            record.nextRetryAt = nil
            record.failureKind = nil
            record.uploadAttemptID = nil
            record.updatedAt = now
        }
    }

    @discardableResult
    func markRetryScheduled(
        id: UUID,
        failureKind: FeedbackFailureKind,
        nextRetryAt: Date,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !isTerminal(current.state) else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.state = .retryScheduled
            record.failureKind = failureKind
            record.nextRetryAt = nextRetryAt
            record.uploadAttemptID = nil
            record.updatedAt = now
        }
    }

    @discardableResult
    func markReservationContinuityWaiting(
        id: UUID,
        lane: FeedbackReservationAttemptLane,
        allowBoundIdentity: Bool = false,
        failureKind: FeedbackFailureKind = .identity,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        try ensureRoot()
        try cleanup(now: now)
        let current = try loadRecord(id)
        let identityMatchesWait =
            allowBoundIdentity
                ? current?.identitySubjectSHA256 != nil
                : current?.identitySubjectSHA256 == nil
        guard let current,
              identityMatchesWait,
              !current.hasRemoteBinding else {
            throw FeedbackOutboxError.invalidRecord
        }
        switch lane {
        case .delivery:
            guard current.attemptCount > 0,
                  current.state == .reserving
                    || (current.cancelRequested
                        && current.state == .cancelling) else {
                throw FeedbackOutboxError.invalidRecord
            }
        case .cancellation:
            guard current.cancelRequested,
                  current.state == .cancelling,
                  current.cancellationAttempts > 0 else {
                throw FeedbackOutboxError.invalidRecord
            }
        }
        let delay = FeedbackReservationContinuityPolicy.retryDelay(
            in: try loadRecords(),
            now: now
        )
        return try update(id: id) { record in
            switch lane {
            case .delivery:
                record.attemptCount = max(0, record.attemptCount - 1)
                record.state =
                    record.cancelRequested ? .cancelling : .retryScheduled
            case .cancellation:
                record.state = .cancelling
                record.cancellationAttemptCount = max(
                    0,
                    record.cancellationAttempts - 1
                )
            }
            record.failureKind = failureKind
            record.nextRetryAt = now.addingTimeInterval(delay)
            record.uploadAttemptID = nil
            record.updatedAt = max(record.updatedAt, now)
        }
    }

    @discardableResult
    func markCompletionRetryScheduled(
        id: UUID,
        failureKind: FeedbackFailureKind,
        nextRetryAt: Date,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !isTerminal(current.state) else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.state = .completing
            record.uploadProgress = 1
            record.failureKind = failureKind
            record.nextRetryAt = nextRetryAt
            record.uploadAttemptID = nil
            record.updatedAt = now
        }
    }

    @discardableResult
    func markFailed(
        id: UUID,
        failureKind: FeedbackFailureKind,
        unlessCancellationRequested: Bool = false,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !isTerminal(current.state),
              !(unlessCancellationRequested
                  && (current.cancelRequested
                      || current.state == .cancelling)) else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.state = .failed
            record.failureKind = failureKind
            record.nextRetryAt = nil
            record.uploadAttemptID = nil
            record.updatedAt = now
        }
    }

    @discardableResult
    func prepareManualRetry(
        id: UUID,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !isTerminal(current.state) else {
            throw FeedbackOutboxError.invalidRecord
        }
        return try update(id: id) { record in
            record.state = record.cancelRequested ? .cancelling : .queued
            record.uploadProgress = 0
            if record.cancelRequested {
                record.cancellationAttemptCount = 0
            } else {
                record.attemptCount = 0
            }
            record.nextRetryAt = nil
            record.failureKind = nil
            record.uploadAttemptID = nil
            record.updatedAt = now
        }
    }

    @discardableResult
    func requestCancellation(
        id: UUID,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !isTerminal(current.state) else {
            throw FeedbackOutboxError.invalidRecord
        }
        let alreadyRequested = current.cancelRequested
        let record = try update(id: id) { record in
            record.cancelRequested = true
            record.state = .cancelling
            record.upload = nil
            record.uploadAttemptID = nil
            if !alreadyRequested {
                record.cancellationAttemptCount = 0
                record.nextRetryAt = nil
                record.failureKind = nil
            }
            record.updatedAt = now
        }
        return persistArchiveCleanupOutcome(for: record)
    }

    @discardableResult
    func markCancellationPending(
        id: UUID,
        nextRetryAt: Date,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !isTerminal(current.state) else {
            throw FeedbackOutboxError.invalidRecord
        }
        let record = try update(id: id) { record in
            record.cancelRequested = true
            record.state = .cancelling
            record.uploadProgress = 0
            record.upload = nil
            record.uploadAttemptID = nil
            record.nextRetryAt = nextRetryAt
            record.failureKind = nil
            record.updatedAt = now
        }
        return persistArchiveCleanupOutcome(for: record)
    }

    @discardableResult
    func markSent(
        id: UUID,
        receipt: String,
        retainedUntil: Date?,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        guard let current = try loadRecord(id),
              !current.cancelRequested,
              !isTerminal(current.state) else {
            throw FeedbackOutboxError.invalidRecord
        }
        let record = try update(id: id) { record in
            record.state = .sent
            record.uploadProgress = 1
            record.receipt = receipt
            record.retainedUntil = retainedUntil
            record.reportToken = nil
            record.upload = nil
            record.uploadAttemptID = nil
            record.nextRetryAt = nil
            record.failureKind = nil
            record.cancelRequested = false
            record.updatedAt = now
        }
        return persistArchiveCleanupOutcome(for: record)
    }

    @discardableResult
    func markCancelled(
        id: UUID,
        now: Date = Date()
    ) throws -> FeedbackOutboxRecord {
        let record = try update(id: id) { record in
            record.state = .cancelled
            record.uploadProgress = 0
            record.reportToken = nil
            record.upload = nil
            record.uploadAttemptID = nil
            record.nextRetryAt = nil
            record.failureKind = nil
            record.cancelRequested = false
            record.updatedAt = now
        }
        return persistArchiveCleanupOutcome(for: record)
    }

    #if DEBUG
    func removeAllForUITesting() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.removeItem(at: rootURL)
    }
    #endif

    private func verifiedArchiveURL(
        for record: FeedbackOutboxRecord
    ) throws -> URL {
        guard record.schemaVersion == FeedbackOutboxRecord.schemaVersion,
              record.consentConfirmedAt >= record.createdAt,
              record.archiveFileName == FeedbackOutboxRecord.archiveFileName,
              FeedbackProtocolValidation.validAppVersion(record.appVersion) else {
            throw FeedbackOutboxError.invalidRecord
        }
        let archiveURL = reportDirectory(record.id)
            .appendingPathComponent(record.archiveFileName)
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw FeedbackOutboxError.archiveMissing
        }
        let package = FeedbackArchivePackage(
            archiveURL: archiveURL,
            archiveBytes: record.archiveBytes,
            archiveSHA256: record.archiveSHA256,
            manifest: record.archiveManifest
        )
        do {
            try FeedbackArchiveBuilder.verify(package: package)
            return archiveURL
        } catch {
            throw FeedbackOutboxError.archiveIntegrity
        }
    }

    private func update(
        id: UUID,
        mutation: (inout FeedbackOutboxRecord) -> Void
    ) throws -> FeedbackOutboxRecord {
        guard var record = try loadRecord(id) else {
            throw FeedbackOutboxError.invalidRecord
        }
        mutation(&record)
        try persist(record)
        return record
    }

    private func persist(
        _ record: FeedbackOutboxRecord,
        in directory: URL? = nil
    ) throws {
        let reportDirectory = directory ?? self.reportDirectory(record.id)
        let stateURL = reportDirectory.appendingPathComponent(Self.stateFileName)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(record)
            try data.write(to: stateURL, options: .atomic)
            try FeedbackOutboxFileSecurity.protectState(stateURL)
        } catch {
            throw FeedbackOutboxError.persistence
        }
    }

    private func loadRecord(_ id: UUID) throws -> FeedbackOutboxRecord? {
        let url = reportDirectory(id).appendingPathComponent(Self.stateFileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FeedbackOutboxError.persistence
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(
                FeedbackOutboxRecord.self,
                from: data
            )
            guard record.id == id,
                  record.schemaVersion == FeedbackOutboxRecord.schemaVersion,
                  record.identitySubjectSHA256.map(
                      FeedbackProtocolValidation.validIdentitySubjectSHA256
                  ) ?? true else {
                throw FeedbackOutboxError.invalidRecord
            }
            return record
        } catch let error as FeedbackOutboxError {
            throw error
        } catch {
            throw FeedbackOutboxError.invalidRecord
        }
    }

    private func loadRecords() throws -> [FeedbackOutboxRecord] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var records: [FeedbackOutboxRecord] = []
        for url in children {
            guard let id = UUID(uuidString: url.lastPathComponent) else {
                continue
            }
            do {
                if let record = try loadRecord(id) {
                    records.append(record)
                }
            } catch FeedbackOutboxError.invalidRecord {
                try? fileManager.removeItem(at: url)
                AppDiagnosticsRecorder.shared.record(
                    "feedback.outbox_record_rejected",
                    fields: ["outcome": "invalid_record"]
                )
            } catch {
                AppDiagnosticsRecorder.shared.record(
                    "feedback.outbox_record_deferred",
                    fields: ["outcome": "state_unavailable"]
                )
                throw error
            }
        }
        return records
    }

    private func cleanup(now: Date) throws {
        try removeTemporaryDirectories()
        var records = try loadRecords()
        for var record in records {
            if record.identitySubjectSHA256 != nil,
               record.reservationContinuityStartedAt == nil {
                record.reservationContinuityStartedAt = min(
                    record.createdAt,
                    min(record.updatedAt, now)
                )
                try persist(record)
            }

            if FeedbackReservationContinuityPolicy
                .needsClockAnomalyNormalization(record, now: now) {
                if isTerminal(record.state) {
                    record.clockAnomalyObservedAt = now
                    record.updatedAt = now
                    try persist(record)
                    AppDiagnosticsRecorder.shared.record(
                        "feedback.clock_anomaly",
                        fields: ["outcome": "terminal_normalized"]
                    )
                } else if FeedbackReservationContinuityPolicy
                    .hasPossibleRemoteReservation(record) {
                    record.clockAnomalyObservedAt = now
                    record.reservationContinuityStartedAt = min(
                        record.reservationContinuityStartedAt ?? now,
                        now
                    )
                    record.state = .cancelling
                    record.uploadProgress = 0
                    if !record.cancelRequested {
                        record.cancellationAttemptCount = 0
                    }
                    record.nextRetryAt = now
                    record.failureKind = nil
                    record.upload = nil
                    record.uploadAttemptID = nil
                    record.cancelRequested = true
                    record.updatedAt = now
                    try persist(record)
                    _ = persistArchiveCleanupOutcome(for: record)
                    AppDiagnosticsRecorder.shared.record(
                        "feedback.clock_anomaly",
                        fields: ["outcome": "cancellation_required"]
                    )
                    continue
                } else {
                    try? fileManager.removeItem(at: reportDirectory(record.id))
                    AppDiagnosticsRecorder.shared.record(
                        "feedback.clock_anomaly",
                        fields: ["outcome": "local_record_removed"]
                    )
                    continue
                }
            }

            if FeedbackReservationContinuityPolicy
                .hasSecondaryClockRollback(record, now: now),
               !isTerminal(record.state) {
                record.clockAnomalyObservedAt = now
                if let continuityStartedAt =
                    record.reservationContinuityStartedAt,
                   continuityStartedAt > now {
                    record.reservationContinuityStartedAt = now
                }
                if record.nextRetryAt.map({ $0 > now }) == true {
                    record.nextRetryAt = now
                }
                record.updatedAt = now
                try persist(record)
                AppDiagnosticsRecorder.shared.record(
                    "feedback.clock_anomaly",
                    fields: ["outcome": "secondary_normalized"]
                )
            }

            let age = now.timeIntervalSince(record.createdAt)
            let terminalAge = now.timeIntervalSince(record.updatedAt)

            if isTerminal(record.state) {
                if age >= limits.retention
                    || terminalAge >= limits.terminalRetention {
                    try? fileManager.removeItem(at: reportDirectory(record.id))
                }
                continue
            }

            if FeedbackReservationContinuityPolicy.hasExpired(
                record,
                now: now
            ) {
                if record.state == .failed,
                   record.failureKind == .capabilityExpired,
                   record.cancelRequested {
                    _ = persistArchiveCleanupOutcome(for: record)
                    continue
                }
                record.state = .failed
                record.uploadProgress = 0
                record.upload = nil
                record.uploadAttemptID = nil
                record.nextRetryAt = nil
                record.failureKind = .capabilityExpired
                record.cancelRequested = true
                record.updatedAt = max(record.updatedAt, now)
                try persist(record)
                _ = persistArchiveCleanupOutcome(for: record)
                AppDiagnosticsRecorder.shared.record(
                    "feedback.identity_continuity_expired",
                    fields: ["outcome": "deletion_unconfirmed"]
                )
                continue
            }

            guard age >= limits.retention,
                  !record.cancelRequested,
                  !FeedbackReservationContinuityPolicy.hasActiveWorkLease(
                      record,
                      now: now
                  ) else {
                continue
            }

            record.uploadProgress = 0
            record.upload = nil
            record.uploadAttemptID = nil
            record.nextRetryAt = now
            record.failureKind = nil
            record.updatedAt = now

            if record.reportID != nil
                || record.reportToken != nil
                || record.attemptCount > 0 {
                record.cancelRequested = true
                record.cancellationAttemptCount = 0
                record.state = .cancelling
                try persist(record)
                _ = persistArchiveCleanupOutcome(for: record)
                AppDiagnosticsRecorder.shared.record(
                    "feedback.local_retention_transition",
                    fields: ["outcome": "cancelling"]
                )
            } else {
                record.state = .cancelled
                record.reportID = nil
                record.reportToken = nil
                record.nextRetryAt = nil
                try persist(record)
                _ = persistArchiveCleanupOutcome(for: record)
                AppDiagnosticsRecorder.shared.record(
                    "feedback.local_retention_transition",
                    fields: ["outcome": "cancelled"]
                )
            }
        }
        records = try loadRecords()
        for record in records
            .filter({ isTerminal($0.state) })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .dropFirst(limits.maximumTerminalReports) {
            try? fileManager.removeItem(at: reportDirectory(record.id))
        }
    }

    private func removeTemporaryDirectories() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        for child in children
        where child.lastPathComponent.hasPrefix(Self.temporaryPrefix) {
            try? fileManager.removeItem(at: child)
        }
    }

    @discardableResult
    private func removeArchive(for record: FeedbackOutboxRecord) throws -> Bool {
        let archiveURL = reportDirectory(record.id)
            .appendingPathComponent(record.archiveFileName)
        guard fileManager.fileExists(atPath: archiveURL.path) else { return false }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archiveURL.path
        )
        do {
            try fileManager.removeItem(at: archiveURL)
            return true
        } catch {
            throw FeedbackOutboxError.persistence
        }
    }

    private func cleanupLocalArchive(for record: FeedbackOutboxRecord) -> Bool {
        do {
            guard try removeArchive(for: record) else { return true }
            AppDiagnosticsRecorder.shared.record(
                "feedback.local_archive_cleanup",
                fields: ["outcome": "completed"]
            )
            return true
        } catch {
            AppDiagnosticsRecorder.shared.record(
                "feedback.local_archive_cleanup",
                fields: ["outcome": "failed"]
            )
            return false
        }
    }

    private func persistArchiveCleanupOutcome(
        for record: FeedbackOutboxRecord
    ) -> FeedbackOutboxRecord {
        let removed = cleanupLocalArchive(for: record)
        guard removed != record.localArchiveIsRemoved else {
            return record
        }
        do {
            return try update(id: record.id) { current in
                current.localArchiveRemoved = removed
            }
        } catch {
            return record
        }
    }

    private func archiveSize(for record: FeedbackOutboxRecord) throws -> Int64 {
        let url = reportDirectory(record.id)
            .appendingPathComponent(record.archiveFileName)
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func ensureRoot() throws {
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try FeedbackOutboxFileSecurity.protectDirectory(rootURL)
        } catch {
            throw FeedbackOutboxError.persistence
        }
    }

    private func reportDirectory(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func isTerminal(_ state: FeedbackDeliveryState) -> Bool {
        state == .sent || state == .cancelled
    }

    static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(
            "NOOP/FeedbackOutbox",
            isDirectory: true
        )
    }
}

private enum FeedbackOutboxFileSecurity {
    static func protectDirectory(_ url: URL) throws {
        try excludeFromBackup(url)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
                .posixPermissions: 0o700,
            ],
            ofItemAtPath: url.path
        )
        #else
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        #endif
    }

    static func protectState(_ url: URL) throws {
        try excludeFromBackup(url)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
                .posixPermissions: 0o600,
            ],
            ofItemAtPath: url.path
        )
        #else
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        #endif
    }

    static func protectArchive(_ url: URL) throws {
        try excludeFromBackup(url)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
                .posixPermissions: 0o400,
            ],
            ofItemAtPath: url.path
        )
        #else
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
