import Foundation
import Security
import NoopRemoteSync
import StrandAnalytics
import WhoopStore

/// Non-secret preferences for the optional self-hosted destination. Upload is OFF by default.
enum RemoteSyncPreferences {
    private static var defaults: UserDefaults { .standard }
    private static let endpointKey = "remoteSync.endpoint"
    private static let automaticKey = "remoteSync.automatic"
    private static let lastAttemptKey = "remoteSync.lastAttemptMs"
    private static let lastSuccessKey = "remoteSync.lastSuccessMs"
    private static let lastStatusKey = "remoteSync.lastStatus"
    private static let replayKey = "remoteSync.needsFullReplay"
    private static let replayInProgressKey = "remoteSync.replayInProgress"
    private static let replayWindowKey = "remoteSync.replayWindow"
    private static let backlogKey = "remoteSync.hasPendingBacklog"
    private static let optimizeStorageKey = "remoteSync.optimizeStorage"
    private static let installIdKey = "remoteSync.installationId"

    static var endpoint: String {
        get { defaults.string(forKey: endpointKey) ?? "" }
        set { defaults.set(newValue, forKey: endpointKey) }
    }
    static var automatic: Bool {
        get { defaults.bool(forKey: automaticKey) }
        set { defaults.set(newValue, forKey: automaticKey) }
    }
    static var lastAttemptMs: Int {
        get { defaults.integer(forKey: lastAttemptKey) }
        set { defaults.set(newValue, forKey: lastAttemptKey) }
    }
    static var lastSuccessMs: Int {
        get { defaults.integer(forKey: lastSuccessKey) }
        set { defaults.set(newValue, forKey: lastSuccessKey) }
    }
    static var lastStatus: String {
        get { defaults.string(forKey: lastStatusKey) ?? "" }
        set { defaults.set(newValue, forKey: lastStatusKey) }
    }
    static var needsFullReplay: Bool {
        get { defaults.bool(forKey: replayKey) }
        set { defaults.set(newValue, forKey: replayKey) }
    }
    static var replayInProgress: Bool {
        defaults.bool(forKey: replayInProgressKey)
    }
    static var replayWindow: RemoteDerivedWindow? {
        guard let data = defaults.data(forKey: replayWindowKey),
              let window = try? JSONDecoder().decode(RemoteDerivedWindow.self, from: data),
              window.isValid else { return nil }
        return window
    }
    static var hasPendingBacklog: Bool {
        get { defaults.bool(forKey: backlogKey) }
        set { defaults.set(newValue, forKey: backlogKey) }
    }
    static var optimizeStorage: Bool {
        get { defaults.bool(forKey: optimizeStorageKey) }
        set { defaults.set(newValue, forKey: optimizeStorageKey) }
    }
    static var installationId: String {
        if let value = defaults.string(forKey: installIdKey), !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: installIdKey)
        return value
    }

    /// Persist a validated endpoint. A destination change schedules a complete idempotent replay so
    /// rows previously delivered to server A are not silently absent from server B.
    static func saveEndpoint(_ value: String) {
        if endpoint != value {
            endpoint = value
            needsFullReplay = true
            finishReplay()
            lastStatus = "New destination saved; the next sync will replay local history."
        }
    }

    static func beginReplay(_ window: RemoteDerivedWindow) {
        guard window.isValid, let data = try? JSONEncoder().encode(window) else { return }
        defaults.set(data, forKey: replayWindowKey)
        defaults.set(true, forKey: replayInProgressKey)
    }

    static func finishReplay() {
        defaults.removeObject(forKey: replayWindowKey)
        defaults.set(false, forKey: replayInProgressKey)
    }

    static func clearConfiguration() {
        endpoint = ""
        automatic = false
        lastAttemptMs = 0
        lastSuccessMs = 0
        lastStatus = "Self-hosted sync disconnected. Local data was not changed."
        needsFullReplay = true
        finishReplay()
        hasPendingBacklog = false
        optimizeStorage = false
    }
}

