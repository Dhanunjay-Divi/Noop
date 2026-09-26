import CoreFoundation
import Foundation

struct VeepooBandProductIdentity: Equatable, Hashable, Sendable {
    let modelCode: String
    let hardwareRevision: String
    let firmwareRevision: String
}

enum VeepooBandCompatibilityDecision: Equatable, Sendable {
    case approved
    case qualificationApproved
    case invalidManifest
    case invalidIdentity
    case notApproved
}

enum VeepooBandCompatibilityManifestError: Error, Equatable {
    case oversized
    case malformed
    case invalidTopLevel
    case invalidSchema
    case invalidApprovedBands
    case invalidRow
    case duplicateRow
}

struct VeepooBandCompatibilityPolicy: Sendable {
    static let schemaVersion = 1
    static let applePlatform = "apple"
    static let protocolVersion = "noop-band-v1"
    static let wrapperRevision = "veepoo-apple-display-v1"
    private static let supportedWrapperByPlatform = [
        "android": "veepoo-android-display-v2",
        "apple": wrapperRevision,
    ]

    private static let resourceName = "noop-band-compatibility"
    private static let maximumManifestBytes = 65_536
    private static let maximumApprovedBands = 256
    private static let maximumFieldBytes = 64
    private static let rejectedPlaceholders = Set([
        "all",
        "any",
        "default",
        "unknown",
    ])
    private static let topLevelKeys = Set([
        "schemaVersion",
        "approvedBands",
    ])
    private static let rowKeys = Set([
        "platform",
        "modelCode",
        "hardwareRevision",
        "firmwareRevision",
        "protocolVersion",
        "wrapperRevision",
    ])

    private struct ApprovedBand: Equatable, Hashable, Sendable {
        let platform: String
        let modelCode: String
        let hardwareRevision: String
        let firmwareRevision: String
        let protocolVersion: String
        let wrapperRevision: String
    }

    private let approvedBands: Set<ApprovedBand>?
    private let allowsUnlistedQualification: Bool

    init(
        validatingManifestData data: Data,
        allowsUnlistedQualification: Bool = false
    ) throws {
        guard data.count <= Self.maximumManifestBytes else {
            throw VeepooBandCompatibilityManifestError.oversized
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let manifest = object as? [String: Any]
        else {
            throw VeepooBandCompatibilityManifestError.malformed
        }
        guard Set(manifest.keys) == Self.topLevelKeys else {
            throw VeepooBandCompatibilityManifestError.invalidTopLevel
        }
        guard Self.validSchemaVersion(manifest["schemaVersion"]) else {
            throw VeepooBandCompatibilityManifestError.invalidSchema
        }
        guard let rows = manifest["approvedBands"] as? [Any],
              rows.count <= Self.maximumApprovedBands
        else {
            throw VeepooBandCompatibilityManifestError.invalidApprovedBands
        }

        var parsed = Set<ApprovedBand>()
        parsed.reserveCapacity(rows.count)
        for rawRow in rows {
            guard let row = rawRow as? [String: Any],
                  Set(row.keys) == Self.rowKeys,
                  let platform = Self.validField(row["platform"]),
                  let modelCode = Self.validField(row["modelCode"]),
                  let hardwareRevision =
                    Self.validField(row["hardwareRevision"]),
                  let firmwareRevision =
                    Self.validField(row["firmwareRevision"]),
                  let protocolVersion =
                    Self.validField(row["protocolVersion"]),
                  let wrapperRevision =
                    Self.validField(row["wrapperRevision"]),
                  protocolVersion == Self.protocolVersion,
                  Self.supportedWrapperByPlatform[platform]
                    == wrapperRevision
            else {
                throw VeepooBandCompatibilityManifestError.invalidRow
            }
            let approvedBand = ApprovedBand(
                platform: platform,
                modelCode: modelCode,
                hardwareRevision: hardwareRevision,
                firmwareRevision: firmwareRevision,
                protocolVersion: protocolVersion,
                wrapperRevision: wrapperRevision
            )
            guard parsed.insert(approvedBand).inserted else {
                throw VeepooBandCompatibilityManifestError.duplicateRow
            }
        }
        approvedBands = parsed
        self.allowsUnlistedQualification = allowsUnlistedQualification
    }

    static func loadFromMainBundle(
        _ bundle: Bundle = .main,
        allowsUnlistedQualification: Bool = false
    ) -> Self {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: url, options: .mappedIfSafe),
        let policy = try? Self(
            validatingManifestData: data,
            allowsUnlistedQualification: allowsUnlistedQualification
        )
        else {
            return Self(
                approvedBands: nil,
                allowsUnlistedQualification: false
            )
        }
        return policy
    }

    static func rejectingInvalidManifest() -> Self {
        Self(
            approvedBands: nil,
            allowsUnlistedQualification: false
        )
    }

    func decision(
        for identity: VeepooBandProductIdentity
    ) -> VeepooBandCompatibilityDecision {
        guard let approvedBands else { return .invalidManifest }
        guard Self.validField(identity.modelCode) != nil,
              Self.validField(identity.hardwareRevision) != nil,
              Self.validField(identity.firmwareRevision) != nil
        else {
            return .invalidIdentity
        }
        let candidate = ApprovedBand(
            platform: Self.applePlatform,
            modelCode: identity.modelCode,
            hardwareRevision: identity.hardwareRevision,
            firmwareRevision: identity.firmwareRevision,
            protocolVersion: Self.protocolVersion,
            wrapperRevision: Self.wrapperRevision
        )
        if approvedBands.contains(candidate) {
            return .approved
        }
        if !approvedBands.contains(where: {
            $0.platform == Self.applePlatform
        }) && allowsUnlistedQualification {
            return .qualificationApproved
        }
        return .notApproved
    }

    private init(
        approvedBands: Set<ApprovedBand>?,
        allowsUnlistedQualification: Bool
    ) {
        self.approvedBands = approvedBands
        self.allowsUnlistedQualification = allowsUnlistedQualification
    }

    private static func validSchemaVersion(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return false
        }
        let type = String(cString: number.objCType)
        guard type != "f", type != "d" else { return false }
        return number.intValue == schemaVersion
            && number.doubleValue == Double(schemaVersion)
    }

    private static func validField(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.utf8.count <= maximumFieldBytes,
              value.trimmingCharacters(in: .whitespaces) == value,
              !value.trimmingCharacters(in: .whitespaces).isEmpty,
              value.unicodeScalars.allSatisfy({
                  (0x20...0x7E).contains($0.value)
              }),
              !value.contains("*"),
              !value.contains("?"),
              !rejectedPlaceholders.contains(value.lowercased())
        else {
            return nil
        }
        return value
    }
}
