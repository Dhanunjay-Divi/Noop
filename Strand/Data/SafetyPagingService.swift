import Combine
import Foundation
import NoopRemoteSync
import Security
import StrandAnalytics
import UserNotifications

@MainActor
final class SafetyPagingService: ObservableObject {
    enum SetupState: Equatable {
        case needsServer
        case needsEnrollment
        case ready
    }

    @Published private(set) var setupState: SetupState
    @Published private(set) var contacts: [RemoteSafetyContact] = []
    @Published private(set) var acceptedCount: Int
    @Published private(set) var maximumContacts = 5
    @Published private(set) var pagingConfigured = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastDispatch: RemoteSafetyDispatch?
    @Published private(set) var recentIncidents: [RemoteSafetyDispatch] = []
    @Published var errorMessage: String?

    static let minimumAcceptedContacts = 2

    init() {
        acceptedCount = SafetyPagingPreferences.acceptedCount
        if Self.memberContext != nil {
            setupState = .ready
        } else if Self.canBootstrap {
            setupState = .needsEnrollment
        } else {
            setupState = .needsServer
        }
        SafetyContactReminders.restore()
    }

    var canPage: Bool {
        setupState == .ready
            && acceptedCount >= Self.minimumAcceptedContacts
            && pagingConfigured
            && activeIncident == nil
            && !isBusy
    }

    var remainingAcceptedContacts: Int {
        max(Self.minimumAcceptedContacts - acceptedCount, 0)
    }

    var activeIncident: RemoteSafetyDispatch? {
        recentIncidents.first {
            [.open, .acknowledged, .pending].contains($0.status)
        } ?? lastDispatch.flatMap {
            [.open, .acknowledged, .pending].contains($0.status) ? $0 : nil
        }
    }

    func markSetupPresented() {
        SafetyPagingPreferences.setupReminderRequired = true
        SafetyContactReminders.update(
            reminderRequired: true,
            acceptedCount: acceptedCount
        )
    }

    func dismissError() {
        errorMessage = nil
    }

