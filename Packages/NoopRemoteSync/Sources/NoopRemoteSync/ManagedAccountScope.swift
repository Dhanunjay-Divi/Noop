import Foundation

public enum ManagedAccountScopeError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidPersistedBinding
    case identityMismatch
}

public struct ManagedAccountScopeBinding: Equatable, Sendable {
    public let identityScopeHash: String
    public let dataScopeHash: String
    public let dataScopeVersion: Int
    public let requiresPersistence: Bool

    public init(
        identityScopeHash: String,
        dataScopeHash: String,
        dataScopeVersion: Int,
        requiresPersistence: Bool
    ) throws {
        guard ManagedAccountScope.isScopeHash(identityScopeHash),
              ManagedAccountScope.isScopeHash(dataScopeHash),
              (1...2).contains(dataScopeVersion) else {
            throw ManagedAccountScopeError.invalidPersistedBinding
        }
        self.identityScopeHash = identityScopeHash
        self.dataScopeHash = dataScopeHash
        self.dataScopeVersion = dataScopeVersion
        self.requiresPersistence = requiresPersistence
    }
}

public struct ManagedAccountScopeRecoveryMapping: Codable, Equatable, Sendable {
    public let bindingSchemaVersion: Int
    public let identityScopeHash: String
    public let dataScopeHash: String
    public let dataScopeVersion: Int

    public init(
        identityScopeHash: String,
        dataScopeHash: String,
        dataScopeVersion: Int,
        bindingSchemaVersion: Int = ManagedAccountScope.bindingSchemaVersion
    ) throws {
        guard bindingSchemaVersion == ManagedAccountScope.bindingSchemaVersion,
              ManagedAccountScope.isScopeHash(identityScopeHash),
              ManagedAccountScope.isScopeHash(dataScopeHash),
              (1...2).contains(dataScopeVersion) else {
            throw ManagedAccountScopeError.invalidPersistedBinding
        }
        self.bindingSchemaVersion = bindingSchemaVersion
        self.identityScopeHash = identityScopeHash
        self.dataScopeHash = dataScopeHash
        self.dataScopeVersion = dataScopeVersion
    }

    public init(binding: ManagedAccountScopeBinding) throws {
        try self.init(
            identityScopeHash: binding.identityScopeHash,
            dataScopeHash: binding.dataScopeHash,
            dataScopeVersion: binding.dataScopeVersion
        )
    }

    private enum CodingKeys: String, CodingKey {
        case bindingSchemaVersion
        case identityScopeHash
        case dataScopeHash
        case dataScopeVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identityScopeHash: values.decode(
                String.self,
                forKey: .identityScopeHash
            ),
            dataScopeHash: values.decode(
                String.self,
                forKey: .dataScopeHash
            ),
            dataScopeVersion: values.decode(
                Int.self,
                forKey: .dataScopeVersion
            ),
            bindingSchemaVersion: values.decode(
                Int.self,
                forKey: .bindingSchemaVersion
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(
            bindingSchemaVersion,
            forKey: .bindingSchemaVersion
        )
        try values.encode(identityScopeHash, forKey: .identityScopeHash)
        try values.encode(dataScopeHash, forKey: .dataScopeHash)
        try values.encode(dataScopeVersion, forKey: .dataScopeVersion)
    }
}

public struct ManagedAccountScopeRecoveryStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String) {
        precondition(!key.isEmpty)
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> ManagedAccountScopeRecoveryMapping? {
        guard let stored = defaults.object(forKey: key) else { return nil }
        guard let data = stored as? Data,
              let mapping = try? JSONDecoder().decode(
                  ManagedAccountScopeRecoveryMapping.self,
                  from: data
              ) else {
            throw ManagedAccountScopeError.invalidPersistedBinding
        }
        return mapping
    }

    @discardableResult
    public func preserve(
        _ binding: ManagedAccountScopeBinding
    ) throws -> Bool {
        let mapping = try ManagedAccountScopeRecoveryMapping(binding: binding)
        if let existing = try load() {
            guard existing.identityScopeHash == mapping.identityScopeHash else {
                throw ManagedAccountScopeError.identityMismatch
            }
            guard existing == mapping else {
                throw ManagedAccountScopeError.invalidPersistedBinding
            }
            return false
        }
        guard let data = try? JSONEncoder().encode(mapping) else {
            throw ManagedAccountScopeError.invalidPersistedBinding
        }
        defaults.set(data, forKey: key)
        return true
    }

    public func remove() {
        defaults.removeObject(forKey: key)
    }
}

public enum ManagedAccountScope {
    public static let bindingSchemaVersion = 1

    public static func legacy(uid: String) throws -> String {
        guard isIdentityComponent(uid) else {
            throw ManagedAccountScopeError.invalidIdentity
        }
        return ManagedDigest.sha256(
            Data("noop-managed-account-v1\0\(uid)".utf8)
        )
    }

    public static func identity(
        projectID: String,
        tenantID: String?,
        uid: String
    ) throws -> String {
        let tenant = tenantID ?? ""
        guard isIdentityComponent(projectID),
              isIdentityComponent(tenant, allowEmpty: true),
              isIdentityComponent(uid) else {
            throw ManagedAccountScopeError.invalidIdentity
        }
        let seed = "noop-managed-account-v2\0"
            + lengthPrefixed(projectID) + "\0"
            + lengthPrefixed(tenant) + "\0"
            + lengthPrefixed(uid)
        return ManagedDigest.sha256(Data(seed.utf8))
    }