/// The Bearer token stays in this-device-only Keychain storage, never UserDefaults or logs.
enum RemoteSyncKeyStore {
    private static let service = "com.noop.remote-sync"
    private static let account = "bearer-token"
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = kCFBooleanTrue
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static var hasKey: Bool { read() != nil }

    static func clear() { SecItemDelete(query as CFDictionary) }
}

enum RemoteSyncSettingsError: LocalizedError {
    case invalidURL
    case embeddedCredentials
    case keychainWrite
    case notConfigured
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a server URL with a host. Public servers must use HTTPS."
        case .embeddedCredentials:
            return "Do not put a username or password in the server URL."
        case .keychainWrite:
            return "The API key could not be saved in Keychain."
        case .notConfigured:
            return "Save a server URL and API key first."
        case .storeUnavailable:
            return "Noop could not open the local data store."
        }
    }
}

/// Persists the retry identity before URLSession starts so a response-lost retry after app
/// termination receives the server's original idempotent acknowledgement.
private actor RemoteSyncBatchIdentityStore:
    RemoteBatchIdentityStoring,
    RemoteDerivedCursorStoring
{
    static let shared = RemoteSyncBatchIdentityStore()

    private let defaults = UserDefaults.standard
    private let batchPrefix = "remoteSync.batchId."
    private let sentAtPrefix = "remoteSync.batchSentAt."
    private let cursorPrefix = "remoteSync.derivedCursor."

    func resolve(fingerprint: String, now: Date) -> RemoteBatchIdentity {
        if let rawId = defaults.string(forKey: batchPrefix + fingerprint),
           let batchId = UUID(uuidString: rawId),
           let sentAt = defaults.string(forKey: sentAtPrefix + fingerprint),
           !sentAt.isEmpty {
            return RemoteBatchIdentity(batchId: batchId, sentAt: sentAt)
        }
        let identity = RemoteBatchIdentity(
            batchId: UUID(),
            sentAt: ISO8601DateFormatter().string(from: now)
        )
        defaults.set(identity.batchId.uuidString.lowercased(), forKey: batchPrefix + fingerprint)
        defaults.set(identity.sentAt, forKey: sentAtPrefix + fingerprint)
        return identity
    }

    func acknowledge(fingerprint: String) {
        defaults.removeObject(forKey: batchPrefix + fingerprint)
        defaults.removeObject(forKey: sentAtPrefix + fingerprint)
    }

    func cursor(for namespace: String) -> RemoteDerivedCursor {
        guard let data = defaults.data(forKey: cursorPrefix + namespace),
              let cursor = try? JSONDecoder().decode(RemoteDerivedCursor.self, from: data) else {
            return .start
        }
        return cursor
    }

    func save(_ cursor: RemoteDerivedCursor, for namespace: String) {
        guard let data = try? JSONEncoder().encode(cursor) else { return }
        defaults.set(data, forKey: cursorPrefix + namespace)
    }

    func resetCursor(for namespace: String) {
        defaults.removeObject(forKey: cursorPrefix + namespace)
    }
}

/// UI-facing orchestration for authenticated probes and automatic/manual delivery.
/// Main-actor isolation serializes button/launch/refresh triggers without blocking network I/O.
@MainActor
enum RemoteSyncService {
    private static var running = false
    private static let automaticIntervalMs = 5 * 60 * 1_000
    private static let noopAlgorithmRevisions = [
        NoopScoreAlgorithmRevision.charge,
        NoopScoreAlgorithmRevision.effort,
        NoopScoreAlgorithmRevision.rest,
    ]

    private struct Namespace {
        let remoteId: String
        let logicalId: String
        let localId: String
        let pairedId: String
        let role: String
        let scoreProvenance: String
        let raw: Bool
        let derived: Bool
    }