    func bootstrap(displayName: String) async {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count) else {
            errorMessage = "Enter your name so contacts know who invited them."
            return
        }
        guard let adminToken = RemoteSyncKeyStore.read(),
              let endpoint = URL(string: RemoteSyncPreferences.endpoint)
        else {
            setupState = .needsServer
            errorMessage = "Safety Network is unavailable. Check the service connection in Backup & Sync."
            return
        }
        await withBusy {
            do {
                let pending = try Self.pendingEnrollment(
                    endpoint: endpoint,
                    displayName: name
                )
                let client = RemoteSyncClient(
                    configuration: try RemoteSyncConfiguration(
                        baseURL: pending.endpoint,
                        apiKey: adminToken,
                        timeout: 30
                    )
                )
                let response = try await client.bootstrapSafetyProfile(
                    RemoteSafetyProfileBootstrap(
                        displayName: pending.displayName,
                        installationId: RemoteSyncPreferences.installationId,
                        enrollmentId: pending.enrollmentId,
                        safetyToken: pending.token
                    )
                )
                SafetyPagingPreferences.endpoint = pending.endpoint.absoluteString
                SafetyPagingPreferences.profileId =
                    response.profile.profileId.uuidString.lowercased()
                SafetyPagingPreferences.displayName = response.profile.displayName
                SafetyPagingPreferences.clearPendingEnrollment()
                setupState = .ready
                statusMessage = "Safety Network is ready. Add two contacts."
                await reload()
            } catch {
                present(error)
            }
        }
    }

    func refresh() async {
        guard setupState == .ready else {
            setupState = Self.canBootstrap ? .needsEnrollment : .needsServer
            return
        }
        await withBusy {
            await reload()
        }
    }

    func addContact(displayName: String, phone: String) async -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count) else {
            errorMessage = "Enter a contact name."
            return false
        }
        guard let normalizedPhone = Self.normalizedE164(phone) else {
            errorMessage = "Enter the full phone number with country code, for example +14155550123."
            return false
        }
        guard contacts.count < maximumContacts else {
            errorMessage = "You can add up to five emergency contacts."
            return false
        }
        var added = false
        await withBusy {
            do {
                let context = try Self.requiredContext()
                let response = try await Self.client(for: context).addSafetyContact(
                    RemoteSafetyContactCreate(
                        displayName: name,
                        phoneE164: normalizedPhone
                    ),
                    authorization: .safety(token: context.token)
                )
                statusMessage = response.contact.invitationDeliveryStatus == .failed
                    ? "Contact saved, but the invitation could not be delivered."
                    : "Invitation sent. This contact must accept before paging is enabled."
                if response.contact.invitationDeliveryStatus == .failed {
                    errorMessage = response.contact.invitationError
                        ?? "The server could not send this invitation."
                }
                await reload()
                added = true
            } catch {
                present(error)
            }
        }
        return added
    }

    func resend(_ contact: RemoteSafetyContact) async {
        await withBusy {
            do {
                let context = try Self.requiredContext()
                let response = try await Self.client(for: context)
                    .resendSafetyContactInvitation(
                        contact.contactId,
                        authorization: .safety(token: context.token)
                    )
                statusMessage = response.contact.invitationDeliveryStatus == .failed
                    ? "Invitation delivery failed."
                    : "Invitation sent again."
                if response.contact.invitationDeliveryStatus == .failed {
                    errorMessage = response.contact.invitationError
                        ?? "The server could not send this invitation."
                }
                await reload()
            } catch {
                present(error)
            }
        }
    }

    func remove(_ contact: RemoteSafetyContact) async {
        await withBusy {
            do {
                let context = try Self.requiredContext()
                try await Self.client(for: context).removeSafetyContact(
                    contact.contactId,
                    authorization: .safety(token: context.token)
                )
                statusMessage = "\(contact.displayName) was removed."
                await reload()
            } catch {
                present(error)
            }
        }
    }

    func pageAcceptedContacts() async -> Bool {
        guard canPage else {
            errorMessage = pagingConfigured
                ? "At least two accepted emergency contacts are required."
                : "SMS and voice paging are not configured on this server."
            return false
        }
        var submitted = false
        await withBusy {
            let key = SafetyPagingPreferences.pendingPageKey ?? UUID()
            SafetyPagingPreferences.pendingPageKey = key
            do {
                let context = try Self.requiredContext()
                let dispatch = try await Self.client(for: context).sendManualSafetyPage(
                    idempotencyKey: key,
                    authorization: .safety(token: context.token)
                )
                SafetyPagingPreferences.pendingPageKey = nil
                lastDispatch = dispatch
                merge(dispatch)
                SafetySOSRuntime.shared.startLocationSharing(
                    for: dispatch,
                    service: self
                )
                statusMessage = (
                    "Safety page opened. SMS is sending now; voice follows "
                    + "if nobody acknowledges."
                )
                submitted = dispatch.status != .failed
            } catch {
                let serverStatus: Int?
                if case let RemoteSyncError.server(status, _) = error {
                    serverStatus = status
                } else {
                    serverStatus = nil
                }
                if !Self.shouldRetainPageIdempotencyKey(serverStatus: serverStatus) {
                    SafetyPagingPreferences.pendingPageKey = nil
                }
                present(error)
            }
        }
        return submitted
    }

    func refreshLatestIncident() async {
        guard setupState == .ready else { return }
        do {
            let context = try Self.requiredContext()
            let client = try Self.client(for: context)
            if let incident = activeIncident ?? lastDispatch {
                let refreshed = try await client.safetyIncident(
                    incident.dispatchId,
                    authorization: .safety(token: context.token)
                )
                lastDispatch = refreshed
                merge(refreshed)
                if ![.open, .acknowledged, .pending].contains(refreshed.status) {
                    SafetySOSRuntime.shared.stopLocationSharing(
                        dispatchId: refreshed.dispatchId
                    )
                }
            } else {
                let response = try await client.safetyIncidents(
                    limit: 10,
                    authorization: .safety(token: context.token)
                )
                recentIncidents = response.incidents
                lastDispatch = response.incidents.first
            }
        } catch {
            // Periodic status refresh is best-effort. Explicit actions surface errors.
        }
    }

    func resolve(_ incident: RemoteSafetyDispatch) async {
        await transition(incident, action: .resolve)
    }

    func cancel(_ incident: RemoteSafetyDispatch) async {
        await transition(incident, action: .cancel)
    }

    func updateLocation(
        for dispatchId: UUID,
        sequence: Int64,
        location: SafetyLocation
    ) async throws -> RemoteSafetyLocationResponse {
        guard location.isValid else {
            throw SafetyPagingError.invalidLocation
        }
        let context = try Self.requiredContext()
        return try await Self.client(for: context).updateSafetyIncidentLocation(
            dispatchId,
            update: RemoteSafetyLocationUpdate(
                sequence: sequence,
                latitude: location.latitude,
                longitude: location.longitude,
                horizontalAccuracyMeters: location.horizontalAccuracyMeters,
                capturedAt: Self.iso8601Timestamp(location.capturedAtUnix)
            ),
            authorization: .safety(token: context.token)
        )
    }

    private enum IncidentAction {
        case resolve
        case cancel
    }

    private func transition(
        _ incident: RemoteSafetyDispatch,
        action: IncidentAction
    ) async {
        await withBusy {
            do {
                let context = try Self.requiredContext()
                let client = try Self.client(for: context)
                let updated: RemoteSafetyDispatch
                switch action {
                case .resolve:
                    updated = try await client.resolveSafetyIncident(
                        incident.dispatchId,
                        authorization: .safety(token: context.token)
                    )
                    statusMessage = "Safety page marked resolved."
                case .cancel:
                    updated = try await client.cancelSafetyIncident(
                        incident.dispatchId,
                        authorization: .safety(token: context.token)
                    )
                    statusMessage = "Safety page cancelled."
                }
                lastDispatch = updated
                merge(updated)
                SafetySOSRuntime.shared.stopLocationSharing(
                    dispatchId: incident.dispatchId
                )
            } catch {
                present(error)
            }
        }
    }

    private func reload() async {
        do {
            let context = try Self.requiredContext()
            let client = try Self.client(for: context)
            let response = try await client.safetyContacts(
                authorization: .safety(token: context.token)
            )
            contacts = response.contacts
            acceptedCount = response.acceptedCount
            maximumContacts = response.maximumContacts
            pagingConfigured = response.pagingConfigured
            SafetyPagingPreferences.acceptedCount = response.acceptedCount
            SafetyPagingPreferences.setupReminderRequired =
                response.acceptedCount < Self.minimumAcceptedContacts
            SafetyContactReminders.update(
                reminderRequired: SafetyPagingPreferences.setupReminderRequired,
                acceptedCount: response.acceptedCount
            )
            NotificationCenter.default.post(
                name: .safetyContactsDidChange,
                object: nil
            )
            if response.acceptedCount >= Self.minimumAcceptedContacts {
                statusMessage = "Safety paging is ready."
            }
            let incidents = try await client.safetyIncidents(
                limit: 10,
                authorization: .safety(token: context.token)
            )
            recentIncidents = incidents.incidents
            lastDispatch = incidents.incidents.first
        } catch {
            present(error)
        }
    }

    private func merge(_ incident: RemoteSafetyDispatch) {
        recentIncidents.removeAll { $0.dispatchId == incident.dispatchId }
        recentIncidents.insert(incident, at: 0)
        if recentIncidents.count > 10 {
            recentIncidents.removeLast(recentIncidents.count - 10)
        }
    }

    private func withBusy(_ operation: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        await operation()
        isBusy = false
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private struct MemberContext {
        let endpoint: URL
        let token: String
    }

    private struct PendingEnrollment {
        let endpoint: URL
        let enrollmentId: UUID
        let displayName: String
        let token: String
    }

    private static var canBootstrap: Bool {
        !RemoteSyncPreferences.endpoint.isEmpty && RemoteSyncKeyStore.hasKey
    }

    private static var memberContext: MemberContext? {
        guard !SafetyPagingPreferences.profileId.isEmpty,
              let endpoint = URL(string: SafetyPagingPreferences.endpoint),
              let token = SafetyPagingKeyStore.read()
        else { return nil }
        return MemberContext(endpoint: endpoint, token: token)
    }

    private static func requiredContext() throws -> MemberContext {
        guard let context = memberContext else {
            throw SafetyPagingError.notEnrolled
        }
        return context
    }

    private static func client(for context: MemberContext) throws -> RemoteSyncClient {
        RemoteSyncClient(
            configuration: try RemoteSyncConfiguration(
                baseURL: context.endpoint,
                apiKey: context.token,
                timeout: 30
            )
        )
    }

    private static func pendingEnrollment(
        endpoint: URL,
        displayName: String
    ) throws -> PendingEnrollment {
        if let enrollmentId = UUID(
            uuidString: SafetyPagingPreferences.pendingEnrollmentId
        ),
           SafetyPagingPreferences.pendingEndpoint == endpoint.absoluteString,
           !SafetyPagingPreferences.pendingDisplayName.isEmpty,
           let token = SafetyPagingKeyStore.read() {
            return PendingEnrollment(
                endpoint: endpoint,
                enrollmentId: enrollmentId,
                displayName: SafetyPagingPreferences.pendingDisplayName,
                token: token
            )
        }
        let token = try newToken()
        guard SafetyPagingKeyStore.save(token) else {
            throw SafetyPagingError.keychainWrite
        }
        let enrollmentId = UUID()
        SafetyPagingPreferences.pendingEndpoint = endpoint.absoluteString
        SafetyPagingPreferences.pendingEnrollmentId =
            enrollmentId.uuidString.lowercased()
        SafetyPagingPreferences.pendingDisplayName = displayName
        return PendingEnrollment(
            endpoint: endpoint,
            enrollmentId: enrollmentId,
            displayName: displayName,
            token: token
        )
    }

    private static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw SafetyPagingError.randomCredential }
        let suffix = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "noop_safety_\(suffix)"
    }

    private static func iso8601Timestamp(_ unix: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(unix))
        )
    }

    static func normalizedE164(_ raw: String) -> String? {
        var compact = raw.filter { $0 == "+" || $0.isNumber }
        if compact.hasPrefix("00") {
            compact = "+" + compact.dropFirst(2)
        }
        guard compact.first == "+" else { return nil }
        let digits = compact.dropFirst()
        guard (8...15).contains(digits.count),
              digits.first != "0",
              digits.allSatisfy(\.isNumber)
        else { return nil }
        return compact
    }

    static func shouldRetainPageIdempotencyKey(serverStatus: Int?) -> Bool {
        guard let serverStatus else { return true }
        return !(400..<500).contains(serverStatus)
    }
}

