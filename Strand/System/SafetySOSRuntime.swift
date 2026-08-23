import Foundation
import NoopRemoteSync
import StrandAnalytics
#if os(iOS)
import CoreLocation
import UserNotifications
#endif

/// Owns explicit SOS dispatch and the active incident's latest-only location session.
///
/// This never triggers from wellness metrics. A page starts only after the configured sequence of
/// physical band events or the existing manual Safety Center action.
@MainActor
final class SafetySOSRuntime {
    enum TriggerOutcome {
        case opened
        case alreadyActive
        case unavailable(String)

        var logLine: String {
            switch self {
            case .opened:
                return "SOS page opened; latest-location sharing started where permitted"
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
    private var triggerTask: Task<Void, Never>?
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

            let submitted = await service.pageAcceptedContacts()
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
        guard [.open, .acknowledged, .pending].contains(dispatch.status) else {
            stopLocationSharing(dispatchId: dispatch.dispatchId)
            return
        }
        UserDefaults.standard.set(
            dispatch.dispatchId.uuidString.lowercased(),
            forKey: Self.activeDispatchKey
        )
        UserDefaults.standard.set(
            dispatch.expiresAt ?? "",
            forKey: Self.activeExpiryKey
        )
        #if os(iOS)
        locationStreamer.start(
            dispatchId: dispatch.dispatchId,
            expiresAt: Self.parseISO8601(dispatch.expiresAt)
        ) { location, sequence in
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
        #if os(iOS)
        locationStreamer.stop()
        #endif
        UserDefaults.standard.removeObject(forKey: Self.activeDispatchKey)
        UserDefaults.standard.removeObject(forKey: Self.activeExpiryKey)
    }

    func restoreLocationSharingIfNeeded() async {
        guard let raw = UserDefaults.standard.string(forKey: Self.activeDispatchKey),
              let dispatchId = UUID(uuidString: raw)
        else { return }
        let expiresAt = Self.parseISO8601(
            UserDefaults.standard.string(forKey: Self.activeExpiryKey)
        )
        if let expiresAt, expiresAt <= Date() {
            stopLocationSharing(dispatchId: dispatchId)
            return
        }
        let service = SafetyPagingService()
        #if os(iOS)
        locationStreamer.start(
            dispatchId: dispatchId,
            expiresAt: expiresAt
        ) { location, sequence in
            _ = try await service.updateLocation(
                for: dispatchId,
                sequence: sequence,
                location: location
            )
        }
        #endif
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private func postResultNotification(_ outcome: TriggerOutcome) {
        #if os(iOS)
        let content = UNMutableNotificationContent()
        switch outcome {
        case .opened:
            content.title = String(localized: "SOS page sent")
            content.body = String(
                localized: "Your accepted contacts are being paged. Open Safety to monitor responses."
            )
        case .alreadyActive:
            content.title = String(localized: "SOS page already active")
            content.body = String(localized: "Open Safety to monitor contact responses.")
        case .unavailable:
            content.title = String(localized: "SOS page was not sent")
            content.body = String(
                localized: "Open Safety to check setup, accepted contacts, and delivery."
            )
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "safety-gesture-result",
                content: content,
                trigger: nil
            )
        )
        #endif
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
        sender: @escaping Sender
    ) {
        if self.dispatchId != dispatchId {
            sequence = 0
            lastSubmittedAt = .distantPast
        }
        self.dispatchId = dispatchId
        self.sender = sender
        expiryTask?.cancel()
        let deadline = min(
            expiresAt ?? Date().addingTimeInterval(30 * 60),
            Date().addingTimeInterval(60 * 60)
        )
        expiryTask = Task { @MainActor [weak self] in
            let delay = max(deadline.timeIntervalSinceNow, 0)
            try? await Task.sleep(
                nanoseconds: UInt64(min(delay, 60 * 60) * 1_000_000_000)
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
