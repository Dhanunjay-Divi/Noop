import Foundation

/// Small, Codable glance snapshot shared between the iOS app and its widget/Live-Activity extension
/// via an App Group. The app writes it; the widget reads it. Keeping it tiny avoids any cross-process
/// database access — the widget never opens SQLite.
public struct WidgetSnapshot: Codable, Equatable {
    public var recovery: Int?    // Charge (0–100)
    public var bpm: Int?
    public var batteryPct: Int?
    public var bonded: Bool
    public var updated: Date
    // Richer glance fields (#446). All OPTIONAL with nil defaults so a snapshot written by an OLDER app
    // build (which never encoded these keys) still decodes — Codable fills a missing optional with nil.
    public var effort: Int?      // Effort / strain on NOOP's 0–100 axis
    public var rest: Int?        // Rest (sleep_performance) score, 0–100
    public var hrv: Int?         // HRV (ms), whole-number for the glance
    public var restingHr: Int?   // Resting heart rate (bpm)
    public var sleepMinutes: Int? // Main-sleep duration for the score day
    /// `connected` is deliberately separate from `bonded`: a paired band is not necessarily live.
    /// Optional keeps snapshots written by an older app build decodable without inventing a state.
    public var connected: Bool?
    /// Logical day represented by the daily scores (`yyyy-MM-dd`). This prevents a carried prior-day
    /// score from being labelled as today's measurement around the overnight rollover.
    public var scoreDay: String?

    public init(recovery: Int?, bpm: Int?, batteryPct: Int?, bonded: Bool, updated: Date,
                effort: Int? = nil, rest: Int? = nil, hrv: Int? = nil, restingHr: Int? = nil,
                sleepMinutes: Int? = nil, connected: Bool? = nil, scoreDay: String? = nil) {
        self.recovery = recovery
        self.bpm = bpm
        self.batteryPct = batteryPct
        self.bonded = bonded
        self.updated = updated
        self.effort = effort
        self.rest = rest
        self.hrv = hrv
        self.restingHr = restingHr
        self.sleepMinutes = sleepMinutes
        self.connected = connected
        self.scoreDay = scoreDay
    }

