#if os(iOS)
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation
import UIKit

extension Notification.Name {
    static let feedbackOutboxDidChange = Notification.Name(
        "com.noop.feedback-outbox-did-change"
    )
}

private enum FeedbackFirebaseError: Error {
    case configuration
    case appCheck
    case identity
    case identityReservationDeferred
    case identityContinuity
}

private struct FeedbackAPIConfiguration {
    let baseURL: URL
    let allowsLocalHTTP: Bool

    static func load(bundle: Bundle = .main) throws -> FeedbackAPIConfiguration {
        guard let raw = value("NOOPManagedAPIURL", bundle: bundle),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw FeedbackFirebaseError.configuration
        }
        let allowsLocalHTTP = debugFlag(
            "NOOPManagedAllowLocalHTTP",
            bundle: bundle
        )
        guard scheme == "https"
                || (scheme == "http" && allowsLocalHTTP && isLocal(url)) else {
            throw FeedbackFirebaseError.configuration
        }
        return FeedbackAPIConfiguration(
            baseURL: url,
            allowsLocalHTTP: allowsLocalHTTP
        )
    }

    func endpoint(_ path: String) throws -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw FeedbackFirebaseError.configuration
        }
        let basePath = components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let suffix = path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        components.path = "/" + [basePath, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw FeedbackFirebaseError.configuration
        }
        return url
    }

    func validateSignedUpload(
        method: String,
        url rawURL: String,
        headers: [String: String],
        archiveBytes: Int64,
        archiveSHA256: String,
        expiresAt: Date
    ) throws -> FeedbackUploadCapability {
        let normalizedMethod = method.uppercased()
        guard normalizedMethod == "PUT",
              let url = URL(string: rawURL),
              FeedbackProtocolValidation.validSignedUpload(
                  url: url,
                  headers: headers,
                  archiveBytes: archiveBytes,
                  archiveSHA256: archiveSHA256,
                  allowsLocalHTTP: allowsLocalHTTP
              ),
              expiresAt > Date(),
              archiveBytes > 0 else {
            throw FeedbackTransportFailure(
                kind: .invalidResponse,
                retryable: false
            )
        }
        return FeedbackUploadCapability(
            method: normalizedMethod,
            url: rawURL,
            headers: headers,
            expiresAt: expiresAt
        )
    }

    private static func value(_ key: String, bundle: Bundle) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.contains("$(") ? nil : value
    }

    private static func debugFlag(_ key: String, bundle: Bundle) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return value.boolValue
        }
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
            return false
        }
        return ["1", "true", "yes"].contains(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        #else
        _ = key
        _ = bundle
        return false
        #endif
    }

    private static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
    }

}

private struct FeedbackFirebaseAuthorization: Sendable {
    let appCheckToken: String
    let identityToken: String
    let identitySubjectSHA256: String
}

@MainActor
private enum FeedbackFirebaseAuthorizationProvider {
    private struct Runtime {
        let auth: Auth
        let appCheck: AppCheck
    }

    private struct FirebaseValues {
        let projectID: String
        let apiKey: String
        let googleAppID: String
        let senderID: String
    }

    private struct IdentityAuthorization {
        let token: String
        let subjectSHA256: String
    }

    static func authorization(
        forceRefresh: Bool,
        allowIdentityReplacement: Bool,
        expectedIdentitySubjectSHA256: String?,
        enforceReservationIdentityLifetime: Bool,
        reservationContinuityIdentitySubjectSHA256s: Set<String>
    ) async throws -> FeedbackFirebaseAuthorization {
        let runtime = try runtime()
        await identityGate.acquire()
        let identity: IdentityAuthorization
        do {
            identity = try await identityAuthorization(
                runtime.auth,
                forceRefresh: forceRefresh,
                allowReplacement: allowIdentityReplacement,
                expectedSubjectSHA256: expectedIdentitySubjectSHA256,
                enforceReservationIdentityLifetime:
                    enforceReservationIdentityLifetime,
                reservationContinuityIdentitySubjectSHA256s:
                    reservationContinuityIdentitySubjectSHA256s
            )
            await identityGate.release()
        } catch {
            await identityGate.release()
            throw error
        }
        let appCheckToken = try await appCheckToken(
            runtime.appCheck,
            forceRefresh: forceRefresh
        )
        return FeedbackFirebaseAuthorization(
            appCheckToken: appCheckToken,
            identityToken: identity.token,
            identitySubjectSHA256: identity.subjectSHA256
        )
    }

    private static func appCheckToken(
        _ appCheck: AppCheck,
        forceRefresh: Bool
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            appCheck.token(forcingRefresh: forceRefresh) { token, error in
                guard let value = token?.token,
                      !value.isEmpty,
                      value.utf8.count <= 16_384 else {
                    _ = error
                    continuation.resume(throwing: FeedbackFirebaseError.appCheck)
                    return
                }
                continuation.resume(returning: value)
            }
        }
    }

    private static func identityAuthorization(
        _ auth: Auth,
        forceRefresh: Bool,
        allowReplacement: Bool,
        expectedSubjectSHA256: String?,
        enforceReservationIdentityLifetime: Bool,
        reservationContinuityIdentitySubjectSHA256s: Set<String>
    ) async throws -> IdentityAuthorization {
        var (user, createdNow) = try await identityUser(
            auth,
            allowCreation: allowReplacement && expectedSubjectSHA256 == nil
        )
        var subjectSHA256 = try validatedSubjectSHA256(
            user,
            expected: expectedSubjectSHA256
        )
        let now = Date()
        let action =
            FeedbackAnonymousIdentityProviderPolicy.reservationAction(
                enforceLifetime: enforceReservationIdentityLifetime,
                identityCreatedAt:
                    createdNow ? now : user.metadata.creationDate,
                now: now,
                identitySubjectSHA256: subjectSHA256,
                reservationContinuityIdentitySubjectSHA256s:
                    reservationContinuityIdentitySubjectSHA256s
            )
        if enforceReservationIdentityLifetime {
            switch action {
            case .reuse:
                break
            case .replace:
                guard allowReplacement,
                      expectedSubjectSHA256 == nil else {
                    throw FeedbackFirebaseError.identity
                }
                user = try await replaceIdentity(auth)
                subjectSHA256 = try validatedSubjectSHA256(
                    user,
                    expected: nil
                )
            case .deferReservation:
                throw FeedbackFirebaseError.identityReservationDeferred
            }
        }
        do {
            let token = try await user.getIDToken(forcingRefresh: forceRefresh)
            guard !token.isEmpty, token.utf8.count <= 16_384 else {
                throw FeedbackFirebaseError.identity
            }
            return IdentityAuthorization(
                token: token,
                subjectSHA256: subjectSHA256
            )
        } catch {
            guard allowReplacement,
                  expectedSubjectSHA256 == nil,
                  permitsAnonymousIdentityReplacement(after: error),
                  FeedbackAnonymousIdentityProviderPolicy
                    .permitsStaleIdentityReplacement(
                        identitySubjectSHA256: subjectSHA256,
                        reservationContinuityIdentitySubjectSHA256s:
                            reservationContinuityIdentitySubjectSHA256s
                    ) else {
                throw FeedbackFirebaseError.identity
            }

            // Identity Platform can remove an inactive anonymous user. Replace only
            // an explicitly stale identity before a report has a server binding.
            let replacement = try await replaceIdentity(auth)
            let replacementSubjectSHA256 = try validatedSubjectSHA256(
                replacement,
                expected: nil
            )
            do {
                let token = try await replacement.getIDToken(
                    forcingRefresh: true
                )
                guard !token.isEmpty, token.utf8.count <= 16_384 else {
                    throw FeedbackFirebaseError.identity
                }
                return IdentityAuthorization(
                    token: token,
                    subjectSHA256: replacementSubjectSHA256
                )
            } catch {
                throw FeedbackFirebaseError.identity
            }
        }
    }

    private static func replaceIdentity(
        _ auth: Auth
    ) async throws -> User {
        do {
            try auth.signOut()
            return try await auth.signInAnonymously().user
        } catch {
            throw FeedbackFirebaseError.identity
        }
    }

    private static func permitsAnonymousIdentityReplacement(
        after error: Error
    ) -> Bool {
        let code = (error as NSError).code
        return code == AuthErrorCode.userNotFound.rawValue
            || code == AuthErrorCode.invalidUserToken.rawValue
            || code == AuthErrorCode.userTokenExpired.rawValue
    }

    private static func identityUser(
        _ auth: Auth,
        allowCreation: Bool
    ) async throws -> (User, Bool) {
        if let current = auth.currentUser { return (current, false) }
        guard allowCreation else {
            throw FeedbackFirebaseError.identityContinuity
        }
        do {
            return (try await auth.signInAnonymously().user, true)
        } catch {
            throw FeedbackFirebaseError.identity
        }
    }

    private static func validatedSubjectSHA256(
        _ user: User,
        expected: String?
    ) throws -> String {
        guard let subjectSHA256 = FeedbackIdentitySubject.sha256(user.uid) else {
            throw FeedbackFirebaseError.identity
        }
        guard expected == nil || expected == subjectSHA256 else {
            throw FeedbackFirebaseError.identityContinuity
        }
        return subjectSHA256
    }

    private static func runtime(bundle: Bundle = .main) throws -> Runtime {
        let values = try firebaseValues(bundle: bundle)
        let app: FirebaseApp
        if let existing = FirebaseApp.app(name: firebaseAppName) {
            guard existing.options.projectID == values.projectID,
                  existing.options.googleAppID == values.googleAppID else {
                throw FeedbackFirebaseError.configuration
            }
            app = existing
        } else {
            if FirebaseApp.app() == nil {
                #if DEBUG
                AppCheck.setAppCheckProviderFactory(
                    AppCheckDebugProviderFactory()
                )
                #elseif targetEnvironment(simulator)
                AppCheck.setAppCheckProviderFactory(
                    AppCheckDebugProviderFactory()
                )
                #else
                AppCheck.setAppCheckProviderFactory(
                    AppAttestProviderFactory()
                )
                #endif
            }
            let options = FirebaseOptions(
                googleAppID: values.googleAppID,
                gcmSenderID: values.senderID
            )
            options.apiKey = values.apiKey
            options.projectID = values.projectID
            options.bundleID = Bundle.main.bundleIdentifier ?? options.bundleID
            FirebaseApp.configure(name: firebaseAppName, options: options)
            guard let configured = FirebaseApp.app(name: firebaseAppName) else {
                throw FeedbackFirebaseError.configuration
            }
            app = configured
        }
        guard let appCheck = AppCheck.appCheck(app: app) else {
            throw FeedbackFirebaseError.configuration
        }
        return Runtime(
            auth: Auth.auth(app: app),
            appCheck: appCheck
        )
    }

    private static func firebaseValues(bundle: Bundle) throws -> FirebaseValues {
        func value(_ key: String) throws -> String {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
                throw FeedbackFirebaseError.configuration
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.contains("$(") else {
                throw FeedbackFirebaseError.configuration
            }
            return value
        }
        return try FirebaseValues(
            projectID: value("NOOPManagedProjectID"),
            apiKey: value("NOOPManagedAPIKey"),
            googleAppID: value("NOOPManagedGoogleAppID"),
            senderID: value("NOOPManagedGCMSenderID")
        )
    }

    private static let firebaseAppName = "noop-feedback"
    private static let identityGate = FeedbackIdentityAuthorizationGate()
}

