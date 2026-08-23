import CoreLocation
import Foundation
import StrandAnalytics

/// One-shot, user-requested location capture for the manual Safety Center.
///
/// This deliberately does not run in the background, track a route, or infer an emergency. The user
/// taps "Get current location", Core Location returns one fix, and the screen may place that fix in a
/// message that still has to be shared and sent through the operating system.
@MainActor
final class SafetyLocationProvider: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case requesting
        case ready
        case denied
        case unavailable
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var location: SafetyLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    func requestCurrentLocation() {
        location = nil
        guard CLLocationManager.locationServicesEnabled() else {
            state = .unavailable
            return
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            beginRequest()
        case .notDetermined:
            state = .requesting
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .failed
        }
    }

    func clear() {
        location = nil
        state = .idle
    }

    var hasBackgroundAuthorization: Bool {
        authorizationStatus == .authorizedAlways
    }

    #if os(iOS)
    func requestBackgroundAuthorization() {
        authorizationStatus = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            Task { @MainActor in
                await SafetySOSRuntime.shared.restoreLocationSharingIfNeeded()
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .failed
        }
    }
    #endif

    private func beginRequest() {
        state = .requesting
        manager.requestLocation()
    }
}

// The manager is created on the main actor and delivers callbacks on that run loop. `@preconcurrency`
// bridges Core Location's older nonisolated delegate declaration without weakening this object's UI state.
extension SafetyLocationProvider: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if state == .requesting { beginRequest() }
            Task { @MainActor in
                await SafetySOSRuntime.shared.restoreLocationSharingIfNeeded()
            }
        case .denied, .restricted:
            location = nil
            state = .denied
        case .notDetermined:
            break
        @unknown default:
            location = nil
            state = .failed
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations
            .filter({ $0.horizontalAccuracy >= 0 })
            .max(by: { $0.timestamp < $1.timestamp })
        else {
            location = nil
            state = .failed
            return
        }

        let candidate = SafetyLocation(
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            horizontalAccuracyMeters: fix.horizontalAccuracy,
            capturedAtUnix: Int(fix.timestamp.timeIntervalSince1970)
        )
        guard candidate.isUsable(atUnix: Int(Date().timeIntervalSince1970)) else {
            location = nil
            state = .failed
            return
        }
        location = candidate
        state = .ready
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        location = nil
        state = (error as? CLError)?.code == .denied ? .denied : .failed
    }
}