    static func normalizedEndpoint(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw RemoteSyncSettingsError.invalidURL }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), url.host != nil else {
            throw RemoteSyncSettingsError.invalidURL
        }
        guard url.user == nil, url.password == nil else {
            throw RemoteSyncSettingsError.embeddedCredentials
        }
        // This validates HTTPS/private-LAN cleartext before anything is persisted.
        _ = try RemoteSyncConfiguration(baseURL: url, apiKey: "validation-only")
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    static func saveConfiguration(endpoint: String, newAPIKey: String, automatic: Bool) throws {
        let normalized = try normalizedEndpoint(endpoint)
        let trimmedKey = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty, !RemoteSyncKeyStore.save(trimmedKey) {
            throw RemoteSyncSettingsError.keychainWrite
        }
        guard RemoteSyncKeyStore.hasKey else { throw RemoteSyncSettingsError.notConfigured }
        RemoteSyncPreferences.saveEndpoint(normalized)
        RemoteSyncPreferences.automatic = automatic
    }

    static func disconnect(repo: Repository) async {
        RemoteSyncKeyStore.clear()
        RemoteSyncPreferences.clearConfiguration()
        if let store = await repo.storeHandle() {
            try? await store.configureRemoteSyncPendingIndexes(enabled: false)
        }
    }

    /// A dedicated installation-scoped producer for the sparse Friends projection. It is deliberately
    /// distinct from the normal `noop_computed` archive producer: leaving a circle can erase this
    /// social copy without deleting the user's separately configured self-hosted backup.
    static func socialDailyDeviceId(for strapId: String) -> String {
        RemoteNamespaceIdentifier.scoped(
            platform: platform,
            installationId: RemoteSyncPreferences.installationId,
            logicalSourceId: strapId + "-noop-friends",
            revisionToken: RemoteNamespaceIdentifier.revisionToken(
                noopAlgorithmRevisions + ["friends-v1"]
            )
        )
    }

    static func testConnection(endpoint: String, apiKeyInput: String) async throws -> String {
        let normalized = try normalizedEndpoint(endpoint)
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = key.isEmpty ? RemoteSyncKeyStore.read() : key
        guard let effectiveKey else { throw RemoteSyncSettingsError.notConfigured }
        let config = try RemoteSyncConfiguration(
            baseURL: URL(string: normalized)!,
            apiKey: effectiveKey,
            timeout: 20
        )
        let response = try await RemoteSyncClient(configuration: config).authenticatedStatus()
        return response.status
    }

    static func catchUpIfDue(repo: Repository) async {
        guard RemoteSyncPreferences.automatic,
              !RemoteSyncPreferences.endpoint.isEmpty,
              RemoteSyncKeyStore.hasKey else { return }
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        guard now - RemoteSyncPreferences.lastAttemptMs >= automaticIntervalMs else { return }
        _ = try? await sync(repo: repo, fullReplay: false)
    }

    @discardableResult
    static func sync(repo: Repository, fullReplay: Bool) async throws -> RemoteSyncRunResult {
        guard !running else {
            return RemoteSyncRunResult(
                uploadedRawRows: 0, uploadedBatches: 0, hasMoreRawRows: false,
                lastResponse: nil
            )
        }
        guard let key = RemoteSyncKeyStore.read(),
              let url = URL(string: RemoteSyncPreferences.endpoint),
              !RemoteSyncPreferences.endpoint.isEmpty else {
            throw RemoteSyncSettingsError.notConfigured
        }
        guard let store = await repo.storeHandle() else {
            throw RemoteSyncSettingsError.storeUnavailable
        }

        running = true
        defer { running = false }
        RemoteSyncPreferences.lastAttemptMs = Int(Date().timeIntervalSince1970 * 1_000)
        RemoteSyncPreferences.lastStatus = "Syncing…"

        do {
            let client = RemoteSyncClient(
                configuration: try RemoteSyncConfiguration(baseURL: url, apiKey: key)
            )
            let activeId = repo.deviceId
            let canonicalId = Repository.whoopSource
            let installationId = RemoteSyncPreferences.installationId

            var totalRows = 0
            var totalBatches = 0
            var hasMoreRaw = false
            var hasMoreDerived = false
            var lastResponse: RemoteSyncResponse?
            var prunedRows = 0
            var pruneHasMore = false
            var strapIds: [String] = []
            for id in [activeId] + (try await store.pairedDeviceIdsForRemoteSync()) + [canonicalId]
            where !strapIds.contains(id) {
                strapIds.append(id)
            }
            var namespaces: [Namespace] = []
            func addNamespace(
                logicalId: String,
                localId: String,
                pairedId: String,
                role: String,
                scoreProvenance: String,
                raw: Bool,
                derived: Bool
            ) {
                let revisionToken = role == "noop_computed"
                    ? RemoteNamespaceIdentifier.revisionToken(Self.noopAlgorithmRevisions)
                    : nil
                let remoteId = RemoteNamespaceIdentifier.scoped(
                    platform: Self.platform,
                    installationId: installationId,
                    logicalSourceId: logicalId,
                    revisionToken: revisionToken
                )
                guard !namespaces.contains(where: { $0.remoteId == remoteId }) else { return }
                namespaces.append(
                    Namespace(
                        remoteId: remoteId,
                        logicalId: logicalId,
                        localId: localId,
                        pairedId: pairedId,
                        role: role,
                        scoreProvenance: scoreProvenance,
                        raw: raw,
                        derived: derived
                    )
                )
            }
            for strapId in strapIds {
                addNamespace(
                    logicalId: strapId + "-strap",
                    localId: strapId,
                    pairedId: strapId,
                    role: "strap_measured",
                    scoreProvenance: "strap_measured",
                    raw: true,
                    derived: false
                )
                addNamespace(
                    logicalId: strapId + "-noop",
                    localId: strapId + "-noop",
                    pairedId: strapId,
                    role: "noop_computed",
                    scoreProvenance: "noop_transparent_algorithm",
                    raw: false,
                    derived: true
                )
            }
            addNamespace(
                logicalId: "whoop-official-reference",
                localId: canonicalId,
                pairedId: activeId,
                role: "official_reference",
                scoreProvenance: "user_imported_whoop_export",
                raw: false,
                derived: true
            )
            addNamespace(
                logicalId: Repository.journalDeviceId,
                localId: Repository.journalDeviceId,
                pairedId: activeId,
                role: "noop_journal",
                scoreProvenance: "user_entered_noop_journal",
                raw: false,
                derived: true
            )
            let importedSources: [(String, String, String)] = [
                (
                    Repository.appleHealthSource,
                    "apple_health_import",
                    "user_imported_apple_health"
                ),
                (
                    Repository.healthConnectSource,
                    "health_connect_import",
                    "user_imported_health_connect"
                ),
                (
                    Repository.activityFileSource,
                    "activity_file_import",
                    "user_imported_activity_file"
                ),
            ] + Repository.wearableImportSources.map {
                ($0, "wearable_import", "user_imported_wearable")
            }
            for (sourceId, role, provenance) in importedSources {
                addNamespace(
                    logicalId: sourceId,
                    localId: sourceId,
                    pairedId: activeId,
                    role: role,
                    scoreProvenance: provenance,
                    raw: false,
                    derived: true
                )
            }

            let replayStateIsIncomplete =
                RemoteSyncPreferences.replayInProgress &&
                RemoteSyncPreferences.replayWindow == nil
            let initializeReplay =
                fullReplay || RemoteSyncPreferences.needsFullReplay || replayStateIsIncomplete
            if initializeReplay {
                let window = RemoteDerivedWindow(
                    endingAt: Date(),
                    historyDays: 3_650,
                    timeZone: .current
                )
                for strapId in strapIds {
                    try await store.resetRemoteSyncState(deviceId: strapId)
                }
                for namespace in namespaces {
                    await RemoteSyncBatchIdentityStore.shared.resetCursor(
                        for: namespace.remoteId
                    )
                }
                // Publish the fixed replay window only after every durable reset. If termination happens
                // before here, `needsFullReplay` remains set and the idempotent reset runs again.
                RemoteSyncPreferences.beginReplay(window)
                RemoteSyncPreferences.needsFullReplay = false
            }
            let replayWindow = RemoteSyncPreferences.replayWindow
            let replay =
                RemoteSyncPreferences.replayInProgress && replayWindow != nil

            for namespace in namespaces {
                var metadata = [
                    "installation_id": installationId,
                    "logical_source_id": namespace.logicalId,
                    "namespace": namespace.role,
                    "paired_device_id": namespace.pairedId,
                    "privacy": "explicit_opt_in",
                    "score_provenance": namespace.scoreProvenance,
                ]
                if namespace.role == "noop_computed" {
                    metadata["algorithm_revision"] = Self.noopAlgorithmRevisions.joined(
                        separator: "+"
                    )
                }
                let source = RemoteSyncSource(
                    deviceId: namespace.remoteId,
                    appVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String,
                    platform: Self.platform,
                    metadata: metadata
                )
                let coordinator = RemoteSyncCoordinator(
                    store: store,
                    uploader: client,
                    identityStore: RemoteSyncBatchIdentityStore.shared,
                    cursorStore: RemoteSyncBatchIdentityStore.shared
                )
                let result = try await coordinator.sync(
                    source: source,
                    storeDeviceId: namespace.localId,
                    includeRaw: namespace.raw,
                    includeDerived: namespace.derived,
                    derivedWorkoutSources: namespace.role == "official_reference"
                        ? Set(["whoop"])
                        : nil,
                    derivedMetricProvenance: namespace.role == "official_reference"
                        ? .officialReference
                        : (namespace.role == "noop_computed" ? .noopComputed : .userOwned),
                    derivedHistoryDays: replay ? 3_650 : 400,
                    derivedWindow: replayWindow,
                    retainDerivedCompletion: replay,
                    maxBatches: replay ? 50 : 8
                )
                totalRows += result.uploadedRawRows
                totalBatches += result.uploadedBatches
                hasMoreRaw = hasMoreRaw || result.hasMoreRawRows
                hasMoreDerived = hasMoreDerived || result.hasMoreDerivedRows
                lastResponse = result.lastResponse ?? lastResponse
            }

            let hasMore = hasMoreRaw || hasMoreDerived
            if replay && !hasMore {
                // Completed markers prevent page-one loops while any namespace is still draining. Once
                // the global snapshot is complete, clear all of them so the next run is a fresh rolling
                // 400-day refresh rather than a permanently completed replay.
                for namespace in namespaces where namespace.derived {
                    await RemoteSyncBatchIdentityStore.shared.resetCursor(
                        for: namespace.remoteId
                    )
                }
                RemoteSyncPreferences.finishReplay()
            }
            if RemoteSyncPreferences.optimizeStorage {
                let cutoff = Int(Date().timeIntervalSince1970) - 14 * 86_400
                for strapId in strapIds {
                    let result = try await store.pruneAcknowledgedRemoteRows(
                        deviceId: strapId,
                        olderThan: cutoff
                    )
                    prunedRows += result.deletedRows
                    pruneHasMore = pruneHasMore || result.hasMoreEligibleRows
                }
            }
            RemoteSyncPreferences.hasPendingBacklog = hasMore
            RemoteSyncPreferences.lastSuccessMs = Int(Date().timeIntervalSince1970 * 1_000)
            let storageSuffix = (prunedRows > 0
                ? " Freed \(prunedRows) acknowledged local raw rows."
                : "")
                + (pruneHasMore
                    ? " More acknowledged rows will be trimmed next time."
                    : "")
            RemoteSyncPreferences.lastStatus = (
                hasMore
                    ? "Uploaded \(totalRows) raw rows; more history will continue next time."
                    : "Up to date - uploaded \(totalRows) pending raw rows."
            ) + storageSuffix
            return RemoteSyncRunResult(
                uploadedRawRows: totalRows,
                uploadedBatches: totalBatches,
                hasMoreRawRows: hasMoreRaw,
                hasMoreDerivedRows: hasMoreDerived,
                lastResponse: lastResponse
            )
        } catch {
            // Client errors intentionally never include the Bearer token.
            RemoteSyncPreferences.lastStatus = "Sync failed: \(error.localizedDescription)"
            throw error
        }
    }

    private static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "apple"
        #endif
    }
}
