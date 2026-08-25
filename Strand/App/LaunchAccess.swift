import Combine
import CommonCrypto
import Foundation
import Security

/// Build-time configuration for NOOP's temporary launch-access screen.
///
/// The submitted build contains only a one-way PBKDF2 verifier and its random salt. The access code
/// itself is never stored by NOOP. This remains a client-side distribution gate, not authentication:
/// someone who controls the binary can inspect or patch it, so no health-data security boundary may
/// depend on this type.
struct LaunchAccessConfiguration: Equatable {
    static let versionInfoKey = "NOOPLaunchGateVersion"
    static let saltInfoKey = "NOOPLaunchGateSaltHex"
    static let verifierInfoKey = "NOOPLaunchGateVerifierHex"
    static let iterationsInfoKey = "NOOPLaunchGateIterations"
    static let requiredInfoKey = "NOOPLaunchGateRequired"

    static let saltBytes = 16
    static let verifierBytes = 32
    static let minimumIterations: UInt32 = 100_000
    static let maximumIterations: UInt32 = 2_000_000

    let version: String
    let salt: Data
    let verifier: Data
    let iterations: UInt32

    enum Resolution: Equatable {
        /// An explicitly ungated policy, or a blank legacy version, removes the temporary gate
        /// without changing app identity/data.
        case disabled
        case enabled(LaunchAccessConfiguration)
        /// A required or legacy-enabled nonblank version with incomplete or unsafe verifier material
        /// must never fail open.
        case invalid
    }

