import Foundation
import NoopRemoteSync
import StrandAnalytics
import UserNotifications
#if os(iOS)
import CoreLocation
#endif

/// Owns explicit SOS dispatch and the active incident's latest-only location session.
///
/// This never triggers from wellness metrics. A page starts only after the configured sequence of
/// physical band events or the existing manual Safety Center action.
@MainActor
final class SafetySOSRuntime {
    struct StatusNotificationMarker: Hashable {
        let dispatchId: String
        let status: String
    }

    enum TriggerOutcome {
        case opened
        case alreadyActive
        case unavailable(String)

        var logLine: String {
            switch self {
            case .opened:
                return "SOS page request accepted; delivery is pending"
            case .alreadyActive:
                return "SOS page already active; latest-location sharing resumed"
            case .unavailable(let reason):
                return "SOS page was not sent: \(reason)"
            }
        }
    }

    static let shared = SafetySOSRuntime()

    private static let activeDispatchKey = "safety.liveLocation.dispatchId"
    private static let activeExpiryKey = "safety.liveLocation.expiresAt"
    private static let activeSequenceKey = "safety.liveLocation.sequence"
    private static let lastNotifiedDispatchKey = "safety.status.lastNotifiedDispatchId"
    private static let lastNotifiedStatusKey = "safety.status.lastNotifiedStatus"
    static let fallbackSessionSeconds: TimeInterval = 8 * 60 * 60
    static let maximumSessionSeconds: TimeInterval = 12 * 60 * 60
    private var triggerTask: Task<Void, Never>?
    private var statusMonitorTask: Task<Void, Never>?
    private var monitoredDispatchId: UUID?
    private var pendingStatusNotifications: Set<StatusNotificationMarker> = []
    #if os(iOS)
    private let locationStreamer = SafetyIncidentLocationStreamer()
    #endif

    private init() {}