enum SafetyPagingPreferences {
    private static let defaults = UserDefaults.standard
    private static let prefix = "safetyPaging."

    static var endpoint: String {
        get { defaults.string(forKey: prefix + "endpoint") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "endpoint") }
    }
    static var profileId: String {
        get { defaults.string(forKey: prefix + "profileId") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "profileId") }
    }
    static var displayName: String {
        get { defaults.string(forKey: prefix + "displayName") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "displayName") }
    }
    static var acceptedCount: Int {
        get { defaults.integer(forKey: prefix + "acceptedCount") }
        set { defaults.set(max(newValue, 0), forKey: prefix + "acceptedCount") }
    }
    static var setupReminderRequired: Bool {
        get { defaults.bool(forKey: prefix + "setupReminderRequired") }
        set { defaults.set(newValue, forKey: prefix + "setupReminderRequired") }
    }
    static var pendingEndpoint: String {
        get { defaults.string(forKey: prefix + "pendingEndpoint") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "pendingEndpoint") }
    }
    static var pendingEnrollmentId: String {
        get { defaults.string(forKey: prefix + "pendingEnrollmentId") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "pendingEnrollmentId") }
    }
    static var pendingDisplayName: String {
        get { defaults.string(forKey: prefix + "pendingDisplayName") ?? "" }
        set { defaults.set(newValue, forKey: prefix + "pendingDisplayName") }
    }
    static var pendingPageKey: UUID? {
        get {
            defaults.string(forKey: prefix + "pendingPageKey")
                .flatMap(UUID.init(uuidString:))
        }
        set {
            if let newValue {
                defaults.set(
                    newValue.uuidString.lowercased(),
                    forKey: prefix + "pendingPageKey"
                )
            } else {
                defaults.removeObject(forKey: prefix + "pendingPageKey")
            }
        }
    }

    static func clearPendingEnrollment() {
        defaults.removeObject(forKey: prefix + "pendingEndpoint")
        defaults.removeObject(forKey: prefix + "pendingEnrollmentId")
        defaults.removeObject(forKey: prefix + "pendingDisplayName")
    }
}

