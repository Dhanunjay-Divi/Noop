import Foundation

/// Builds the installation-scoped identifier stored by the self-hosted server.
///
/// The human/logical source remains separate metadata. Scoping the actual storage key prevents an
/// iPhone, Mac, and Android phone that upload the same logical source from overwriting each other.
public enum RemoteNamespaceIdentifier {
    private static let maximumLength = 128

    public static func scoped(
        platform: String,
        installationId: String,
        logicalSourceId: String,
        revisionToken: String? = nil
    ) -> String {
        let revisionScoped = revisionToken.map {
            logicalSourceId + "-alg-" + safeComponent($0)
        } ?? logicalSourceId
        let direct = "\(platform):\(installationId):\(revisionScoped)"
        if direct.utf8.count <= maximumLength, isAllowedIdentifier(direct) {
            return direct
        }

        let platformCandidate = String(safeComponent(platform).prefix(12))
        let safePlatform = platformCandidate.unicodeScalars.first.map(isASCIIAlphaNumeric) == true
            ? platformCandidate
            : "apple"
        let installation = safeComponent(installationId)
        let safeInstallation = installation.isEmpty
            ? fingerprint(installationId)
            : String(installation.prefix(64))
        let safeLogical = safeComponent(revisionScoped)
        let digest = fingerprint(revisionScoped)
        let prefix = "\(safePlatform):\(safeInstallation):"
        let readableLength = max(0, maximumLength - prefix.utf8.count - digest.utf8.count - 1)
        return prefix + String(safeLogical.prefix(readableLength)) + ":" + digest
    }

    /// A compact deterministic token for formula/source revisions that must receive a fresh server
    /// namespace. The full human-readable revisions still travel in source metadata.
    public static func revisionToken(_ revisions: [String]) -> String {
        fingerprint(revisions.joined(separator: "\u{1f}"))
    }

    private static func safeComponent(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return Character(String(scalar))
            case 45, 46, 58, 95:
                return Character(String(scalar))
            default:
                return "_"
            }
        })
    }

    private static func isAllowedIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              isASCIIAlphaNumeric(first) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || [45, 46, 58, 95].contains(scalar.value)
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122: return true
        default: return false
        }
    }

    /// FNV-1a is sufficient here: this is a stable namespace discriminator, not an authentication
    /// primitive. It also keeps this helper available on every package platform without extra state.
    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