    func trigger(
        completion: @escaping @MainActor (TriggerOutcome) -> Void
    ) {
        guard triggerTask == nil else { return }
        triggerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { triggerTask = nil }

            let service = SafetyPagingService()
            await service.refresh()
            if let incident = service.activeIncident {
                startLocationSharing(for: incident, service: service)
                let outcome = TriggerOutcome.alreadyActive
                postResultNotification(outcome)
                completion(outcome)
                return
            }
            guard service.canPage else {
                let reason = service.errorMessage
                    ?? "finish Safety setup and add two accepted contacts"
                let outcome = TriggerOutcome.unavailable(reason)
                postResultNotification(outcome)
                completion(outcome)
                return
            }

            let submitted = await service.pageAcceptedContacts(origin: .band)
            let outcome: TriggerOutcome
            if submitted, service.lastDispatch != nil {
                outcome = .opened
            } else {
                outcome = .unavailable(
                    service.errorMessage ?? "the paging server did not accept the request"
                )
            }
            postResultNotification(outcome)
            completion(outcome)
        }
    }

    func startLocationSharing(
        for dispatch: RemoteSafetyDispatch,
        service: SafetyPagingService
    ) {
        let now = Date()
        guard Self.isActive(dispatch.status),
              var expiresAt = Self.boundedSessionExpiry(
                requested: Self.parseISO8601(dispatch.expiresAt),
                now: now
              )
        else {
            stopLocationSharing(dispatchId: dispatch.dispatchId)
            return
        }
        let wasSameDispatch =
            UserDefaults.standard.string(forKey: Self.activeDispatchKey)
            == dispatch.dispatchId.uuidString.lowercased()
        if wasSameDispatch,
           let persistedExpiry = Self.parseISO8601(
                UserDefaults.standard.string(forKey: Self.activeExpiryKey)
           ),
           persistedExpiry > now {
            expiresAt = min(expiresAt, persistedExpiry)
        }
        UserDefaults.standard.set(
            dispatch.dispatchId.uuidString.lowercased(),
            forKey: Self.activeDispatchKey
        )
        UserDefaults.standard.set(
            Self.iso8601(expiresAt),
            forKey: Self.activeExpiryKey
        )
        let resumedSequence = Self.resumedLocationSequence(
            server: dispatch.latestLocation?.sequence,
            persisted: UserDefaults.standard.object(
                forKey: Self.activeSequenceKey
            ) as? NSNumber,
            sameDispatch: wasSameDispatch
        )
        UserDefaults.standard.set(
            NSNumber(value: resumedSequence),
            forKey: Self.activeSequenceKey
        )
        startStatusMonitoring(dispatchId: dispatch.dispatchId)
        #if os(iOS)
        locationStreamer.start(
            dispatchId: dispatch.dispatchId,
            expiresAt: expiresAt,
            startingSequence: resumedSequence
        ) { location, sequence in
            if UserDefaults.standard.string(forKey: Self.activeDispatchKey)
                == dispatch.dispatchId.uuidString.lowercased() {
                UserDefaults.standard.set(
                    NSNumber(value: sequence),
                    forKey: Self.activeSequenceKey
                )
            }
            _ = try await service.updateLocation(
                for: dispatch.dispatchId,
                sequence: sequence,
                location: location
            )
        }
        #endif
    }

    func stopLocationSharing(dispatchId: UUID? = nil) {
        if let dispatchId,
           UserDefaults.standard.string(forKey: Self.activeDispatchKey)
            != dispatchId.uuidString.lowercased() {
            return
        }
        stopLocationUpdates(dispatchId: dispatchId)
        statusMonitorTask?.cancel()
        statusMonitorTask = nil
        monitoredDispatchId = nil
        UserDefaults.standard.removeObject(forKey: Self.activeDispatchKey)
        UserDefaults.standard.removeObject(forKey: Self.activeExpiryKey)
        UserDefaults.standard.removeObject(forKey: Self.activeSequenceKey)
    }

    func restoreLocationSharingIfNeeded() async {
        guard let raw = UserDefaults.standard.string(forKey: Self.activeDispatchKey),
              let dispatchId = UUID(uuidString: raw)
        else { return }
        let service = SafetyPagingService()
        do {
            let dispatch = try await service.incident(dispatchId)
            guard UserDefaults.standard.string(forKey: Self.activeDispatchKey)
                    == dispatchId.uuidString.lowercased()
            else { return }
            let reconciled = await reconcileStatus(dispatch)
            guard UserDefaults.standard.string(forKey: Self.activeDispatchKey)
                    == dispatchId.uuidString.lowercased()
            else { return }
            let locallyExpired = Self.persistedSessionExpiry(now: Date()) == nil
            guard Self.shouldRetainMonitorState(
                status: dispatch.status,
                locallyExpired: locallyExpired,
                notificationReconciled: reconciled
            ) else {
                stopLocationSharing(dispatchId: dispatchId)
                return
            }
            startStatusMonitoring(dispatchId: dispatchId)
            guard !locallyExpired, Self.isActive(dispatch.status) else {
                stopLocationUpdates(dispatchId: dispatchId)
                return
            }
            startLocationSharing(for: dispatch, service: service)
            return
        } catch let RemoteSyncError.server(status, _)
            where [401, 404, 409, 410].contains(status) {
            stopLocationSharing(dispatchId: dispatchId)
            return
        } catch {
            // A transient lookup failure must not terminate an active user-started page. Resume only
            // from its persisted, privacy-bounded deadline while the status monitor retries.
        }
        guard UserDefaults.standard.string(forKey: Self.activeDispatchKey)
                == dispatchId.uuidString.lowercased()
        else { return }
        guard let fallbackExpiry = Self.persistedSessionExpiry(now: Date()) else {
            stopLocationUpdates(dispatchId: dispatchId)
            startStatusMonitoring(dispatchId: dispatchId)
            return
        }
        UserDefaults.standard.set(
            Self.iso8601(fallbackExpiry),
            forKey: Self.activeExpiryKey
        )
        startStatusMonitoring(dispatchId: dispatchId)
        #if os(iOS)
        let resumedSequence = Self.resumedLocationSequence(
            server: nil,
            persisted: UserDefaults.standard.object(
                forKey: Self.activeSequenceKey
            ) as? NSNumber,
            sameDispatch: true
        )
        locationStreamer.start(
            dispatchId: dispatchId,
            expiresAt: fallbackExpiry,
            startingSequence: resumedSequence
        ) { location, sequence in
            if UserDefaults.standard.string(forKey: Self.activeDispatchKey)
                == dispatchId.uuidString.lowercased() {
                UserDefaults.standard.set(
                    NSNumber(value: sequence),
                    forKey: Self.activeSequenceKey
                )
            }
            _ = try await service.updateLocation(
                for: dispatchId,
                sequence: sequence,
                location: location
            )
        }
        #endif
    }

    /// Reconciles the persisted active page during foreground launch and opportunistic background wakes.
    /// A successful check does not claim that iOS will grant future background execution.
    @discardableResult
    func refreshActiveIncidentStatusIfNeeded() async -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: Self.activeDispatchKey),
              let dispatchId = UUID(uuidString: raw)
        else { return true }
        let locallyExpired = Self.parseISO8601(
            UserDefaults.standard.string(forKey: Self.activeExpiryKey)
        ).map { $0 <= Date() } ?? false
        if locallyExpired {
            stopLocationUpdates(dispatchId: dispatchId)
        }
        do {
            let dispatch = try await SafetyPagingService().incident(dispatchId)
            guard UserDefaults.standard.string(forKey: Self.activeDispatchKey)
                    == dispatchId.uuidString.lowercased()
            else { return true }
            let reconciled = await reconcileStatus(dispatch)
            if Self.shouldRetainMonitorState(
                status: dispatch.status,
                locallyExpired: locallyExpired,
                notificationReconciled: reconciled
            ) {
                startStatusMonitoring(dispatchId: dispatchId)
            } else {
                stopLocationSharing(dispatchId: dispatchId)
            }
            return reconciled
        } catch let RemoteSyncError.server(status, _)
            where [401, 404, 409, 410].contains(status) {
            stopLocationSharing(dispatchId: dispatchId)
            return true
        } catch {
            return false
        }
    }

    private func startStatusMonitoring(dispatchId: UUID) {
        if monitoredDispatchId == dispatchId, statusMonitorTask != nil {
            return
        }
        statusMonitorTask?.cancel()
        monitoredDispatchId = dispatchId
        statusMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.monitoredDispatchId == dispatchId,
                      UserDefaults.standard.string(forKey: Self.activeDispatchKey)
                        == dispatchId.uuidString.lowercased()
                else { return }
                let succeeded = await self.refreshActiveIncidentStatusIfNeeded()
                guard !Task.isCancelled,
                      self.monitoredDispatchId == dispatchId
                else { return }
                try? await Task.sleep(
                    nanoseconds: UInt64(succeeded ? 15 : 45) * 1_000_000_000
                )
            }
        }
    }

    @discardableResult
    func reconcileStatus(_ dispatch: RemoteSafetyDispatch) async -> Bool {
        switch dispatch.status {
        case .acknowledged:
            return await postStatusNotificationOnce(
                dispatch: dispatch,
                titleKey: "safety.page.status.acknowledged",
                bodyKey: "safety.page.detail.acknowledged"
            )
        case .failed:
            stopLocationUpdates(dispatchId: dispatch.dispatchId)
            let posted = await postStatusNotificationOnce(
                dispatch: dispatch,
                titleKey: "safety.page.all_contacts_failed_title",
                bodyKey: "safety.page.detail.failed"
            )
            if posted {
                stopLocationSharing(dispatchId: dispatch.dispatchId)
            }
            return posted
        case .open, .pending:
            return true
        case .resolved, .cancelled, .expired, .submitted, .partialFailure:
            stopLocationSharing(dispatchId: dispatch.dispatchId)
            return true
        }
    }

    static func isActive(_ status: RemoteSafetyIncidentStatus) -> Bool {
        [.open, .acknowledged, .pending].contains(status)
    }

    static func boundedSessionExpiry(
        requested: Date?,
        now: Date
    ) -> Date? {
        let maximum = now.addingTimeInterval(maximumSessionSeconds)
        guard let requested else {
            return now.addingTimeInterval(fallbackSessionSeconds)
        }
        guard requested > now else { return nil }
        return min(requested, maximum)
    }

    static func resumedLocationSequence(
        server: Int64?,
        persisted: NSNumber?,
        sameDispatch: Bool
    ) -> Int64 {
        let serverValue = max(server ?? 0, 0)
        guard sameDispatch else { return serverValue }
        return max(serverValue, max(persisted?.int64Value ?? 0, 0))
    }

    static func markerAfterNotificationAttempt(
        previous: StatusNotificationMarker?,
        candidate: StatusNotificationMarker,
        postedSuccessfully: Bool
    ) -> StatusNotificationMarker? {
        postedSuccessfully ? candidate : previous
    }

    static func shouldRetainMonitorState(
        status: RemoteSafetyIncidentStatus,
        locallyExpired: Bool,
        notificationReconciled: Bool
    ) -> Bool {
        !notificationReconciled || (!locallyExpired && isActive(status))
    }

    private func postStatusNotificationOnce(
        dispatch: RemoteSafetyDispatch,
        titleKey: String,
        bodyKey: String
    ) async -> Bool {
        let defaults = UserDefaults.standard
        let previous = Self.persistedStatusNotificationMarker(defaults: defaults)
        let candidate = StatusNotificationMarker(
            dispatchId: dispatch.dispatchId.uuidString.lowercased(),
            status: dispatch.status.rawValue
        )
        guard previous != candidate else { return true }
        guard pendingStatusNotifications.insert(candidate).inserted else {
            return false
        }
        defer { pendingStatusNotifications.remove(candidate) }

        let posted = await postNotification(titleKey: titleKey, bodyKey: bodyKey)
        let next = Self.markerAfterNotificationAttempt(
            previous: previous,
            candidate: candidate,
            postedSuccessfully: posted
        )
        guard next == candidate else { return false }
        defaults.set(candidate.dispatchId, forKey: Self.lastNotifiedDispatchKey)
        defaults.set(candidate.status, forKey: Self.lastNotifiedStatusKey)
        return true
    }

    private static func persistedSessionExpiry(now: Date) -> Date? {
        boundedSessionExpiry(
            requested: parseISO8601(
                UserDefaults.standard.string(forKey: activeExpiryKey)
            ),
            now: now
        )
    }

    private static func persistedStatusNotificationMarker(
        defaults: UserDefaults
    ) -> StatusNotificationMarker? {
        guard let dispatchId = defaults.string(forKey: lastNotifiedDispatchKey),
              let status = defaults.string(forKey: lastNotifiedStatusKey)
        else { return nil }
        return StatusNotificationMarker(dispatchId: dispatchId, status: status)
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func postResultNotification(_ outcome: TriggerOutcome) {
        #if os(iOS)
        Task { @MainActor [weak self] in
            switch outcome {
            case .opened:
                _ = await self?.postNotification(
                    titleKey: "safety.page.status.submitted",
                    bodyKey: "safety.page.detail.submitted"
                )
            case .alreadyActive:
                _ = await self?.postNotification(
                    titleKey: "safety.page.status.open",
                    bodyKey: "safety.page.detail.waiting"
                )
            case .unavailable:
                _ = await self?.postNotification(
                    titleKey: "safety.page.status.failed",
                    bodyKey: "safety.delivery.unavailable"
                )
            }
        }
        #endif
    }

    private func postNotification(
        titleKey: String,
        bodyKey: String
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard Self.notificationsAvailable(settings.authorizationStatus) else {
            LocalNotificationLifecycle.suppressed(
                identifier: "safety-gesture-result",
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: String.LocalizationValue(titleKey))
        content.body = String(localized: String.LocalizationValue(bodyKey))
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.safety"
        content.userInfo = [
            NotificationRouteBridge.userInfoKey:
                NoopNotificationRoute.safety.rawValue,
        ]
        do {
            try await LocalNotificationLifecycle.schedule(
                UNNotificationRequest(
                    identifier: "safety-gesture-result",
                    content: content,
                    trigger: nil
                ),
                on: center
            )
            return true
        } catch {
            return false
        }
    }

    private func stopLocationUpdates(dispatchId: UUID? = nil) {
        if let dispatchId,
           UserDefaults.standard.string(forKey: Self.activeDispatchKey)
            != dispatchId.uuidString.lowercased() {
            return
        }
        #if os(iOS)
        locationStreamer.stop()
        #endif
    }

    static func notificationDeliveryAvailable() async -> Bool {
        notificationsAvailable(
            await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
        )
    }

    static func requestNotificationAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let initial = await center.notificationSettings().authorizationStatus
        if initial == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        return notificationsAvailable(
            await center.notificationSettings().authorizationStatus
        )
    }

    private static func notificationsAvailable(
        _ status: UNAuthorizationStatus
    ) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }
}

