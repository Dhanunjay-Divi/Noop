import Foundation
import StrandAnalytics

/// The machine-readable tie between a strap log and the test profile that produced it: meta.json,
/// schema v1 (spec section 5.1). Folds in build-provenance and the storage / DB-size block so a
/// maintainer sees the version, channel, signing and on-disk footprint without asking. snake_case
/// wire keys match the spec JSON sample; sortedKeys keeps the Swift and Kotlin output byte-aligned.
struct TestBundleMeta: Codable {
    let schema: Int                    // always 1
    let appVersion: String
    let appBuild: String?              // CFBundleVersion; disambiguates TestFlight/sideload rebuilds
    let platform: String               // "iOS" | "macOS" | "Android"
    let osVersion: String
    let deviceHardware: String?        // e.g. iPhone16,2; nil off iOS
    let strapModel: String?
    let strapFirmware: String?
    let deviceFamily: String?          // whoop4 | whoop5
    let deviceVariant: String?         // attested 5.0/MG variant when available
    let source: [String]               // e.g. ["Live Bluetooth"]
    let testProfile: String            // TestDomain.id
    let profileStartedAt: String?      // ISO8601, from TestCentre.startedAt
    let captureStartedAt: String?      // explicit alias for analysis tooling
    let captureEndedAt: String?        // report assembly instant (end of captured interval)
    let questionnaire: [String: String]
    let build: Build
    let capabilities: Capabilities?
    let storage: Storage
    let redaction: String              // "v2"
    let truncated: Bool
    /// The report-completeness guard result (#812, generalised): per ACTIVE domain, OK (its killer trace
    /// landed, with a count) or INCOMPLETE (the mode was on but produced no trace). Empty on a non-test
    /// export. Lets a maintainer see at a glance, from meta alone, that a report is thin and WHICH capture
    /// failed. Built by CaptureCompleteness.evaluate over the redacted report.txt.
    var captureCheck: [CaptureCheck] = []

    /// channel: one of AltStore / App Store / TestFlight / brew / GitHub / sideload. signed is false on
    /// the sideloaded iOS path; derived from IOSDiagnostics.isSideloaded on iOS, fixed per flavour else.
    struct Build: Codable { let channel: String; let signed: Bool }

    /// Runtime proof of what this particular installed build can actually use. Declared project settings
    /// are not enough for a re-signed IPA: its provisioning profile may strip HealthKit/background delivery
    /// or redirect the App Group. Optional fields keep the same schema meaningful on non-iOS platforms.
    struct Capabilities: Codable {
        let healthKitEntitled: Bool?
        let healthKitBackgroundDeliveryEntitled: Bool?
        let appGroupIdentifier: String?
        let appGroupContainerAvailable: Bool?
        let bluetoothCentralBackgroundMode: Bool?
        let locationBackgroundMode: Bool?
        let backgroundFetchMode: Bool?
        let protectedDataAvailable: Bool?
        let backgroundRefresh: String?

        init(healthKitEntitled: Bool? = nil,
             healthKitBackgroundDeliveryEntitled: Bool? = nil,
             appGroupIdentifier: String? = nil,
             appGroupContainerAvailable: Bool? = nil,
             bluetoothCentralBackgroundMode: Bool? = nil,
             locationBackgroundMode: Bool? = nil,
             backgroundFetchMode: Bool? = nil,
             protectedDataAvailable: Bool? = nil,
             backgroundRefresh: String? = nil) {
            self.healthKitEntitled = healthKitEntitled
            self.healthKitBackgroundDeliveryEntitled = healthKitBackgroundDeliveryEntitled
            self.appGroupIdentifier = appGroupIdentifier
            self.appGroupContainerAvailable = appGroupContainerAvailable
            self.bluetoothCentralBackgroundMode = bluetoothCentralBackgroundMode
            self.locationBackgroundMode = locationBackgroundMode
            self.backgroundFetchMode = backgroundFetchMode
            self.protectedDataAvailable = protectedDataAvailable
            self.backgroundRefresh = backgroundRefresh
        }

        enum CodingKeys: String, CodingKey {
            case backgroundRefresh = "background_refresh"
            case backgroundFetchMode = "background_fetch_mode"
            case bluetoothCentralBackgroundMode = "bluetooth_central_background_mode"
            case locationBackgroundMode = "location_background_mode"
            case protectedDataAvailable = "protected_data_available"
            case healthKitEntitled = "healthkit_entitled"
            case healthKitBackgroundDeliveryEntitled = "healthkit_background_delivery_entitled"
            case appGroupIdentifier = "app_group_identifier"
            case appGroupContainerAvailable = "app_group_container_available"
        }
    }

    /// db_bytes plus per-table row counts plus the raw-capture footprint (#590 asked us to surface this).
    struct Storage: Codable {
        let dbBytes: Int; let rows: [String: Int]; let rawCaptureBytes: Int
        enum CodingKeys: String, CodingKey {
            case rows
            case dbBytes = "db_bytes", rawCaptureBytes = "raw_capture_bytes"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema, platform, source, questionnaire, build, storage, redaction, truncated
        case appVersion = "app_version", appBuild = "app_build"
        case osVersion = "os_version", deviceHardware = "device_hardware"
        case strapModel = "strap_model", strapFirmware = "strap_firmware"
        case deviceFamily = "device_family", deviceVariant = "device_variant"
        case testProfile = "test_profile", profileStartedAt = "profile_started_at"
        case captureStartedAt = "capture_started_at", captureEndedAt = "capture_ended_at"
        case capabilities
        case captureCheck = "capture_check"
    }

    func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }
}
