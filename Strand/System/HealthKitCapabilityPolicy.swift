import Foundation

/// Determines whether the running distribution can use a declared HealthKit capability without
/// calling HealthKit APIs that raise an Objective-C exception when the entitlement is absent.
enum HealthKitCapabilityPolicy {
    static func allows(
        entitlement key: String,
        embeddedProvisioningProfile data: Data?,
        hasAppStoreReceipt: Bool
    ) -> Bool {
        // App Store and TestFlight remove the embedded profile but install a receipt. A profile-less,
        // receipt-less process is a local/unsigned build and must fail closed.
        guard let data else { return hasAppStoreReceipt }
        guard let entitlements = entitlements(in: data) else { return false }
        if let enabled = entitlements[key] as? Bool { return enabled }
        if let enabled = entitlements[key] as? NSNumber { return enabled.boolValue }
        return false
    }

    private static func entitlements(in profile: Data) -> [String: Any]? {
        guard let xmlStart = profile.range(of: Data("<?xml".utf8)),
              let xmlEnd = profile.range(of: Data("</plist>".utf8)) else { return nil }
        let plistData = profile.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }
}