    /// App Group suite the app and widget both use. Injected from the `APP_GROUP_ID` build setting
    /// (see project.yml) via the `AppGroupIdentifier` Info.plist key, so the value lives in exactly
    /// one place rather than being duplicated here. Must match the `com.apple.security.application-groups`
    /// entitlement on both targets (which also reads `$(APP_GROUP_ID)`). If the entitlement is missing on
    /// either side, `UserDefaults(suiteName:)` returns nil and every consumer (PendingIntents,
    /// WidgetSnapshot.publish, Live Activity) silently no-ops — see `assertGroupProvisioned` for the
    /// debug-time canary. The fallback is the canonical upstream group and only applies if the Info.plist
    /// key is somehow absent (each process reads its OWN bundle, so the app and the widget extension
    /// each carry the key in their generated Info.plist).
    public static let suiteName: String = {
        resolveSuiteName(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }()
    public static let storageKey = "noop.widget.snapshot"

    /// AltStore/SideStore append the signing team to requested App Groups and expose the actually
    /// provisioned identifiers in `ALTAppGroups`. Prefer that runtime value so host and widget share
    /// a real container after re-signing; ordinary Xcode builds retain the configured group.
    static func resolveSuiteName(infoDictionary: [String: Any]) -> String {
        let configured = (infoDictionary["AppGroupIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let provisioned = (infoDictionary["ALTAppGroups"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("group.") && !$0.isEmpty } ?? []
        if let configured, !configured.isEmpty,
           let match = provisioned.first(where: { $0 == configured || $0.hasPrefix(configured + ".") }) {
            return match
        }
        if provisioned.count == 1, let only = provisioned.first { return only }
        if let configured, !configured.isEmpty { return configured }
        return "group.com.noopapp.noop"
    }

    /// Debug-only canary: trips on the first run after a misprovisioning so the silent no-op gets
    /// caught immediately rather than masquerading as "widget shows nothing yet." Release builds do
    /// nothing — App Store apps can't crash on a missing entitlement.
    public static func assertGroupProvisioned() {
        assert(UserDefaults(suiteName: suiteName) != nil,
               "App Group '\(suiteName)' not provisioned on this target — check the entitlement.")
    }

    public static var placeholder: WidgetSnapshot {
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: Date(),
                       effort: 42, rest: 81, hrv: 64, restingHr: 52,
                       sleepMinutes: 462, connected: true,
                       scoreDay: Self.dayFormatter.string(from: Date()))
    }

    /// Honest runtime fallback; sample numbers are reserved for gallery previews.
    static var unavailable: WidgetSnapshot {
        WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: .distantPast)
    }

    /// Read the last-published snapshot from the shared suite, if any.
    public static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist this snapshot into the shared suite.
    public func save() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: WidgetSnapshot.storageKey)
    }

    /// Compact, deterministic freshness buckets shared by every widget family. The snapshot timestamp
    /// is the app's last successful publication, not a claim that every daily metric was measured then.
    public enum Freshness: Equatable {
        case current, recent, stale, unavailable
    }

    public func freshness(at now: Date = Date()) -> Freshness {
        guard updated != .distantPast else { return .unavailable }
        let age = max(0, now.timeIntervalSince(updated))
        if age <= 20 * 60 { return .current }
        if age <= 2 * 60 * 60 { return .recent }
        return .stale
    }

    public var hasDailySignal: Bool {
        recovery != nil || effort != nil || rest != nil
    }

    public var hasVitals: Bool {
        bpm != nil || hrv != nil || restingHr != nil
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Appearance hand-off for the widget extension, which runs in a separate process and therefore
/// cannot see the app's ordinary `@AppStorage`. Keep the raw value string-based so this shared file
/// remains independent of StrandDesign in the app, widget, and unit-test targets.
public enum WidgetAppearancePreference {
    public static let storageKey = "theme.appearance"

    public static func load() -> String {
        UserDefaults(suiteName: WidgetSnapshot.suiteName)?.string(forKey: storageKey) ?? "system"
    }

    public static func save(_ rawValue: String) {
        UserDefaults(suiteName: WidgetSnapshot.suiteName)?.set(rawValue, forKey: storageKey)
    }
}

/// The three supporting measurements shown beside the Daily Signal scores. This is deliberately an
/// app-wide preference rather than a per-widget App Intent: a user can make one clear choice inside NOOP,
/// every already-placed widget updates immediately, and the extension stays compatible with sideloaded
/// builds where configurable-widget intents are not always provisioned reliably.
public enum WidgetMetric: String, CaseIterable, Codable, Equatable {
    case heartRate
    case hrv
    case restingHeartRate
    case sleepDuration
    case deviceBattery
}

/// App Group hand-off for the Daily Signal widget's supporting measurements. The score row is fixed to
/// Recovery / Effort / Sleep so it remains a stable daily summary; these preferences customize only the
/// three detail rows and therefore can never duplicate a headline score.
public enum WidgetMetricPreference {
    public static let storageKey = "noop.widget.supportingMetrics"
    public static let slotCount = 3
    public static let defaultSelection: [WidgetMetric] = [.heartRate, .sleepDuration, .deviceBattery]

    /// Resolve corrupt, old, duplicated, or partially-written preferences into exactly three unique
    /// supported metrics. Valid user choices keep their order; defaults fill any gaps deterministically.
    public static func normalized(_ rawValues: [String]) -> [WidgetMetric] {
        var result: [WidgetMetric] = []
        for raw in rawValues {
            guard let metric = WidgetMetric(rawValue: raw), !result.contains(metric) else { continue }
            result.append(metric)
            if result.count == slotCount { return result }
        }
        for metric in defaultSelection + WidgetMetric.allCases where !result.contains(metric) {
            result.append(metric)
            if result.count == slotCount { break }
        }
        return result
    }

    public static func load(defaults: UserDefaults? = UserDefaults(suiteName: WidgetSnapshot.suiteName)) -> [WidgetMetric] {
        normalized(defaults?.stringArray(forKey: storageKey) ?? [])
    }

    public static func save(_ metrics: [WidgetMetric],
                            defaults: UserDefaults? = UserDefaults(suiteName: WidgetSnapshot.suiteName)) {
        defaults?.set(normalized(metrics.map(\.rawValue)).map(\.rawValue), forKey: storageKey)
    }
}

/// Stable app routes used by every widget's tap target. Keeping parsing beside the snapshot makes the
/// extension and app agree on one URL contract while remaining independent of the app-only `NavRouter`.
public enum NOOPWidgetDestination: String, CaseIterable {
    case today
    case trends
    case sleep
    case live

    public var url: URL {
        // Every raw value is compile-time controlled and URL-path safe.
        URL(string: "noop://widget/\(rawValue)")!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "noop", url.host?.lowercased() == "widget" else {
            return nil
        }
        let raw = url.pathComponents.dropFirst().first?.lowercased()
        guard let raw else { return nil }
        self.init(rawValue: raw)
    }
}