private enum FeedbackFailureScheduling {
    case normal
    case identityContinuityWait
    case reservationContinuityWait
}

private struct FeedbackTransportFailure: Error {
    let kind: FeedbackFailureKind
    let retryable: Bool
    let statusCode: Int?
    let scheduling: FeedbackFailureScheduling
    let retryAfter: TimeInterval?

    init(
        kind: FeedbackFailureKind,
        retryable: Bool,
        statusCode: Int? = nil,
        scheduling: FeedbackFailureScheduling = .normal,
        retryAfter: TimeInterval? = nil
    ) {
        self.kind = kind
        self.retryable = retryable
        self.statusCode = statusCode
        self.scheduling = scheduling
        self.retryAfter = retryAfter
    }
}

private struct FeedbackPreparedAuthorization {
    let record: FeedbackOutboxRecord
    let authorization: FeedbackFirebaseAuthorization
}

private struct FeedbackReservationRequest: Encodable {
    let schemaVersion: Int
    let platform: String
    let appVersion: String
    let archiveBytes: Int64
    let archiveSHA256: String
    let includesUserNote: Bool
    let includesScreenshot: Bool

    enum CodingKeys: String, CodingKey {
        case platform
        case schemaVersion = "schema_version"
        case appVersion = "app_version"
        case archiveBytes = "archive_bytes"
        case archiveSHA256 = "archive_sha256"
        case includesUserNote = "includes_user_note"
        case includesScreenshot = "includes_screenshot"
    }
}

private struct FeedbackUploadWire: Decodable {
    let method: String
    let url: String
    let headers: [String: String]
    let expiresAt: String
}

private struct FeedbackReservationResponse: Decodable {
    let reportID: String
    let reportToken: String
    let status: FeedbackServerStatus
    let upload: FeedbackUploadWire?
    let retainedUntil: String
}

private struct FeedbackCompletionResponse: Decodable {
    let status: FeedbackServerStatus
    let receipt: String?
    let retainedUntil: String
}

private struct FeedbackStatusResponse: Decodable {
    let status: FeedbackServerStatus
    let receipt: String?
    let retainedUntil: String
}

private final class FeedbackNoRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        _ = response
        _ = request
        completionHandler(nil)
    }
}

