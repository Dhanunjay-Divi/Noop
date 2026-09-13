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
        expectedIdentitySubjectSHA256: String?
    ) async throws -> FeedbackFirebaseAuthorization {
        let runtime = try runtime()
        let identity = try await identityAuthorization(
            runtime.auth,
            forceRefresh: forceRefresh,
            allowReplacement: allowIdentityReplacement,
            expectedSubjectSHA256: expectedIdentitySubjectSHA256
        )
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
        expectedSubjectSHA256: String?
    ) async throws -> IdentityAuthorization {
        let user = try await identityUser(
            auth,
            allowCreation: allowReplacement && expectedSubjectSHA256 == nil
        )
        let subjectSHA256 = try validatedSubjectSHA256(
            user,
            expected: expectedSubjectSHA256
        )
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
                  permitsAnonymousIdentityReplacement(after: error) else {
                throw FeedbackFirebaseError.identity
            }

            // Identity Platform can remove an inactive anonymous user. Replace only
            // an explicitly stale identity before a report has a server binding.
            do {
                try auth.signOut()
            } catch {
                throw FeedbackFirebaseError.identity
            }
            do {
                let replacement = try await auth.signInAnonymously().user
                let replacementSubjectSHA256 = try validatedSubjectSHA256(
                    replacement,
                    expected: nil
                )
                let token = try await replacement.getIDToken(forcingRefresh: true)
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
    ) async throws -> User {
        if let current = auth.currentUser { return current }
        guard allowCreation else {
            throw FeedbackFirebaseError.identityContinuity
        }
        do {
            return try await auth.signInAnonymously().user
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
}

private struct FeedbackTransportFailure: Error {
    let kind: FeedbackFailureKind
    let retryable: Bool
    let statusCode: Int?

    init(
        kind: FeedbackFailureKind,
        retryable: Bool,
        statusCode: Int? = nil
    ) {
        self.kind = kind
        self.retryable = retryable
        self.statusCode = statusCode
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
                localID: task.taskDescription,
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
                localID: task.taskDescription,
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
    private var started = false
    private var pumping = Set<UUID>()
    private var activeUploadIDs = Set<UUID>()
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
        guard !started else { return }
        started = true

        #if DEBUG
        if Self.holdsDemoReportsQueued {
            try? await outbox.removeAllForUITesting()
            notifyChange()
            return
        }
        #endif

        let records: [FeedbackOutboxRecord]
        do {
            records = try await outbox.recover()
        } catch {
            FeedbackDiagnostics.record(
                state: .failed,
                outcome: .failed,
                failureKind: .archiveIntegrity
            )
            return
        }

        let tasks = await allBackgroundTasks()
        let recordsByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, $0) }
        )
        var taskIDs = Set<UUID>()
        for task in tasks {
            guard let raw = task.taskDescription,
                  let id = UUID(uuidString: raw),
                  let record = recordsByID[id] else {
                task.cancel()
                continue
            }
            guard FeedbackUploadStartPolicy.permitsResume(record) else {
                task.cancel()
                continue
            }
            taskIDs.insert(id)
            activeUploadIDs.insert(id)
        }

        notifyChange()
        for record in records {
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
            if record.state == .uploading, taskIDs.contains(record.id) {
                continue
            }
            if record.state == .uploading {
                guard await beginAutomaticAttempt(id: record.id) else {
                    continue
                }
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
                            kind: .interrupted,
                            retryable: true
                        )
                    )
                }
                continue
            }
            if shouldPump(record, now: Date()) {
                Task { await self.pump(id: record.id) }
            } else if let nextRetryAt = record.nextRetryAt {
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
            for task in await allBackgroundTasks()
            where task.taskDescription == id.uuidString {
                task.cancel()
            }
            activeUploadIDs.remove(id)
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
        localID: String?,
        sent: Int64,
        expected: Int64
    ) async {
        guard let localID,
              let id = UUID(uuidString: localID),
              expected > 0 else { return }
        do {
            _ = try await outbox.updateProgress(
                id: id,
                fraction: Double(sent) / Double(expected)
            )
            notifyChange()
        } catch {
            return
        }
    }

    func handleUploadCompletion(
        localID: String?,
        statusCode: Int?,
        failed: Bool
    ) async {
        guard let localID,
              let id = UUID(uuidString: localID) else { return }
        activeUploadIDs.remove(id)
        guard let record = try? await outbox.record(id: id) else { return }
        if record.cancelRequested {
            await pump(id: id)
            return
        }
        if statusCode == 412 {
            do {
                _ = try await outbox.markCompleting(id: id)
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
            _ = try await outbox.markCompleting(id: id)
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
        guard pumping.insert(id).inserted else { return }
        defer { pumping.remove(id) }
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
            if let nextRetryAt = record.nextRetryAt, nextRetryAt > Date() {
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
            if let nextRetryAt = record.nextRetryAt, nextRetryAt > Date() {
                scheduleRetryWake(id: id, at: nextRetryAt)
                return
            }
        case .completing:
            if let nextRetryAt = record.nextRetryAt, nextRetryAt > Date() {
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
                        statusCode: failure.statusCode
                    )
                )
            } else {
                await scheduleFailure(id: id, failure: failure)
            }
        }
    }

    private func startUpload(
        record: FeedbackOutboxRecord,
        capability: FeedbackUploadCapability
    ) async {
        guard !activeUploadIDs.contains(record.id) else { return }
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
            _ = try await outbox.markUploading(id: current.id)
            guard let latest = try await outbox.record(id: current.id) else {
                return
            }
            guard FeedbackUploadStartPolicy.permitsResume(latest) else {
                await cancelRemote(latest)
                return
            }
            let task = backgroundSession.uploadTask(
                with: request,
                fromFile: archiveURL
            )
            task.taskDescription = current.id.uuidString
            activeUploadIDs.insert(current.id)
            FeedbackDiagnostics.record(
                state: .uploading,
                outcome: .completed
            )
            notifyChange()
            task.resume()
        } catch {
            activeUploadIDs.remove(record.id)
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
            guard !responseData.isEmpty else {
                switch FeedbackRemoteAbsencePolicy.statusAction(
                    for: record,
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
                _ = try await outbox.markFailed(
                    id: record.id,
                    failureKind: .reportRejected
                )
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
        guard let record = try? await outbox.record(id: id) else { return }
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
        guard let record = try? await outbox.record(id: id) else { return }
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
            expectedIdentitySubjectSHA256: record.identitySubjectSHA256
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
            expectedIdentitySubjectSHA256: expectedIdentitySubjectSHA256
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
        expectedIdentitySubjectSHA256: String?
    ) async throws -> FeedbackFirebaseAuthorization {
        do {
            return try await FeedbackFirebaseAuthorizationProvider.authorization(
                forceRefresh: forceRefresh,
                allowIdentityReplacement: allowIdentityReplacement,
                expectedIdentitySubjectSHA256:
                    expectedIdentitySubjectSHA256
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
                refreshedAuthorization: true
            )
        }
        guard acceptedStatusCodes.contains(http.statusCode) else {
            throw FeedbackTransportFailure(
                kind: (400...499).contains(http.statusCode)
                    ? .reservationRejected
                    : .reservationUnavailable,
                retryable: http.statusCode == 408
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
                    retryable: failure.retryable
                )
            case .reservationUnavailable, .uploadUnavailable,
                    .completionUnavailable:
                return FeedbackTransportFailure(
                    kind: unavailable,
                    retryable: failure.retryable
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
            return record.nextRetryAt.map { $0 <= now } ?? true
        case .retryScheduled:
            return record.nextRetryAt.map { $0 <= now } ?? true
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
