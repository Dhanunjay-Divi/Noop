#if os(iOS)
import CoreLocation
import Foundation
import WeatherKit

/// One-shot current conditions for Today's header.
///
/// Location is requested only after the person enables weather from the header. A coarse fix is sent to
/// Apple Weather, the resulting conditions are cached locally, and no route or location history is stored.
@MainActor
final class TodayWeatherStore: NSObject, ObservableObject {
    static let enabledKey = "today.weather.enabled"

    struct Snapshot: Codable, Equatable {
        let temperatureC: Double
        let symbolName: String
        let condition: String
        let observedAt: Date
    }

    enum Status: Equatable {
        case idle
        case locating
        case ready
        case denied
        case unavailable
        case failed
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var status: Status = .idle
    @Published private(set) var attributionURL =
        URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    private static let cacheKey = "today.weather.snapshot.v1"
    private static let cacheLifetime: TimeInterval = 2 * 60 * 60
    private let manager = CLLocationManager()
    private var shouldContinueAfterAuthorization = false
    private var requestInFlight = false

    override init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(Snapshot.self, from: data),
           Date().timeIntervalSince(cached.observedAt) < Self.cacheLifetime {
            snapshot = cached
            status = .ready
        }
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func startIfEnabled(_ enabled: Bool) {
        #if DEBUG
        if CommandLine.arguments.contains("--demo-seed") {
            snapshot = Snapshot(
                temperatureC: 22,
                symbolName: "cloud.sun.fill",
                condition: String(localized: "Partly cloudy"),
                observedAt: Date()
            )
            status = .ready
            return
        }
        #endif

        guard enabled else {
            if snapshot == nil { status = .idle }
            return
        }
        refresh(requestAuthorization: false)
    }

    func enableAndRefresh() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        refresh(requestAuthorization: true)
    }

    func refresh(requestAuthorization: Bool = false) {
        guard !requestInFlight else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            status = .unavailable
            return
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocation()
        case .notDetermined:
            guard requestAuthorization else {
                status = snapshot == nil ? .idle : .ready
                return
            }
            shouldContinueAfterAuthorization = true
            status = .locating
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .failed
        }
    }

    private func requestLocation() {
        requestInFlight = true
        status = .locating
        manager.requestLocation()
    }

    private func fetchWeather(for location: CLLocation) {
        Task {
            defer { requestInFlight = false }
            do {
                let weather = try await WeatherService.shared.weather(for: location)
                if let attribution = try? await WeatherService.shared.attribution {
                    attributionURL = attribution.legalPageURL
                }
                let current = weather.currentWeather
                let next = Snapshot(
                    temperatureC: current.temperature.converted(to: .celsius).value,
                    symbolName: current.symbolName,
                    condition: current.condition.description,
                    observedAt: current.date
                )
                snapshot = next
                status = .ready
                if let data = try? JSONEncoder().encode(next) {
                    UserDefaults.standard.set(data, forKey: Self.cacheKey)
                }
            } catch {
                status = snapshot == nil ? .failed : .ready
            }
        }
    }
}

extension TodayWeatherStore: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if shouldContinueAfterAuthorization {
                shouldContinueAfterAuthorization = false
                requestLocation()
            }
        case .denied, .restricted:
            shouldContinueAfterAuthorization = false
            requestInFlight = false
            status = .denied
        case .notDetermined:
            break
        @unknown default:
            shouldContinueAfterAuthorization = false
            requestInFlight = false
            status = .failed
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations
            .filter({ $0.horizontalAccuracy >= 0 })
            .max(by: { $0.timestamp < $1.timestamp })
        else {
            requestInFlight = false
            status = snapshot == nil ? .failed : .ready
            return
        }
        fetchWeather(for: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        requestInFlight = false
        status = (error as? CLError)?.code == .denied
            ? .denied
            : (snapshot == nil ? .failed : .ready)
    }
}
#endif