private final class FeedbackBackgroundSessionDelegate:
    NSObject,
    URLSessionTaskDelegate,
    URLSessionDelegate,
    @unchecked Sendable {
    static let shared = FeedbackBackgroundSessionDelegate()
    private let pendingCompletions = DispatchGroup()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        _ = session
        _ = bytesSent
        Task {
            await FeedbackUploadCoordinator.shared.handleUploadProgress(
                taskDescription: task.taskDescription,
                sent: totalBytesSent,
                expected: totalBytesExpectedToSend
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        _ = session
        pendingCompletions.enter()
        Task {
            await FeedbackUploadCoordinator.shared.handleUploadCompletion(
                taskDescription: task.taskDescription,
                statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                failed: error != nil
            )
            self.pendingCompletions.leave()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        _ = response
        _ = request
        completionHandler(nil)
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        _ = session
        pendingCompletions.notify(queue: .main) {
            Task {
                await FeedbackUploadCoordinator.shared
                    .finishBackgroundSessionEvents()
            }
        }
    }
}

actor FeedbackUploadCoordinator {
    static let shared = FeedbackUploadCoordinator()

    nonisolated static var backgroundSessionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.noopapp.noop")
            + ".feedback-upload.v1"
    }

    private let outbox: FeedbackOutbox
    private let apiDelegate: FeedbackNoRedirectDelegate
    private let apiSession: URLSession
    private let backgroundSession: URLSession
    private var startupRecoveryGate = FeedbackStartupRecoveryGate()
    private var pumpGate = FeedbackPumpGate()
    private var activeUploadAttempts: [UUID: UUID] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var backgroundCompletionGate = FeedbackBackgroundCompletionGate()

    init(outbox: FeedbackOutbox = .shared) {
        self.outbox = outbox

        let apiDelegate = FeedbackNoRedirectDelegate()
        self.apiDelegate = apiDelegate
        let apiConfiguration = URLSessionConfiguration.ephemeral
        apiConfiguration.urlCache = nil
        apiConfiguration.httpCookieStorage = nil
        apiConfiguration.urlCredentialStorage = nil
        apiConfiguration.requestCachePolicy =
            .reloadIgnoringLocalAndRemoteCacheData
        apiConfiguration.timeoutIntervalForRequest = 20
        apiConfiguration.timeoutIntervalForResource = 30
        apiConfiguration.waitsForConnectivity = false
        self.apiSession = URLSession(
            configuration: apiConfiguration,
            delegate: apiDelegate,
            delegateQueue: nil
        )

        let uploadConfiguration = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        uploadConfiguration.sessionSendsLaunchEvents = true
        uploadConfiguration.isDiscretionary = false
        uploadConfiguration.waitsForConnectivity = true
        uploadConfiguration.allowsCellularAccess = true
        uploadConfiguration.httpMaximumConnectionsPerHost = 1
        uploadConfiguration.timeoutIntervalForResource = 24 * 60 * 60
        uploadConfiguration.urlCache = nil
        uploadConfiguration.httpCookieStorage = nil
        uploadConfiguration.urlCredentialStorage = nil
        self.backgroundSession = URLSession(
            configuration: uploadConfiguration,
            delegate: FeedbackBackgroundSessionDelegate.shared,
            delegateQueue: nil
        )
    }

    func start() async {
        guard startupRecoveryGate.requestStart() else { return }

        #if DEBUG
        if Self.holdsDemoReportsQueued {
            startupRecoveryGate.complete()
            try? await outbox.removeAllForUITesting()
            notifyChange()
            return
        }
        #endif

        var recoveredRecords: [FeedbackOutboxRecord]?
        while recoveredRecords == nil {
            do {
                recoveredRecords = try await outbox.recover()
                startupRecoveryGate.complete()
            } catch {
                let retryImmediately = startupRecoveryGate.recoveryFailed()
                FeedbackDiagnostics.record(
                    state: .retryScheduled,
                    outcome: .deferred,
                    failureKind: .interrupted
                )
                guard retryImmediately,
                      startupRecoveryGate.requestStart() else {
                    return
                }
            }
        }
        guard let records = recoveredRecords else { return }

        let tasks = await allBackgroundTasks()
        let recordsByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, $0) }
        )
        var activeTaskContexts = Set<FeedbackUploadTaskContext>()
        for task in tasks {
            guard let context = FeedbackUploadTaskContext(
                taskDescription: task.taskDescription
            ),
            task is URLSessionUploadTask,
            let record = recordsByID[context.reportID],
            record.uploadAttemptID == context.attemptID else {
                task.cancel()
                continue
            }
            guard FeedbackUploadStartPolicy.permitsResume(record) else {
                task.cancel()
                continue
            }
            guard activeUploadAttempts[context.reportID] == nil else {
                task.cancel()
                continue
            }
            switch task.state {
            case .running:
                break
            case .suspended:
                task.resume()
            case .canceling, .completed:
                task.cancel()
                continue
            @unknown default:
                task.cancel()
                continue
            }
            activeTaskContexts.insert(context)
            activeUploadAttempts[context.reportID] = context.attemptID
        }

        notifyChange()
        for recoveredRecord in records {
            guard let record = try? await outbox.record(
                id: recoveredRecord.id
            ) else {
                continue
            }
            if !FeedbackIdentityContinuityPolicy.canContactRemote(record) {
                switch record.state {
                case .sent, .cancelled, .failed:
                    continue
                default:
                    if record.cancelRequested || record.state == .cancelling {
                        await scheduleCancellationFailure(
                            id: record.id,
                            failure: FeedbackTransportFailure(
                                kind: .identity,
                                retryable: false
                            )
                        )
                    } else {
                        await scheduleFailure(
                            id: record.id,
                            failure: FeedbackTransportFailure(
                                kind: .identity,
                                retryable: false
                            )
                        )
                    }
                    continue
                }
            }
            if record.state == .uploading,
               let attemptID = record.uploadAttemptID,
               activeTaskContexts.contains(
                   FeedbackUploadTaskContext(
                       reportID: record.id,
                       attemptID: attemptID
                   )
               ) {
                continue
            }
            if record.state == .uploading {
                guard await beginAutomaticAttempt(id: record.id) else {
                    continue
                }
                do {
                    _ = try await outbox.markCompleting(
                        id: record.id,
                        uploadAttemptID: record.uploadAttemptID
                    )
                    notifyChange()
                    await complete(
                        id: record.id,
                        missingUploadFallsBack: true
                    )
                } catch {
                    await scheduleCompletionFailure(
                        id: record.id,
                        failure: FeedbackTransportFailure(
                            kind: .interrupted,
                            retryable: true
                        )
                    )
                }
                continue
            }
            let now = Date()
            if shouldPump(record, now: now) {
                Task { await self.pump(id: record.id) }
            } else if FeedbackRetryWakePolicy.shouldWait(record, now: now),
                      let nextRetryAt = record.nextRetryAt {
                scheduleRetryWake(id: record.id, at: nextRetryAt)
            }
        }
    }

    func enqueue(
        entries: [FileExport.BundleEntry],
        appVersion: String
    ) async throws -> FeedbackOutboxRecord {
        await start()
        let record = try await outbox.enqueue(
            entries: entries,
            appVersion: appVersion
        )
        FeedbackDiagnostics.record(
            state: .queued,
            outcome: .completed
        )
        notifyChange()

        #if DEBUG
        if Self.holdsDemoReportsQueued {
            return record
        }
        #endif

        Task { await self.pump(id: record.id) }
        return record
    }

    func record(id: UUID) async -> FeedbackOutboxRecord? {
        try? await outbox.record(id: id)
    }

    func retry(id: UUID) async {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        do {
            _ = try await outbox.prepareManualRetry(id: id)
            await cancelBackgroundUploadTasks(for: id)
            FeedbackDiagnostics.record(
                state: .queued,
                outcome: .completed
            )
            notifyChange()
            await pump(id: id)
        } catch {
            FeedbackDiagnostics.record(
                state: .failed,
                outcome: .failed,
                failureKind: .archiveIntegrity
            )
        }
    }

    func cancel(id: UUID) async {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        do {
            _ = try await outbox.requestCancellation(id: id)
            FeedbackDiagnostics.record(
                state: .cancelling,
                outcome: .completed
            )
            notifyChange()
            await cancelBackgroundUploadTasks(for: id)
            await pump(id: id)
        } catch {
            FeedbackDiagnostics.record(
                state: .failed,
                outcome: .failed,
                failureKind: .cancellationUnavailable
            )
        }
    }

    @discardableResult
    func retryDueReports() async -> Bool {
        await start()
        #if DEBUG
        if Self.holdsDemoReportsQueued { return true }
        #endif
        guard let records = try? await outbox.records() else { return false }
        let now = Date()
        for record in records where shouldPump(record, now: now) {
            Task { await self.pump(id: record.id) }
        }
        return true
    }

    func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.backgroundSessionIdentifier else {
            Task { @MainActor in completionHandler() }
            return
        }
        if let ready = backgroundCompletionGate.install(completionHandler) {
            Task { @MainActor in ready() }
        }
        Task { await self.start() }
    }

    func finishBackgroundSessionEvents() {
        guard let completionHandler =
                backgroundCompletionGate.finishEvents() else {
            return
        }
        Task { @MainActor in completionHandler() }
    }

    func handleUploadProgress(
        taskDescription: String?,
        sent: Int64,
        expected: Int64
    ) async {
        guard let context = FeedbackUploadTaskContext(
            taskDescription: taskDescription
        ),
        expected > 0,
        let current = try? await outbox.record(id: context.reportID),
        current.state == .uploading,
        current.uploadAttemptID == context.attemptID else {
            return
        }
        do {
            let updated = try await outbox.updateProgress(
                id: context.reportID,
                attemptID: context.attemptID,
                fraction: Double(sent) / Double(expected)
            )
            if updated != current {
                notifyChange()
            }
        } catch {
            return
        }
    }

    func handleUploadCompletion(
        taskDescription: String?,
        statusCode: Int?,
        failed: Bool
    ) async {
        guard let context = FeedbackUploadTaskContext(
            taskDescription: taskDescription
        ) else {
            return
        }
        if activeUploadAttempts[context.reportID] == context.attemptID {
            activeUploadAttempts.removeValue(forKey: context.reportID)
        }
        guard let record = try? await outbox.record(id: context.reportID),
        record.state == .uploading,
        record.uploadAttemptID == context.attemptID else {
            return
        }
        let id = context.reportID
        if record.cancelRequested {
            await pump(id: id)
            return
        }
        if statusCode == 412 {
            do {
                _ = try await outbox.markCompleting(
                    id: id,
                    uploadAttemptID: context.attemptID
                )
                notifyChange()
                await complete(id: id, missingUploadFallsBack: false)
            } catch {
                await scheduleCompletionFailure(
                    id: id,
                    failure: FeedbackTransportFailure(
                        kind: .completionUnavailable,
                        retryable: true,
                        statusCode: statusCode
                    )
                )
            }
            return
        }
        guard !failed,
              let statusCode,
              (200...299).contains(statusCode) else {
            let failureKind: FeedbackFailureKind =
                statusCode == 401 || statusCode == 403
                    ? .capabilityExpired
                    : statusCode.map({ (400...499).contains($0) }) == true
                    ? .uploadRejected
                    : .uploadUnavailable
            await scheduleFailure(
                id: id,
                failure: FeedbackTransportFailure(
                    kind: failureKind,
                    retryable: failureKind != .uploadRejected
                )
            )
            return
        }

        do {
            _ = try await outbox.markCompleting(
                id: id,
                uploadAttemptID: context.attemptID
            )
            FeedbackDiagnostics.record(
                state: .completing,
                outcome: .completed
            )
            notifyChange()
            await complete(id: id, missingUploadFallsBack: false)
        } catch {
            await scheduleFailure(
                id: id,
                failure: FeedbackTransportFailure(
                    kind: .completionUnavailable,
                    retryable: true
                )
            )
        }
    }

    private func pump(id: UUID) async {
        guard pumpGate.begin(id) else { return }
        defer {
            if pumpGate.finish(id) {
                Task { await self.pump(id: id) }
            }
        }
        guard let record = try? await outbox.record(id: id) else { return }

        if !FeedbackIdentityContinuityPolicy.canContactRemote(record) {
            switch record.state {
            case .sent, .cancelled, .failed:
                return
            default:
                if record.cancelRequested || record.state == .cancelling {
                    await scheduleCancellationFailure(
                        id: id,
                        failure: FeedbackTransportFailure(
                            kind: .identity,
                            retryable: false
                        )
                    )
                } else {
                    await scheduleFailure(
                        id: id,
                        failure: FeedbackTransportFailure(
                            kind: .identity,
                            retryable: false
                        )
                    )
                }
                return
            }
        }

        if record.cancelRequested || record.state == .cancelling {
            let now = Date()
            if FeedbackRetryWakePolicy.shouldWait(record, now: now),
               let nextRetryAt = record.nextRetryAt {
                scheduleRetryWake(id: id, at: nextRetryAt)
                return
            }
            guard await beginCancellationAttempt(id: id) else { return }
            await cancelRemote(record)
            return
        }
        switch record.state {
        case .sent, .cancelled, .failed, .uploading:
            return
        case .retryScheduled:
            let now = Date()
            if FeedbackRetryWakePolicy.shouldWait(record, now: now),
               let nextRetryAt = record.nextRetryAt {
                scheduleRetryWake(id: id, at: nextRetryAt)
                return
            }
        case .completing:
            let now = Date()
            if FeedbackRetryWakePolicy.shouldWait(record, now: now),
               let nextRetryAt = record.nextRetryAt {
                scheduleRetryWake(id: id, at: nextRetryAt)
                return
            }
            guard await beginAutomaticAttempt(id: id) else { return }
            await complete(id: id, missingUploadFallsBack: false)
            return
        case .queued, .reserving:
            break
        case .cancelling:
            return
        }

        guard await beginAutomaticAttempt(id: id) else { return }
        do {
            _ = try await outbox.verifiedArchiveURL(id: id)
        } catch {
            _ = try? await outbox.markFailed(
                id: id,
                failureKind: .archiveIntegrity
            )
            FeedbackDiagnostics.record(
                state: .failed,
                outcome: .failed,
                failureKind: .archiveIntegrity
            )
            notifyChange()
            return
        }

        if record.reportID == nil || record.reportToken == nil {
            await reserve(id: id)
            return
        }
        await recoverRemoteStatus(record)
    }

    private func reserve(
        id: UUID,
        forCancellation: Bool = false
    ) async {
        do {
            let reserving = try await outbox.markReserving(id: id)
            FeedbackDiagnostics.record(
                state: reserving.cancelRequested ? .cancelling : .reserving,
                outcome: .completed
            )
            notifyChange()

            let configuration = try FeedbackAPIConfiguration.load()
            guard FeedbackProtocolValidation.validAppVersion(
                reserving.appVersion
            ) else {
                throw FeedbackTransportFailure(
                    kind: .configuration,
                    retryable: false
                )
            }
            let prepared = try await prepareReservationAuthorization(
                for: reserving
            )
            let record = prepared.record
            guard let identitySubjectSHA256 = record.identitySubjectSHA256 else {
                throw FeedbackTransportFailure(
                    kind: .identity,
                    retryable: false
                )
            }
            if !forCancellation,
               let latest = try await outbox.record(id: id),
               FeedbackCompletionRacePolicy.action(for: latest)
                == .cancelRemote {
                await cancelRemote(latest)
                return
            }
            if forCancellation
                || !FeedbackReservationContinuityPolicy.permitsNewReservation(
                    record,
                    now: Date()
                ) {
                let recovered = try await recoverReservationReference(
                    configuration: configuration,
                    record: record,
                    authorization: prepared.authorization,
                    identitySubjectSHA256: identitySubjectSHA256
                )
                guard let recovered else {
                    _ = try await outbox.markCancelled(id: id)
                    FeedbackDiagnostics.record(
                        state: .cancelled,
                        outcome: .completed
                    )
                    notifyChange()
                    return
                }
                let stored = try await storeRecoveredReservation(
                    recovered,
                    id: id
                )
                let cancelling = stored.cancelRequested
                    ? stored
                    : try await outbox.requestCancellation(id: id)
                notifyChange()
                await cancelRemote(cancelling)
                return
            }
            let body = FeedbackReservationRequest(
                schemaVersion: 1,
                platform: "ios",
                appVersion: record.appVersion,
                archiveBytes: record.archiveBytes,
                archiveSHA256: record.archiveSHA256,
                includesUserNote: record.includesUserNote,
                includesScreenshot: record.includesScreenshot
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let responseData = try await apiRequest(
                configuration: configuration,
                path: "v1/feedback/reports/reservations",
                method: "POST",
                body: try encoder.encode(body),
                idempotencyKey: record.idempotencyKey,
                reportToken: nil,
                authorization: prepared.authorization,
                expectedIdentitySubjectSHA256: identitySubjectSHA256
            )
            let response = try decode(
                FeedbackReservationResponse.self,
                from: responseData
            )
            guard let reportID =
                    FeedbackProtocolValidation.canonicalReportID(
                        response.reportID
                    ),
                  FeedbackProtocolValidation.validReportToken(
                      response.reportToken
                  ),
                  let retainedUntil = feedbackDate(response.retainedUntil) else {
                throw FeedbackTransportFailure(
                    kind: .invalidResponse,
                    retryable: false
                )
            }
            let responseNow = Date()
            if !FeedbackReservationContinuityPolicy.serverRetentionIsValid(
                retainedUntil,
                for: record,
                now: responseNow
            ) {
                let latest = try await outbox.record(id: id) ?? record
                let cancelling = latest.cancelRequested
                    ? latest
                    : try await outbox.requestCancellation(
                        id: id,
                        now: responseNow
                    )
                let stored = try await outbox.storeReservation(
                    id: id,
                    reportID: reportID,
                    reportToken: response.reportToken,
                    upload: nil,
                    retainedUntil: FeedbackReservationContinuityPolicy
                        .boundedServerRetainedUntil(
                            retainedUntil,
                            for: record,
                            now: responseNow
                        ),
                    now: responseNow
                )
                notifyChange()
                await cancelRemote(
                    stored.cancelRequested ? stored : cancelling
                )
                return
            }
            switch response.status {
            case .reserved:
                guard let upload = response.upload,
                      let expiresAt = feedbackDate(upload.expiresAt) else {
                    throw FeedbackTransportFailure(
                        kind: .invalidResponse,
                        retryable: false
                    )
                }
                let capability = try configuration.validateSignedUpload(
                    method: upload.method,
                    url: upload.url,
                    headers: upload.headers,
                    archiveBytes: record.archiveBytes,
                    archiveSHA256: record.archiveSHA256,
                    expiresAt: expiresAt
                )
                let stored = try await outbox.storeReservation(
                    id: id,
                    reportID: reportID,
                    reportToken: response.reportToken,
                    upload: capability,
                    retainedUntil: retainedUntil
                )
                notifyChange()
                if stored.cancelRequested {
                    await cancelRemote(stored)
                    return
                }
                await startUpload(record: stored, capability: capability)
            case .sent, .rejected, .deleting, .deleted:
                guard response.upload == nil else {
                    throw FeedbackTransportFailure(
                        kind: .invalidResponse,
                        retryable: false
                    )
                }
                let stored = try await outbox.storeReservation(
                    id: id,
                    reportID: reportID,
                    reportToken: response.reportToken,
                    upload: nil,
                    retainedUntil: retainedUntil
                )
                notifyChange()
                if stored.cancelRequested {
                    await cancelRemote(stored)
                } else {
                    await recoverRemoteStatus(stored)
                }
            }
        } catch {
            let failure = classify(
                error,
                rejected: .reservationRejected,
                unavailable: .reservationUnavailable
            )
            if forCancellation {
                await scheduleCancellationFailure(
                    id: id,
                    failure: FeedbackTransportFailure(
                        kind: .cancellationUnavailable,
                        retryable: failure.retryable,
                        statusCode: failure.statusCode,
                        scheduling: failure.scheduling,
                        retryAfter: failure.retryAfter
                    )
                )
            } else {
                await scheduleFailure(id: id, failure: failure)
            }
        }
    }

    private func recoverReservationReference(
        configuration: FeedbackAPIConfiguration,
        record: FeedbackOutboxRecord,
        authorization: FeedbackFirebaseAuthorization,
        identitySubjectSHA256: String
    ) async throws -> FeedbackReservationResponse? {
        let responseData: Data
        do {
            responseData = try await apiRequest(
                configuration: configuration,
                path:
                    "v1/feedback/reports/reservations/"
                    + record.idempotencyKey,
                method: "GET",
                body: nil,
                idempotencyKey: nil,
                reportToken: nil,
                authorization: authorization,
                expectedIdentitySubjectSHA256: identitySubjectSHA256,
                acceptedStatusCodes:
                    FeedbackReservationRecoveryHTTPPolicy.acceptedStatusCodes,
                emptyBodyStatusCodes:
                    FeedbackReservationRecoveryHTTPPolicy.terminalStatusCodes,
                retryableStatusCodes:
                    FeedbackReservationRecoveryHTTPPolicy.pendingStatusCodes
            )
        } catch let failure as FeedbackTransportFailure
            where failure.statusCode.map({
                FeedbackReservationRecoveryHTTPPolicy.pendingStatusCodes
                    .contains($0)
            }) == true {
            throw FeedbackTransportFailure(
                kind: failure.kind,
                retryable: true,
                statusCode: failure.statusCode,
                scheduling: .reservationContinuityWait,
                retryAfter: failure.retryAfter
            )
        }
        guard !responseData.isEmpty else { return nil }
        let response = try decode(
            FeedbackReservationResponse.self,
            from: responseData
        )
        guard response.upload == nil else {
            throw FeedbackTransportFailure(
                kind: .invalidResponse,
                retryable: false
            )
        }
        return response
    }

    private func storeRecoveredReservation(
        _ response: FeedbackReservationResponse,
        id: UUID
    ) async throws -> FeedbackOutboxRecord {
        guard let current = try await outbox.record(id: id),
              let reportID =
                FeedbackProtocolValidation.canonicalReportID(
                    response.reportID
                ),
              FeedbackProtocolValidation.validReportToken(
                  response.reportToken
              ),
              let retainedUntil = feedbackDate(response.retainedUntil) else {
            throw FeedbackTransportFailure(
                kind: .invalidResponse,
                retryable: false
            )
        }
        let stored = try await outbox.storeReservation(
            id: id,
            reportID: reportID,
            reportToken: response.reportToken,
            upload: nil,
            retainedUntil: FeedbackReservationContinuityPolicy
                .boundedServerRetainedUntil(
                    retainedUntil,
                    for: current,
                    now: Date()
                )
        )
        notifyChange()
        return stored
    }

    private func startUpload(
        record: FeedbackOutboxRecord,
        capability: FeedbackUploadCapability
    ) async {
        guard activeUploadAttempts[record.id] == nil else { return }
        var startedContext: FeedbackUploadTaskContext?
        do {
            guard let current = try await outbox.record(id: record.id) else {
                return
            }
            if current.cancelRequested || current.state == .cancelling {
                await cancelRemote(current)
                return
            }
            let configuration = try FeedbackAPIConfiguration.load()
            guard capability.expiresAt.timeIntervalSinceNow > 15 else {
                throw FeedbackTransportFailure(
                    kind: .capabilityExpired,
                    retryable: true
                )
            }
            let validatedCapability = try configuration.validateSignedUpload(
                method: capability.method,
                url: capability.url,
                headers: capability.headers,
                archiveBytes: current.archiveBytes,
                archiveSHA256: current.archiveSHA256,
                expiresAt: capability.expiresAt
            )
            guard let url = URL(string: validatedCapability.url) else {
                throw FeedbackTransportFailure(
                    kind: .invalidResponse,
                    retryable: false
                )
            }
            let archiveURL = try await outbox.verifiedArchiveURL(id: current.id)
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
            )
            request.httpMethod = validatedCapability.method
            request.allHTTPHeaderFields = validatedCapability.headers
            let uploading = try await outbox.markUploading(id: current.id)
            guard let attemptID = uploading.uploadAttemptID else {
                throw FeedbackTransportFailure(
                    kind: .interrupted,
                    retryable: true
                )
            }
            let context = FeedbackUploadTaskContext(
                reportID: current.id,
                attemptID: attemptID
            )
            startedContext = context
            guard let latest = try await outbox.record(id: current.id) else {
                return
            }
            guard latest.uploadAttemptID == attemptID,
                  FeedbackUploadStartPolicy.permitsResume(latest) else {
                if latest.cancelRequested || latest.state == .cancelling {
                    await cancelRemote(latest)
                }
                return
            }
            let task = backgroundSession.uploadTask(
                with: request,
                fromFile: archiveURL
            )
            task.taskDescription = context.taskDescription
            activeUploadAttempts[current.id] = attemptID
            FeedbackDiagnostics.record(
                state: .uploading,
                outcome: .completed
            )
            notifyChange()
            task.resume()
        } catch {
            if let startedContext,
               activeUploadAttempts[startedContext.reportID]
                == startedContext.attemptID {
                activeUploadAttempts.removeValue(
                    forKey: startedContext.reportID
                )
            }
            await scheduleFailure(
                id: record.id,
                failure: classify(
                    error,
                    rejected: .uploadRejected,
                    unavailable: .uploadUnavailable
                )
            )
        }
    }

    private func complete(
        id: UUID,
        missingUploadFallsBack: Bool
    ) async {
        do {
            guard let record = try await outbox.record(id: id),
                  let rawReportID = record.reportID,
                  let reportID =
                    FeedbackProtocolValidation.canonicalReportID(rawReportID),
                  let reportToken = record.reportToken else {
                throw FeedbackTransportFailure(
                    kind: .invalidResponse,
                    retryable: false
                )
            }
            let configuration = try FeedbackAPIConfiguration.load()
            let authorization = try await prepareRemoteAuthorization(
                for: record
            )
            guard let identitySubjectSHA256 = record.identitySubjectSHA256 else {
                throw FeedbackTransportFailure(
                    kind: .identity,
                    retryable: false
                )
            }
            guard let current = try await outbox.record(id: id) else {
                return
            }
            if FeedbackCompletionRacePolicy.action(for: current)
                == .cancelRemote {
                await cancelRemote(current)
                return
            }
            let responseData = try await apiRequest(
                configuration: configuration,
                path: "v1/feedback/reports/\(reportID)/complete",
                method: "POST",
                body: Data("{}".utf8),
                idempotencyKey: nil,
                reportToken: reportToken,
                authorization: authorization,
                expectedIdentitySubjectSHA256: identitySubjectSHA256
            )
            let response = try decode(
                FeedbackCompletionResponse.self,
                from: responseData
            )
            guard response.status == .sent,
                  let receipt = response.receipt,
                  FeedbackProtocolValidation.validReceipt(receipt),
                  let retainedUntil = feedbackDate(response.retainedUntil) else {
                throw FeedbackTransportFailure(
                    kind: .invalidResponse,
                    retryable: false
                )
            }
            guard let latest = try await outbox.record(id: id) else {
                return
            }
            if !FeedbackReservationContinuityPolicy.serverRetentionIsValid(
                retainedUntil,
                for: latest,
                now: Date()
            ) {
                let cancelling = latest.cancelRequested
                    ? latest
                    : try await outbox.requestCancellation(id: id)
                notifyChange()
                await cancelRemote(cancelling)
                return
            }
            if FeedbackCompletionRacePolicy.action(for: latest)
                == .cancelRemote {
                await cancelRemote(latest)
                return
            }
            _ = try await outbox.markSent(
                id: id,
                receipt: receipt,
                retainedUntil: retainedUntil
            )
            FeedbackDiagnostics.record(
                state: .sent,
                outcome: .completed
            )
            notifyChange()
        } catch let failure as FeedbackTransportFailure
        where missingUploadFallsBack && failure.statusCode == 409 {
            await reserve(id: id)
        } catch {
            await scheduleCompletionFailure(
                id: id,
                failure: classify(
                    error,
                    rejected: .completionRejected,
                    unavailable: .completionUnavailable
                )
            )
        }
    }

    private func recoverRemoteStatus(_ record: FeedbackOutboxRecord) async {
        do {
            guard let rawReportID = record.reportID,
                  let reportID =
                    FeedbackProtocolValidation.canonicalReportID(rawReportID),
                  let reportToken = record.reportToken else {
                await reserve(id: record.id)
                return
            }
            let configuration = try FeedbackAPIConfiguration.load()
            let authorization = try await prepareRemoteAuthorization(
                for: record
            )
            guard let identitySubjectSHA256 = record.identitySubjectSHA256 else {
                throw FeedbackTransportFailure(
                    kind: .identity,
                    retryable: false
                )
            }
            let responseData = try await apiRequest(
                configuration: configuration,
                path: "v1/feedback/reports/\(reportID)",
                method: "GET",
                body: nil,
                idempotencyKey: nil,
                reportToken: reportToken,
                authorization: authorization,
                expectedIdentitySubjectSHA256: identitySubjectSHA256,
                acceptedStatusCodes: Set(200...299).union([404]),
                emptyBodyStatusCodes: [404]
            )
            guard let latest = try await outbox.record(id: record.id) else {
                return
            }
            if FeedbackCompletionRacePolicy.action(for: latest)
                == .cancelRemote {
                await cancelRemote(latest)
                return
            }
            guard !responseData.isEmpty else {
                switch FeedbackRemoteAbsencePolicy.statusAction(
                    for: latest,
                    authorizedIdentitySubjectSHA256:
                        authorization.identitySubjectSHA256
                ) {
                case .retryReservation:
                    await reserve(id: record.id)
                case .rejectIdentity, .confirmDeletion:
                    throw FeedbackTransportFailure(
                        kind: .identity,
                        retryable: false
                    )
                }
                return
            }
            let response = try decode(
                FeedbackStatusResponse.self,
                from: responseData
            )
            guard let retainedUntil = feedbackDate(response.retainedUntil) else {
                throw FeedbackTransportFailure(
                    kind: .invalidResponse,
                    retryable: false
                )
            }
            if !FeedbackReservationContinuityPolicy.serverRetentionIsValid(
                retainedUntil,
                for: record,
                now: Date()
            ) {
                let latest = try await outbox.record(id: record.id) ?? record
                let cancelling = latest.cancelRequested
                    ? latest
                    : try await outbox.requestCancellation(id: record.id)
                notifyChange()
                await cancelRemote(cancelling)
                return
            }
            switch response.status {
            case .sent:
                guard let receipt = response.receipt,
                      FeedbackProtocolValidation.validReceipt(receipt) else {
                    throw FeedbackTransportFailure(
                        kind: .invalidResponse,
                        retryable: true
                    )
                }
                guard let latest = try await outbox.record(id: record.id) else {
                    return
                }
                if FeedbackCompletionRacePolicy.action(for: latest)
                    == .cancelRemote {
                    await cancelRemote(latest)
                    return
                }
                _ = try await outbox.markSent(
                    id: record.id,
                    receipt: receipt,
                    retainedUntil: retainedUntil
                )
                FeedbackDiagnostics.record(
                    state: .sent,
                    outcome: .completed
                )
                notifyChange()
            case .deleted:
                _ = try await outbox.markCancelled(id: record.id)
                FeedbackDiagnostics.record(
                    state: .cancelled,
                    outcome: .completed
                )
                notifyChange()
            case .reserved:
                do {
                    _ = try await outbox.markCompleting(id: record.id)
                    notifyChange()
                    await complete(
                        id: record.id,
                        missingUploadFallsBack: true
                    )
                } catch {
                    await scheduleCompletionFailure(
                        id: record.id,
                        failure: FeedbackTransportFailure(
                            kind: .completionUnavailable,
                            retryable: true
                        )
                    )
                }
            case .rejected:
                do {
                    _ = try await outbox.markFailed(
                        id: record.id,
                        failureKind: .reportRejected,
                        unlessCancellationRequested: true
                    )
                } catch {
                    if let latest = try await outbox.record(id: record.id),
                       FeedbackCompletionRacePolicy.action(for: latest)
                        == .cancelRemote {
                        await cancelRemote(latest)
                        return
                    }
                    throw error
                }
                FeedbackDiagnostics.record(
                    state: .failed,
                    outcome: .rejected,
                    failureKind: .reportRejected
                )
                notifyChange()
            case .deleting:
                await scheduleCancellationPending(id: record.id)
            }
        } catch {
            await scheduleFailure(
                id: record.id,
                failure: classify(
                    error,
                    rejected: .statusUnavailable,
                    unavailable: .statusUnavailable
                )
            )
        }
    }

    private func cancelRemote(_ record: FeedbackOutboxRecord) async {
        guard let rawReportID = record.reportID,
              let reportID =
                FeedbackProtocolValidation.canonicalReportID(rawReportID),
              let reportToken = record.reportToken else {
            if record.attemptCount > 0 {
                await reserve(id: record.id, forCancellation: true)
                return
            }
            do {
                _ = try await outbox.markCancelled(id: record.id)
                FeedbackDiagnostics.record(
                    state: .cancelled,
                    outcome: .completed
                )
                notifyChange()
            } catch {
                await scheduleCancellationFailure(
                    id: record.id,
                    failure: FeedbackTransportFailure(
                        kind: .cancellationUnavailable,
                        retryable: true
                    )
                )
            }
            return
        }

        do {
            let configuration = try FeedbackAPIConfiguration.load()
            let authorization = try await prepareRemoteAuthorization(
                for: record
            )
            guard let identitySubjectSHA256 = record.identitySubjectSHA256 else {
                throw FeedbackTransportFailure(
                    kind: .identity,
                    retryable: false
                )
            }
            let responseData = try await apiRequest(
                configuration: configuration,
                path: "v1/feedback/reports/\(reportID)",
                method: "DELETE",
                body: nil,
                idempotencyKey: nil,
                reportToken: reportToken,
                authorization: authorization,
                expectedIdentitySubjectSHA256: identitySubjectSHA256,
                acceptedStatusCodes: Set(200...299).union([404]),
                emptyBodyStatusCodes: [404]
            )
            if responseData.isEmpty {
                switch FeedbackRemoteAbsencePolicy.cancellationAction(
                    for: record,
                    authorizedIdentitySubjectSHA256:
                        authorization.identitySubjectSHA256
                ) {
                case .confirmDeletion:
                    _ = try await outbox.markCancelled(id: record.id)
                    FeedbackDiagnostics.record(
                        state: .cancelled,
                        outcome: .completed
                    )
                    notifyChange()
                case .rejectIdentity, .retryReservation:
                    throw FeedbackTransportFailure(
                        kind: .identity,
                        retryable: false
                    )
                }
                return
            }
            let response = try decode(
                FeedbackStatusResponse.self,
                from: responseData
            )
            switch response.status {
            case .deleted:
                _ = try await outbox.markCancelled(id: record.id)
                FeedbackDiagnostics.record(
                    state: .cancelled,
                    outcome: .completed
                )
                notifyChange()
            case .deleting:
                await scheduleCancellationPending(id: record.id)
            case .reserved, .sent, .rejected:
                throw FeedbackTransportFailure(
                    kind: .invalidResponse,
                    retryable: true
                )
            }
        } catch {
            await scheduleCancellationFailure(
                id: record.id,
                failure: classify(
                    error,
                    rejected: .cancellationUnavailable,
                    unavailable: .cancellationUnavailable
                )
            )
        }
    }

    private func scheduleCancellationPending(id: UUID) async {
        guard let record = try? await outbox.record(id: id) else { return }
        let next = Date().addingTimeInterval(
            FeedbackRetryPolicy.delay(
                afterAttempt: record.cancellationAttempts
            )
        )
        do {
            _ = try await outbox.markCancellationPending(
                id: id,
                nextRetryAt: next
            )
            FeedbackDiagnostics.record(
                state: .cancelling,
                outcome: .deferred
            )
            notifyChange()
            scheduleRetryWake(id: id, at: next)
        } catch {
            await scheduleCancellationFailure(
                id: id,
                failure: FeedbackTransportFailure(
                    kind: .cancellationUnavailable,
                    retryable: true
                )
            )
        }
    }

    private func beginAutomaticAttempt(id: UUID) async -> Bool {
        guard let record = try? await outbox.record(id: id),
              record.attemptCount
                < FeedbackRetryPolicy.maximumAutomaticAttempts else {
            _ = try? await outbox.markFailed(
                id: id,
                failureKind: .retryLimit
            )
            FeedbackDiagnostics.record(
                state: .failed,
                outcome: .failed,
                failureKind: .retryLimit
            )
            notifyChange()
            return false
        }
        do {
            _ = try await outbox.beginAutomaticAttempt(id: id)
            return true
        } catch {
            FeedbackDiagnostics.record(
                state: .failed,
                outcome: .failed,
                failureKind: .interrupted
            )
            return false
        }
    }

    private func beginCancellationAttempt(id: UUID) async -> Bool {
        guard let record = try? await outbox.record(id: id),
              record.cancellationAttempts
                < FeedbackRetryPolicy.maximumAutomaticAttempts else {
            if let _ = try? await outbox.markFailed(
                id: id,
                failureKind: .retryLimit
            ) {}
            FeedbackDiagnostics.record(
                state: .failed,
                outcome: .failed,
                failureKind: .retryLimit
            )
            notifyChange()
            return false
        }
        do {
            _ = try await outbox.beginCancellationAttempt(id: id)
            return true
        } catch {
            FeedbackDiagnostics.record(
                state: .failed,
                outcome: .failed,
                failureKind: .interrupted
            )
            return false
        }
    }

    private func scheduleFailure(
        id: UUID,
        failure: FeedbackTransportFailure
    ) async {
        guard let record = try? await outbox.record(id: id),
              !record.state.isTerminal else { return }
        if failure.scheduling != .normal {
            do {
                let isReservationWait =
                    failure.scheduling == .reservationContinuityWait
                let waiting = try await outbox
                    .markReservationContinuityWaiting(
                        id: id,
                        lane: .delivery,
                        allowBoundIdentity: isReservationWait,
                        failureKind: failure.kind,
                        retryAfter: failure.retryAfter
                    )
                AppDiagnosticsRecorder.shared.record(
                    isReservationWait
                        ? "feedback.reservation_continuity_wait"
                        : "feedback.identity_continuity_wait",
                    fields: ["outcome": "deferred"]
                )
                FeedbackDiagnostics.record(
                    state: .retryScheduled,
                    outcome: .deferred,
                    failureKind: failure.kind
                )
                notifyChange()
                if waiting.cancelRequested {
                    await cancelRemote(waiting)
                    return
                }
                if let nextRetryAt = waiting.nextRetryAt {
                    scheduleRetryWake(id: id, at: nextRetryAt)
                }
                return
            } catch {
                // Continue through the normal durable failure path.
            }
        }
        if record.cancelRequested {
            await cancelRemote(record)
            return
        }
        if failure.retryable,
           record.attemptCount < FeedbackRetryPolicy.maximumAutomaticAttempts {
            let next = Date().addingTimeInterval(
                FeedbackRetryPolicy.delay(afterAttempt: record.attemptCount)
            )
            do {
                _ = try await outbox.markRetryScheduled(
                    id: id,
                    failureKind: failure.kind,
                    nextRetryAt: next
                )
                FeedbackDiagnostics.record(
                    state: .retryScheduled,
                    outcome: .deferred,
                    failureKind: failure.kind
                )
                notifyChange()
                scheduleRetryWake(id: id, at: next)
                return
            } catch {
                // Fall through to the durable failed state.
            }
        }

        let terminalKind: FeedbackFailureKind =
            failure.retryable ? .retryLimit : failure.kind
        if let _ = try? await outbox.markFailed(
            id: id,
            failureKind: terminalKind
        ) {}
        FeedbackDiagnostics.record(
            state: .failed,
            outcome: .failed,
            failureKind: terminalKind
        )
        notifyChange()
    }

    private func scheduleCompletionFailure(
        id: UUID,
        failure: FeedbackTransportFailure
    ) async {
        guard let record = try? await outbox.record(id: id),
              !record.state.isTerminal else { return }
        if record.cancelRequested {
            await cancelRemote(record)
            return
        }
        if failure.retryable,
           record.attemptCount < FeedbackRetryPolicy.maximumAutomaticAttempts {
            let next = Date().addingTimeInterval(
                FeedbackRetryPolicy.delay(afterAttempt: record.attemptCount)
            )
            do {
                _ = try await outbox.markCompletionRetryScheduled(
                    id: id,
                    failureKind: failure.kind,
                    nextRetryAt: next
                )
                FeedbackDiagnostics.record(
                    state: .completing,
                    outcome: .deferred,
                    failureKind: failure.kind
                )
                notifyChange()
                scheduleRetryWake(id: id, at: next)
                return
            } catch {
                // Fall through to a durable terminal failure.
            }
        }

        let terminalKind: FeedbackFailureKind =
            failure.retryable ? .retryLimit : failure.kind
        if let _ = try? await outbox.markFailed(
            id: id,
            failureKind: terminalKind
        ) {}
        FeedbackDiagnostics.record(
            state: .failed,
            outcome: .failed,
            failureKind: terminalKind
        )
        notifyChange()
    }

    private func scheduleCancellationFailure(
        id: UUID,
        failure: FeedbackTransportFailure
    ) async {
        guard let record = try? await outbox.record(id: id),
              record.cancelRequested else { return }
        if failure.scheduling != .normal {
            do {
                let isReservationWait =
                    failure.scheduling == .reservationContinuityWait
                let waiting = try await outbox
                    .markReservationContinuityWaiting(
                        id: id,
                        lane: .cancellation,
                        allowBoundIdentity: isReservationWait,
                        failureKind: failure.kind,
                        retryAfter: failure.retryAfter
                    )
                AppDiagnosticsRecorder.shared.record(
                    isReservationWait
                        ? "feedback.reservation_continuity_wait"
                        : "feedback.identity_continuity_wait",
                    fields: ["outcome": "deferred"]
                )
                FeedbackDiagnostics.record(
                    state: .cancelling,
                    outcome: .deferred,
                    failureKind: failure.kind
                )
                notifyChange()
                if let nextRetryAt = waiting.nextRetryAt {
                    scheduleRetryWake(id: id, at: nextRetryAt)
                }
                return
            } catch {
                // Continue through the normal durable cancellation path.
            }
        }
        if failure.retryable,
           record.cancellationAttempts
            < FeedbackRetryPolicy.maximumAutomaticAttempts {
            let next = Date().addingTimeInterval(
                FeedbackRetryPolicy.delay(
                    afterAttempt: record.cancellationAttempts
                )
            )
            do {
                _ = try await outbox.markRetryScheduled(
                    id: id,
                    failureKind: failure.kind,
                    nextRetryAt: next
                )
                FeedbackDiagnostics.record(
                    state: .retryScheduled,
                    outcome: .deferred,
                    failureKind: failure.kind
                )
                notifyChange()
                scheduleRetryWake(id: id, at: next)
                return
            } catch {
                // Fall through to a durable cleanup failure.
            }
        }

        let terminalKind: FeedbackFailureKind =
            failure.retryable ? .retryLimit : failure.kind
        if let _ = try? await outbox.markFailed(
            id: id,
            failureKind: terminalKind
        ) {}
        FeedbackDiagnostics.record(
            state: .failed,
            outcome: .failed,
            failureKind: terminalKind
        )
        notifyChange()
    }

    private func scheduleRetryWake(id: UUID, at date: Date) {
        retryTasks[id]?.cancel()
        Task { @MainActor in
            BackgroundSyncScheduler.requestWake(noLaterThan: date)
        }
        let delay = max(0, date.timeIntervalSinceNow)
        retryTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(delay)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.pump(id: id)
        }
    }

    private func prepareReservationAuthorization(
        for record: FeedbackOutboxRecord
    ) async throws -> FeedbackPreparedAuthorization {
        guard FeedbackIdentityContinuityPolicy.canContactRemote(record) else {
            throw FeedbackTransportFailure(
                kind: .identity,
                retryable: false
            )
        }
        let authorization = try await firebaseAuthorization(
            forceRefresh: false,
            allowIdentityReplacement:
                FeedbackIdentityContinuityPolicy
                    .permitsAnonymousIdentityReplacement(record),
            expectedIdentitySubjectSHA256: record.identitySubjectSHA256,
            enforceReservationIdentityLifetime:
                FeedbackReservationContinuityPolicy
                    .requiresIdentityLifetimeCheck(record),
            reservationContinuityIdentitySubjectSHA256s:
                try await outbox
                    .reservationContinuityIdentitySubjectSHA256s()
        )
        guard FeedbackIdentityContinuityPolicy.accepts(
            identitySubjectSHA256: authorization.identitySubjectSHA256,
            for: record
        ) else {
            throw FeedbackTransportFailure(
                kind: .identity,
                retryable: false
            )
        }

        let boundRecord: FeedbackOutboxRecord
        if record.identitySubjectSHA256 == nil {
            boundRecord = try await outbox.bindIdentity(
                id: record.id,
                identitySubjectSHA256: authorization.identitySubjectSHA256
            )
        } else {
            boundRecord = record
        }
        guard FeedbackIdentityContinuityPolicy.accepts(
            identitySubjectSHA256: authorization.identitySubjectSHA256,
            for: boundRecord
        ) else {
            throw FeedbackTransportFailure(
                kind: .identity,
                retryable: false
            )
        }
        return FeedbackPreparedAuthorization(
            record: boundRecord,
            authorization: authorization
        )
    }

    private func prepareRemoteAuthorization(
        for record: FeedbackOutboxRecord
    ) async throws -> FeedbackFirebaseAuthorization {
        guard FeedbackIdentityContinuityPolicy.canContactRemote(record),
              let expectedIdentitySubjectSHA256 =
                record.identitySubjectSHA256 else {
            throw FeedbackTransportFailure(
                kind: .identity,
                retryable: false
            )
        }
        let authorization = try await firebaseAuthorization(
            forceRefresh: false,
            allowIdentityReplacement: false,
            expectedIdentitySubjectSHA256: expectedIdentitySubjectSHA256,
            enforceReservationIdentityLifetime: false,
            reservationContinuityIdentitySubjectSHA256s: []
        )
        guard authorization.identitySubjectSHA256
                == expectedIdentitySubjectSHA256 else {
            throw FeedbackTransportFailure(
                kind: .identity,
                retryable: false
            )
        }
        return authorization
    }

    private func firebaseAuthorization(
        forceRefresh: Bool,
        allowIdentityReplacement: Bool,
        expectedIdentitySubjectSHA256: String?,
        enforceReservationIdentityLifetime: Bool = false,
        reservationContinuityIdentitySubjectSHA256s: Set<String> = []
    ) async throws -> FeedbackFirebaseAuthorization {
        do {
            return try await FeedbackFirebaseAuthorizationProvider.authorization(
                forceRefresh: forceRefresh,
                allowIdentityReplacement: allowIdentityReplacement,
                expectedIdentitySubjectSHA256:
                    expectedIdentitySubjectSHA256,
                enforceReservationIdentityLifetime:
                    enforceReservationIdentityLifetime,
                reservationContinuityIdentitySubjectSHA256s:
                    reservationContinuityIdentitySubjectSHA256s
            )
        } catch FeedbackFirebaseError.configuration {
            throw FeedbackTransportFailure(
                kind: .configuration,
                retryable: false
            )
        } catch FeedbackFirebaseError.identityContinuity {
            throw FeedbackTransportFailure(
                kind: .identity,
                retryable: false
            )
        } catch FeedbackFirebaseError.identityReservationDeferred {
            throw FeedbackTransportFailure(
                kind: .identity,
                retryable: true,
                scheduling: .identityContinuityWait
            )
        } catch FeedbackFirebaseError.identity {
            throw FeedbackTransportFailure(
                kind: .identity,
                retryable: true
            )
        } catch {
            throw FeedbackTransportFailure(
                kind: .appCheck,
                retryable: true
            )
        }
    }

    private func apiRequest(
        configuration: FeedbackAPIConfiguration,
        path: String,
        method: String,
        body: Data?,
        idempotencyKey: String?,
        reportToken: String?,
        authorization: FeedbackFirebaseAuthorization,
        expectedIdentitySubjectSHA256: String,
        acceptedStatusCodes: Set<Int> = Set(200...299),
        emptyBodyStatusCodes: Set<Int> = [],
        retryableStatusCodes: Set<Int> = [],
        refreshedAuthorization: Bool = false
    ) async throws -> Data {
        guard authorization.identitySubjectSHA256
                == expectedIdentitySubjectSHA256 else {
            throw FeedbackTransportFailure(
                kind: .identity,
                retryable: false
            )
        }

        var request = URLRequest(
            url: try configuration.endpoint(path),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = method
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            authorization.appCheckToken,
            forHTTPHeaderField: "X-Firebase-AppCheck"
        )
        request.setValue(
            "Bearer \(authorization.identityToken)",
            forHTTPHeaderField: "Authorization"
        )
        if let idempotencyKey {
            request.setValue(
                idempotencyKey,
                forHTTPHeaderField: "Idempotency-Key"
            )
        }
        if let reportToken {
            guard FeedbackProtocolValidation.validReportToken(reportToken) else {
                throw FeedbackTransportFailure(
                    kind: .invalidResponse,
                    retryable: false
                )
            }
            request.setValue(
                reportToken,
                forHTTPHeaderField: "X-NOOP-Feedback-Token"
            )
        }
        if let body {
            request.httpBody = body
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await apiSession.data(for: request)
        } catch {
            throw FeedbackTransportFailure(
                kind: .reservationUnavailable,
                retryable: true
            )
        }
        guard data.count <= 128 * 1024,
              let http = response as? HTTPURLResponse else {
            throw FeedbackTransportFailure(
                kind: .invalidResponse,
                retryable: false
            )
        }
        if (http.statusCode == 401 || http.statusCode == 403),
           !refreshedAuthorization {
            let refreshed = try await firebaseAuthorization(
                forceRefresh: true,
                allowIdentityReplacement: false,
                expectedIdentitySubjectSHA256:
                    expectedIdentitySubjectSHA256
            )
            return try await apiRequest(
                configuration: configuration,
                path: path,
                method: method,
                body: body,
                idempotencyKey: idempotencyKey,
                reportToken: reportToken,
                authorization: refreshed,
                expectedIdentitySubjectSHA256:
                    expectedIdentitySubjectSHA256,
                acceptedStatusCodes: acceptedStatusCodes,
                emptyBodyStatusCodes: emptyBodyStatusCodes,
                retryableStatusCodes: retryableStatusCodes,
                refreshedAuthorization: true
            )
        }
        if FeedbackReservationAdmissionPolicy.preservesAttemptBudget(
            statusCode: http.statusCode,
            deferral: http.value(
                forHTTPHeaderField:
                    FeedbackReservationAdmissionPolicy.deferralHeader
            )
        ) {
            throw FeedbackTransportFailure(
                kind: .reservationUnavailable,
                retryable: true,
                statusCode: http.statusCode,
                scheduling: .reservationContinuityWait,
                retryAfter: FeedbackReservationAdmissionPolicy.retryDelay(
                    http.value(
                        forHTTPHeaderField:
                            FeedbackReservationAdmissionPolicy.retryAfterHeader
                    )
                )
            )
        }
        guard acceptedStatusCodes.contains(http.statusCode) else {
            throw FeedbackTransportFailure(
                kind: (400...499).contains(http.statusCode)
                    ? .reservationRejected
                    : .reservationUnavailable,
                retryable: retryableStatusCodes.contains(http.statusCode)
                    || http.statusCode == 408
                    || http.statusCode == 429
                    || (500...599).contains(http.statusCode),
                statusCode: http.statusCode
            )
        }
        if emptyBodyStatusCodes.contains(http.statusCode) {
            return Data()
        }
        return data
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(type, from: data)
        } catch {
            throw FeedbackTransportFailure(
                kind: .invalidResponse,
                retryable: false
            )
        }
    }

    private func classify(
        _ error: Error,
        rejected: FeedbackFailureKind,
        unavailable: FeedbackFailureKind
    ) -> FeedbackTransportFailure {
        if let failure = error as? FeedbackTransportFailure {
            switch failure.kind {
            case .reservationRejected, .uploadRejected, .completionRejected:
                return FeedbackTransportFailure(
                    kind: rejected,
                    retryable: failure.retryable,
                    statusCode: failure.statusCode,
                    scheduling: failure.scheduling,
                    retryAfter: failure.retryAfter
                )
            case .reservationUnavailable, .uploadUnavailable,
                    .completionUnavailable:
                return FeedbackTransportFailure(
                    kind: unavailable,
                    retryable: failure.retryable,
                    statusCode: failure.statusCode,
                    scheduling: failure.scheduling,
                    retryAfter: failure.retryAfter
                )
            default:
                return failure
            }
        }
        if error is FeedbackFirebaseError {
            return FeedbackTransportFailure(
                kind: .configuration,
                retryable: false
            )
        }
        return FeedbackTransportFailure(
            kind: unavailable,
            retryable: true
        )
    }

    private func shouldPump(
        _ record: FeedbackOutboxRecord,
        now: Date
    ) -> Bool {
        if record.cancelRequested || record.state == .cancelling {
            return true
        }
        switch record.state {
        case .queued, .reserving:
            return true
        case .completing:
            return !FeedbackRetryWakePolicy.shouldWait(record, now: now)
        case .retryScheduled:
            return !FeedbackRetryWakePolicy.shouldWait(record, now: now)
        case .uploading, .sent, .failed, .cancelled, .cancelling:
            return false
        }
    }

    private func allBackgroundTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            backgroundSession.getAllTasks {
                continuation.resume(returning: $0)
            }
        }
    }

    private func cancelBackgroundUploadTasks(for id: UUID) async {
        activeUploadAttempts.removeValue(forKey: id)
        for task in await allBackgroundTasks() {
            let context = FeedbackUploadTaskContext(
                taskDescription: task.taskDescription
            )
            let legacyReportID = task.taskDescription.flatMap {
                UUID(uuidString: $0)
            }
            if context?.reportID == id || legacyReportID == id {
                task.cancel()
            }
        }
    }

    private func notifyChange() {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .feedbackOutboxDidChange,
                object: nil
            )
        }
    }

    private func feedbackDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    #if DEBUG
    private nonisolated static var holdsDemoReportsQueued: Bool {
        CommandLine.arguments.contains("--demo-feedback-hold-queued")
    }
    #endif
}
#endif
