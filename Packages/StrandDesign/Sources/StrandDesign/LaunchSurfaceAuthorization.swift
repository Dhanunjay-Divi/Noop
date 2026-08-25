import Foundation

/// Non-secret, cross-process presentation authorization for NOOP's embedded surfaces.
///
/// The iPhone launch gate owns the actual unlock decision. After that decision succeeds, the app may
/// publish this tiny receipt into its App Group; widgets and Live Activities only render private data
/// when the receipt exactly matches the gate policy embedded in their own bundle. The watch receives
/// the same three fields inside `WatchScoreSnapshot`, because an iPhone and a Watch do not share one
/// physical UserDefaults container across devices.
///
/// This is intentionally not a password or health-data encryption boundary. It never contains the
/// launch verifier, salt, candidate code, or a derivative of them. Its job is narrower: make every
/// user-facing extension fail closed before the companion app has authorized the current gate version.
public struct LaunchSurfaceAuthorization: Codable, Equatable, Sendable {
    public static let requiredInfoKey = "NOOPLaunchGateRequired"
    public static let versionInfoKey = "NOOPLaunchGateVersion"
    public static let appGroupInfoKey = "AppGroupIdentifier"
    public static let storageKey = "noop.launchSurface.authorization"

    public var required: Bool
    public var gateVersion: String?
    public var authorized: Bool

    public init(required: Bool, gateVersion: String?, authorized: Bool) {
        self.required = required
        self.gateVersion = Self.normalizedVersion(gateVersion)
        self.authorized = authorized
    }

    /// The policy an individual process was built with. A required gate without a usable version is
    /// invalid and therefore denied; a malformed required flag is also invalid rather than silently
    /// becoming an ungated build.
    public enum Requirement: Equatable, Sendable {
        case notRequired
        case required(version: String)
        case invalid
    }