    public static func resolve(
        projectID: String,
        tenantID: String?,
        uid: String,
        enrolledDataScopeHash: String?,
        persistedIdentityScopeHash: String?,
        persistedDataScopeVersion: Int?,
        recoveryMapping: ManagedAccountScopeRecoveryMapping? = nil
    ) throws -> ManagedAccountScopeBinding {
        let legacyScope = try legacy(uid: uid)
        let identityScope = try identity(
            projectID: projectID,
            tenantID: tenantID,
            uid: uid
        )
        let hasAnyPersistedBinding = persistedIdentityScopeHash != nil
            || persistedDataScopeVersion != nil

        let activeBinding: ManagedAccountScopeBinding?
        if hasAnyPersistedBinding {
            guard let enrolledDataScopeHash,
                  let persistedIdentityScopeHash,
                  let persistedDataScopeVersion,
                  isScopeHash(enrolledDataScopeHash),
                  isScopeHash(persistedIdentityScopeHash),
                  persistedIdentityScopeHash == identityScope else {
                if persistedIdentityScopeHash != nil,
                   persistedIdentityScopeHash != identityScope {
                    throw ManagedAccountScopeError.identityMismatch
                }
                throw ManagedAccountScopeError.invalidPersistedBinding
            }
            let expectedDataScope: String
            switch persistedDataScopeVersion {
            case 1:
                expectedDataScope = legacyScope
            case 2:
                expectedDataScope = identityScope
            default:
                throw ManagedAccountScopeError.invalidPersistedBinding
            }
            guard enrolledDataScopeHash == expectedDataScope else {
                throw ManagedAccountScopeError.invalidPersistedBinding
            }
            activeBinding = try ManagedAccountScopeBinding(
                identityScopeHash: identityScope,
                dataScopeHash: enrolledDataScopeHash,
                dataScopeVersion: persistedDataScopeVersion,
                requiresPersistence: false
            )
        } else if let enrolledDataScopeHash {
            guard isScopeHash(enrolledDataScopeHash) else {
                throw ManagedAccountScopeError.invalidPersistedBinding
            }
            if enrolledDataScopeHash == legacyScope {
                activeBinding = try ManagedAccountScopeBinding(
                    identityScopeHash: identityScope,
                    dataScopeHash: legacyScope,
                    dataScopeVersion: 1,
                    requiresPersistence: true
                )
            } else if enrolledDataScopeHash == identityScope {
                activeBinding = try ManagedAccountScopeBinding(
                    identityScopeHash: identityScope,
                    dataScopeHash: identityScope,
                    dataScopeVersion: 2,
                    requiresPersistence: true
                )
            } else {
                throw ManagedAccountScopeError.identityMismatch
            }
        } else {
            activeBinding = nil
        }

        if let activeBinding {
            if let recoveryMapping {
                let recovered = try binding(
                    from: recoveryMapping,
                    identityScope: identityScope,
                    legacyScope: legacyScope
                )
                guard recovered.dataScopeHash == activeBinding.dataScopeHash,
                      recovered.dataScopeVersion
                        == activeBinding.dataScopeVersion else {
                    throw ManagedAccountScopeError.invalidPersistedBinding
                }
            }
            return activeBinding
        }

        if let recoveryMapping {
            return try binding(
                from: recoveryMapping,
                identityScope: identityScope,
                legacyScope: legacyScope
            )
        }

        return try ManagedAccountScopeBinding(
            identityScopeHash: identityScope,
            dataScopeHash: identityScope,
            dataScopeVersion: 2,
            requiresPersistence: true
        )
    }

    static func isScopeHash(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isIdentityComponent(
        _ value: String,
        allowEmpty: Bool = false
    ) -> Bool {
        let bytes = Data(value.utf8)
        return (allowEmpty || !bytes.isEmpty)
            && bytes.count <= 1_024
            && !value.contains("\0")
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(Data(value.utf8).count):\(value)"
    }

    private static func binding(
        from recoveryMapping: ManagedAccountScopeRecoveryMapping,
        identityScope: String,
        legacyScope: String
    ) throws -> ManagedAccountScopeBinding {
        guard recoveryMapping.bindingSchemaVersion == bindingSchemaVersion else {
            throw ManagedAccountScopeError.invalidPersistedBinding
        }
        guard recoveryMapping.identityScopeHash == identityScope else {
            throw ManagedAccountScopeError.identityMismatch
        }
        let expectedDataScope: String
        switch recoveryMapping.dataScopeVersion {
        case 1:
            expectedDataScope = legacyScope
        case 2:
            expectedDataScope = identityScope
        default:
            throw ManagedAccountScopeError.invalidPersistedBinding
        }
        guard recoveryMapping.dataScopeHash == expectedDataScope else {
            throw ManagedAccountScopeError.invalidPersistedBinding
        }
        return try ManagedAccountScopeBinding(
            identityScopeHash: identityScope,
            dataScopeHash: recoveryMapping.dataScopeHash,
            dataScopeVersion: recoveryMapping.dataScopeVersion,
            requiresPersistence: false
        )
    }
}