    static func resolve(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> Resolution {
        let required: Bool
        if let rawRequired = infoDictionary[requiredInfoKey] {
            guard let parsedRequired = boolValue(rawRequired) else { return .invalid }
            guard parsedRequired else { return .disabled }
            required = true
        } else {
            // Preserve the legacy version-driven policy for callers and older test fixtures that do
            // not carry an explicit required flag.
            required = false
        }
        let rawVersion = stringValue(infoDictionary[versionInfoKey]) ?? ""
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return required ? .invalid : .disabled }
        guard version.count <= 128,
              !version.contains("$("),
              let saltText = stringValue(infoDictionary[saltInfoKey]),
              let verifierText = stringValue(infoDictionary[verifierInfoKey]),
              let salt = decodeHex(saltText), salt.count == saltBytes,
              let verifier = decodeHex(verifierText), verifier.count == verifierBytes,
              let iterations = uint32Value(infoDictionary[iterationsInfoKey]),
              (minimumIterations...maximumIterations).contains(iterations) else {
            return .invalid
        }
        return .enabled(Self(
            version: version,
            salt: salt,
            verifier: verifier,
            iterations: iterations
        ))
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func uint32Value(_ value: Any?) -> UInt32? {
        guard let text = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              !text.contains("$(") else { return nil }
        return UInt32(text)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        guard let text = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return nil }
        switch text {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    private static func decodeHex(_ value: String) -> Data? {
        let scalars = Array(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !scalars.isEmpty, scalars.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = hexNibble(scalars[index]),
                  let low = hexNibble(scalars[index + 1]) else { return nil }
            bytes.append((high << 4) | low)
            index += 2
        }
        return Data(bytes)
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}

enum LaunchAccessVerifier {
    static func matches(_ candidate: String, configuration: LaunchAccessConfiguration) -> Bool {
        guard var derived = derive(
            candidate,
            salt: configuration.salt,
            iterations: configuration.iterations
        ) else { return false }
        defer { derived.resetBytes(in: 0..<derived.count) }
        return constantTimeEqual(derived, configuration.verifier)
    }

    /// Internal for deterministic crypto-vector tests. The mutable UTF-8 buffer is cleared as soon as
    /// CommonCrypto returns; Swift does not promise that copies made by `String` itself are zeroizable,
    /// so callers should also keep the candidate's lifetime as short as possible.
    static func derive(_ candidate: String, salt: Data, iterations: UInt32) -> Data? {
        let supportedIterations = LaunchAccessConfiguration.minimumIterations...LaunchAccessConfiguration.maximumIterations
        guard !candidate.isEmpty,
              salt.count == LaunchAccessConfiguration.saltBytes,
              supportedIterations.contains(iterations) else { return nil }

        var passwordBytes = Data(candidate.precomposedStringWithCanonicalMapping.utf8)
        defer { passwordBytes.resetBytes(in: 0..<passwordBytes.count) }
        var derived = Data(repeating: 0, count: LaunchAccessConfiguration.verifierBytes)
        let passwordCount = passwordBytes.count
        let saltCount = salt.count
        let derivedCount = derived.count
        let status = passwordBytes.withUnsafeBytes { passwordRaw in
            salt.withUnsafeBytes { saltRaw in
                derived.withUnsafeMutableBytes { derivedRaw in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordRaw.bindMemory(to: CChar.self).baseAddress,
                        passwordCount,
                        saltRaw.bindMemory(to: UInt8.self).baseAddress,
                        saltCount,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedRaw.bindMemory(to: UInt8.self).baseAddress,
                        derivedCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            derived.resetBytes(in: 0..<derived.count)
            return nil
        }
        return derived
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

struct LaunchAccessReceipt: Codable, Equatable {
    static let currentSchema = 1
    let schema: Int
    let gateVersion: String

    init(gateVersion: String) {
        schema = Self.currentSchema
        self.gateVersion = gateVersion
    }

    var isSupported: Bool { schema == Self.currentSchema && !gateVersion.isEmpty }
}

protocol LaunchAccessReceiptStoring {
    func read() throws -> LaunchAccessReceipt?
    func save(_ receipt: LaunchAccessReceipt) throws
}

enum LaunchAccessStoreError: Error {
    case readFailed(OSStatus)
    case invalidReceipt
    case writeFailed(OSStatus)
}

/// This-device-only persistence for the successful gate version. No access code, derived verifier,
/// health record, or account identifier is written here.
struct KeychainLaunchAccessReceiptStore: LaunchAccessReceiptStoring {
    private let service: String
    private let account = "launch-gate-unlock"

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        service = "\(bundleIdentifier ?? "com.noopapp.noop").launch-access"
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() throws -> LaunchAccessReceipt? {
        var lookup = query
        lookup[kSecReturnData as String] = kCFBooleanTrue
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LaunchAccessStoreError.readFailed(status) }
        guard let data = item as? Data,
              let receipt = try? JSONDecoder().decode(LaunchAccessReceipt.self, from: data),
              receipt.isSupported else { throw LaunchAccessStoreError.invalidReceipt }
        return receipt
    }

    func save(_ receipt: LaunchAccessReceipt) throws {
        guard receipt.isSupported,
              let data = try? JSONEncoder().encode(receipt) else {
            throw LaunchAccessStoreError.invalidReceipt
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw LaunchAccessStoreError.writeFailed(addStatus)
        }
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw LaunchAccessStoreError.writeFailed(updateStatus)
        }
    }
}

@MainActor
final class LaunchAccessController: ObservableObject {
    enum State: Equatable {
        case unlocked
        case locked
        case unavailable
    }

    enum AttemptResult: Equatable {
        case accepted
        case rejected
        case persistenceFailed
        case configurationUnavailable
    }

    @Published private(set) var state: State = .locked

    private let resolution: LaunchAccessConfiguration.Resolution
    private let store: LaunchAccessReceiptStoring

    init(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        store: LaunchAccessReceiptStoring = KeychainLaunchAccessReceiptStore()
    ) {
        resolution = LaunchAccessConfiguration.resolve(infoDictionary: infoDictionary)
        self.store = store
        reload()
    }

    var isUnlocked: Bool { state == .unlocked }

    func reload() {
        switch resolution {
        case .disabled:
            state = .unlocked
        case .invalid:
            state = .unavailable
        case .enabled(let configuration):
            do {
                let receipt = try store.read()
                state = receipt?.gateVersion == configuration.version ? .unlocked : .locked
            } catch {
                state = .unavailable
            }
        }
    }

    func submit(_ candidate: String) -> AttemptResult {
        guard case .enabled(let configuration) = resolution else {
            return resolution == .disabled ? .accepted : .configurationUnavailable
        }
        guard LaunchAccessVerifier.matches(candidate, configuration: configuration) else {
            state = .locked
            return .rejected
        }
        do {
            try store.save(LaunchAccessReceipt(gateVersion: configuration.version))
            state = .unlocked
            return .accepted
        } catch {
            state = .locked
            return .persistenceFailed
        }
    }
}