#if os(iOS)
@MainActor
private final class SafetyIncidentLocationStreamer: NSObject {
    typealias Sender = @MainActor (SafetyLocation, Int64) async throws -> Void

    private let manager = CLLocationManager()
    private var sender: Sender?
    private var dispatchId: UUID?
    private var sequence: Int64 = 0
    private var lastSubmittedAt = Date.distantPast
    private var sendTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start(
        dispatchId: UUID,
        expiresAt: Date?,
        startingSequence: Int64,
        sender: @escaping Sender
    ) {
        if self.dispatchId != dispatchId {
            sequence = max(startingSequence, 0)
            lastSubmittedAt = .distantPast
        } else {
            sequence = max(sequence, max(startingSequence, 0))
        }
        self.dispatchId = dispatchId
        self.sender = sender
        expiryTask?.cancel()
        let deadline = min(
            expiresAt ?? Date().addingTimeInterval(8 * 60 * 60),
            Date().addingTimeInterval(12 * 60 * 60)
        )
        expiryTask = Task { @MainActor [weak self] in
            let delay = max(deadline.timeIntervalSinceNow, 0)
            try? await Task.sleep(
                nanoseconds: UInt64(min(delay, 12 * 60 * 60) * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        startManagerIfAuthorized()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        sendTask?.cancel()
        expiryTask?.cancel()
        sendTask = nil
        expiryTask = nil
        sender = nil
        dispatchId = nil
        sequence = 0
        lastSubmittedAt = .distantPast
    }

    private func startManagerIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
        case .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = false
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    private func submit(_ fix: CLLocation) {
        guard sendTask == nil,
              Date().timeIntervalSince(lastSubmittedAt) >= 12,
              sequence < Int64.max,
              fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= 10_000
        else { return }
        let location = SafetyLocation(
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            horizontalAccuracyMeters: fix.horizontalAccuracy,
            capturedAtUnix: Int(fix.timestamp.timeIntervalSince1970)
        )
        guard location.isUsable(atUnix: Int(Date().timeIntervalSince1970)),
              let sender
        else { return }

        sequence += 1
        let submittedSequence = sequence
        lastSubmittedAt = Date()
        sendTask = Task { @MainActor [weak self] in
            defer { self?.sendTask = nil }
            do {
                try await sender(location, submittedSequence)
            } catch let RemoteSyncError.server(status, _) where
                [401, 404, 409, 410].contains(status) {
                self?.stop()
            } catch {
                // Temporary failures keep the session active. A fresh fix retries with a new sequence.
            }
        }
    }
}

extension SafetyIncidentLocationStreamer:
    @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startManagerIfAuthorized()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let fix = locations
            .filter({ $0.horizontalAccuracy >= 0 })
            .max(by: { $0.timestamp < $1.timestamp })
        else { return }
        submit(fix)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied {
            manager.stopUpdatingLocation()
        }
    }
}
#endif