    public static func requirement(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> Requirement {
        switch parsedRequiredFlag(infoDictionary[requiredInfoKey]) {
        case .notPresent, .value(false):
            return .notRequired
        case .invalid:
            return .invalid
        case .value(true):
            guard let version = normalizedVersion(infoDictionary[versionInfoKey] as? String) else {
                return .invalid
            }
            return .required(version: version)
        }
    }

    /// Whether this receipt opens a consumer built with `requirement`. Exact version equality is
    /// deliberate: rotating the iPhone gate immediately makes every old cache and Watch payload deny.
    public func authorizes(_ requirement: Requirement) -> Bool {
        switch requirement {
        case .notRequired:
            return true
        case .invalid:
            return false
        case .required(let expectedVersion):
            return required
                && authorized
                && gateVersion == expectedVersion
        }
    }

    /// Load and validate the App Group receipt for the current process. Required consumers default to
    /// false for an absent App Group entitlement, an absent receipt, corrupt bytes, or a version mismatch.
    public static func isAuthorized(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        defaults: UserDefaults? = nil
    ) -> Bool {
        let expected = requirement(infoDictionary: infoDictionary)
        if expected == .notRequired { return true }
        guard expected != .invalid,
              let store = defaults ?? sharedDefaults(infoDictionary: infoDictionary),
              let data = store.data(forKey: storageKey),
              let receipt = try? JSONDecoder().decode(Self.self, from: data) else {
            return false
        }
        return receipt.authorizes(expected)
    }

    /// Return the receipt that should be copied into an outbound Watch snapshot. The returned value is
    /// already reduced to denied when stored state is missing, malformed, or belongs to another version.
    public static func current(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        defaults: UserDefaults? = nil
    ) -> Self {
        let expected = requirement(infoDictionary: infoDictionary)
        switch expected {
        case .notRequired:
            return Self(required: false, gateVersion: nil, authorized: true)
        case .invalid:
            return Self(required: true, gateVersion: nil, authorized: false)
        case .required(let version):
            guard let store = defaults ?? sharedDefaults(infoDictionary: infoDictionary),
                  let data = store.data(forKey: storageKey),
                  let receipt = try? JSONDecoder().decode(Self.self, from: data),
                  receipt.authorizes(expected) else {
                return Self(required: true, gateVersion: version, authorized: false)
            }
            return Self(required: true, gateVersion: version, authorized: true)
        }
    }

    /// Publish an authorization only after the iPhone launch controller has accepted the user. The
    /// caller supplies the already-resolved non-secret version; unusable versions are rejected and any
    /// prior receipt is removed so a programming/configuration error cannot leave extensions open.
    @discardableResult
    public static func publishAuthorized(
        gateVersion: String,
        required: Bool = true,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        defaults: UserDefaults? = nil
    ) -> Bool {
        guard let store = defaults ?? sharedDefaults(infoDictionary: infoDictionary) else { return false }
        let version = normalizedVersion(gateVersion)
        guard !required || version != nil else {
            store.removeObject(forKey: storageKey)
            return false
        }
        let receipt = Self(required: required, gateVersion: required ? version : nil, authorized: true)
        guard let data = try? JSONEncoder().encode(receipt) else {
            store.removeObject(forKey: storageKey)
            return false
        }
        store.set(data, forKey: storageKey)
        return true
    }

    /// Convenience for app-side integration after a successful unlock. It publishes only when the
    /// current bundle has a coherent policy; invalid required configuration clears and denies.
    @discardableResult
    public static func publishAuthorizedForCurrentBundle(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        defaults: UserDefaults? = nil
    ) -> Bool {
        switch requirement(infoDictionary: infoDictionary) {
        case .notRequired:
            return publishAuthorized(
                gateVersion: "ungated",
                required: false,
                infoDictionary: infoDictionary,
                defaults: defaults
            )
        case .required(let version):
            return publishAuthorized(
                gateVersion: version,
                required: true,
                infoDictionary: infoDictionary,
                defaults: defaults
            )
        case .invalid:
            clear(infoDictionary: infoDictionary, defaults: defaults)
            return false
        }
    }

    /// Remove extension authorization. App startup should call this whenever the iPhone launch state is
    /// locked or invalid, before starting work that could publish fresh cached metrics.
    public static func clear(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        defaults: UserDefaults? = nil
    ) {
        (defaults ?? sharedDefaults(infoDictionary: infoDictionary))?
            .removeObject(forKey: storageKey)
    }

    private enum ParsedRequiredFlag {
        case notPresent
        case value(Bool)
        case invalid
    }

    private static func parsedRequiredFlag(_ raw: Any?) -> ParsedRequiredFlag {
        guard let raw else { return .notPresent }
        // Property-list booleans bridge through NSNumber, so handle the numeric representation first
        // and accept only its two canonical values. `boolValue` alone would incorrectly turn 2 into true.
        if let number = raw as? NSNumber {
            if number.doubleValue == 0 { return .value(false) }
            if number.doubleValue == 1 { return .value(true) }
            return .invalid
        }
        if let value = raw as? Bool { return .value(value) }
        guard let string = raw as? String else { return .invalid }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1": return .value(true)
        case "no", "false", "0", "": return .value(false)
        default: return .invalid
        }
    }

    private static func normalizedVersion(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("$(") else { return nil }
        return value
    }

    private static func sharedDefaults(infoDictionary: [String: Any]) -> UserDefaults? {
        guard let suite = resolveAppGroupIdentifier(infoDictionary: infoDictionary) else { return nil }
        return UserDefaults(suiteName: suite)
    }

    /// Mirrors the existing widget App Group resolution, including AltStore/SideStore's suffixed group.
    private static func resolveAppGroupIdentifier(infoDictionary: [String: Any]) -> String? {
        let configured = (infoDictionary[appGroupInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let provisioned = (infoDictionary["ALTAppGroups"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("group.") && !$0.isEmpty } ?? []
        if let configured, !configured.isEmpty,
           let match = provisioned.first(where: { $0 == configured || $0.hasPrefix(configured + ".") }) {
            return match
        }
        if provisioned.count == 1 { return provisioned[0] }
        if let configured, configured.hasPrefix("group."), !configured.isEmpty { return configured }
        return nil
    }
}