private enum SafetyPagingKeyStore {
    private static let service = "com.noop.safety-paging"
    private static let account = "safety-token"
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8), !data.isEmpty else { return false }
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = kCFBooleanTrue
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }
}

@MainActor
enum SafetyContactReminders {
    private static let requestId = "noop.safety.contacts.setup"

    static func restore() {
        update(
            reminderRequired: SafetyPagingPreferences.setupReminderRequired,
            acceptedCount: SafetyPagingPreferences.acceptedCount
        )
    }

    static func update(reminderRequired: Bool, acceptedCount: Int) {
        let center = UNUserNotificationCenter.current()
        guard needsReminder(
            reminderRequired: reminderRequired,
            acceptedCount: acceptedCount
        ) else {
            center.removePendingNotificationRequests(withIdentifiers: [requestId])
            return
        }
        Task { @MainActor in
            let settings = await center.notificationSettings()
            guard notificationsAuthorized(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "safety.contacts_reminder.title")
            content.body = String(localized: "safety.contacts_reminder.body")
            content.sound = .default
            content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
            content.threadIdentifier = "noop.safety"
            content.userInfo = [
                NotificationRouteBridge.userInfoKey:
                    NoopNotificationRoute.safety.rawValue,
            ]
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: 3 * 24 * 60 * 60,
                repeats: true
            )
            center.removePendingNotificationRequests(withIdentifiers: [requestId])
            try? await center.add(
                UNNotificationRequest(
                    identifier: requestId,
                    content: content,
                    trigger: trigger
                )
            )
        }
    }

    static func needsReminder(reminderRequired: Bool, acceptedCount: Int) -> Bool {
        reminderRequired
            && acceptedCount < SafetyPagingService.minimumAcceptedContacts
    }

    private static func notificationsAuthorized(
        _ status: UNAuthorizationStatus
    ) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
        #if os(iOS)
        case .ephemeral:
            return true
        #endif
        default:
            return false
        }
    }
}

private enum SafetyPagingError: LocalizedError {
    case keychainWrite
    case randomCredential
    case notEnrolled
    case invalidLocation

    var errorDescription: String? {
        switch self {
        case .keychainWrite:
            return "The private safety credential could not be saved in Keychain."
        case .randomCredential:
            return "NOOP could not generate a private safety credential."
        case .notEnrolled:
            return "Finish Safety setup before managing emergency contacts."
        case .invalidLocation:
            return "The location fix is invalid."
        }
    }
}

extension Notification.Name {
    static let safetyContactsDidChange =
        Notification.Name("noop.safetyContactsDidChange")
}
