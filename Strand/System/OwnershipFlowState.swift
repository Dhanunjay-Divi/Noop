import Foundation

func ownershipAccountScopeMaterial(
    projectID: String,
    subject: String
) -> Data {
    Data(
        "noop-ownership-account-v2\0\(projectID)\0\(subject)".utf8
    )
}

enum OwnershipServicePhase: Equatable {
    case unavailable
    case localRecoveryRequired
    case signedOut
    case emailVerification
    case termsReview
    case registering
    case accountReady
    case possessionUnavailable
    case claiming
    case claimed
    case complete
    case replacementRequired
    case authorizingReplacement
}

func ownershipReconciliationRecoveryPhase(
    _ phase: OwnershipServicePhase
) -> OwnershipServicePhase {
    switch phase {
    case .registering:
        return .termsReview
    case .authorizingReplacement:
        return .replacementRequired
    default:
        return phase
    }
}

func ownershipCancellationRecoveryPhase(
    _ phase: OwnershipServicePhase,
    possessionAvailable: Bool
) -> OwnershipServicePhase {
    switch phase {
    case .registering:
        return .termsReview
    case .claiming:
        return possessionAvailable ? .accountReady : .possessionUnavailable
    case .authorizingReplacement:
        return .replacementRequired
    default:
        return phase
    }
}

func ownershipFailureRecoveryPhase(
    _ phase: OwnershipServicePhase,
    termsChanged: Bool,
    secureStorageFailed: Bool = false
) -> OwnershipServicePhase {
    if secureStorageFailed {
        return .localRecoveryRequired
    }
    return termsChanged
        ? .termsReview
        : ownershipReconciliationRecoveryPhase(phase)
}

func ownershipFailureShouldUpdateState(_ error: Error) -> Bool {
    if Task.isCancelled || error is CancellationError {
        return false
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
        return false
    }
    return true
}

func ownershipReconciliationMayUpdateState(
    expectedGeneration: UInt64?,
    currentGeneration: UInt64
) -> Bool {
    expectedGeneration == nil || expectedGeneration == currentGeneration
}

func ownershipCanAccessPostClaimOnboarding(
    isAvailable: Bool,
    phase: OwnershipServicePhase
) -> Bool {
    !isAvailable || phase == .claimed || phase == .complete
}

enum NoopProductPlan: String, CaseIterable, Codable, Sendable {
    case noop
    case noopPlus = "noop_plus"

    static let storageKey = "noop.productPlanSelection"

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: storageKey),
              let value = Self(rawValue: raw) else {
            return .noop
        }
        return value
    }

    func persist(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

struct OwnershipInstallationCredential: Codable, Equatable, Sendable {
    let id: String
    let token: String

    var isValid: Bool {
        id.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#,
            options: .regularExpression
        ) != nil
            && token.range(
                of: #"^noopo_[A-Za-z0-9_-]{43}$"#,
                options: .regularExpression
            ) != nil
    }

    static func decodePersisted(
        _ data: Data
    ) throws -> OwnershipInstallationCredential {
        let value: OwnershipInstallationCredential
        do {
            value = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw OwnershipInstallationCredentialError.invalid
        }
        guard value.isValid else {
            throw OwnershipInstallationCredentialError.invalid
        }
        return value
    }
}

enum OwnershipInstallationCredentialError: Error, Equatable {
    case invalid
}

enum OwnershipAccountStage: Int, Codable, CaseIterable, Sendable {
    case signedOut
    case emailVerification
    case termsReview
    case accountRegistration
    case accountReady
    case claimPending
    case claimed
    case planSelection
    case complete
    case replacementRequired
    case replacementPending
}

struct OwnershipAccountCheckpoint: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schema: Int
    var stage: OwnershipAccountStage
    var registrationRequestID: UUID
    var claimRequestID: UUID
    var planRequestID: UUID
    var replacementRequestID: UUID
    var acceptedPolicyVersion: String?
    var acceptedPolicySHA256: String?
    var acceptedLocale: String?
    var pendingPlanSelection: NoopProductPlan?

    init(
        schema: Int = schemaVersion,
        stage: OwnershipAccountStage = .signedOut,
        registrationRequestID: UUID = UUID(),
        claimRequestID: UUID = UUID(),
        planRequestID: UUID = UUID(),
        replacementRequestID: UUID = UUID(),
        acceptedPolicyVersion: String? = nil,
        acceptedPolicySHA256: String? = nil,
        acceptedLocale: String? = nil,
        pendingPlanSelection: NoopProductPlan? = nil
    ) {
        self.schema = schema
        self.stage = stage
        self.registrationRequestID = registrationRequestID
        self.claimRequestID = claimRequestID
        self.planRequestID = planRequestID
        self.replacementRequestID = replacementRequestID
        self.acceptedPolicyVersion = acceptedPolicyVersion
        self.acceptedPolicySHA256 = acceptedPolicySHA256
        self.acceptedLocale = acceptedLocale
        self.pendingPlanSelection = pendingPlanSelection
    }

    var isValid: Bool {
        let policyIsComplete = (acceptedPolicyVersion == nil
            && acceptedPolicySHA256 == nil
            && acceptedLocale == nil)
            || (acceptedPolicyVersion != nil
                && acceptedPolicySHA256 != nil
                && acceptedLocale != nil)
        let registrationHasTerms = stage != .accountRegistration
            || hasAcceptedTerms
        let pendingPlanMatchesStage = (stage == .planSelection)
            == (pendingPlanSelection != nil)
        let reviewHasNoStaleAcceptance = stage != .termsReview
            || !hasAcceptedTerms
        return schema == Self.schemaVersion
            && Self.validPolicyComponent(acceptedPolicyVersion, maximum: 64)
            && Self.validDigest(acceptedPolicySHA256)
            && Self.validLocale(acceptedLocale)
            && policyIsComplete
            && registrationHasTerms
            && pendingPlanMatchesStage
            && reviewHasNoStaleAcceptance
    }

    var hasAcceptedTerms: Bool {
        acceptedPolicyVersion != nil
            && acceptedPolicySHA256 != nil
            && acceptedLocale != nil
    }

    mutating func captureAcceptedTerms(
        policyVersion: String,
        sha256: String,
        locale: String
    ) throws {
        try setAcceptedTerms(
            policyVersion: policyVersion,
            sha256: sha256,
            locale: locale
        )
        stage = .emailVerification
    }

    mutating func acceptTerms(
        policyVersion: String,
        sha256: String,
        locale: String
    ) throws {
        try setAcceptedTerms(
            policyVersion: policyVersion,
            sha256: sha256,
            locale: locale
        )
        stage = .accountRegistration
    }

    private mutating func setAcceptedTerms(
        policyVersion: String,
        sha256: String,
        locale: String
    ) throws {
        guard Self.validPolicyComponent(policyVersion, maximum: 64),
              Self.validDigest(sha256),
              Self.validLocale(locale) else {
            throw OwnershipAccountTransitionError.invalidPolicy
        }
        if acceptedPolicyVersion != policyVersion
            || acceptedPolicySHA256 != sha256
            || acceptedLocale != locale {
            registrationRequestID = UUID()
        }
        acceptedPolicyVersion = policyVersion
        acceptedPolicySHA256 = sha256
        acceptedLocale = locale
    }

    mutating func advance(to next: OwnershipAccountStage) throws {
        if next == stage { return }
        guard next.rawValue == stage.rawValue + 1 else {
            throw OwnershipAccountTransitionError.invalidTransition
        }
        if next == .accountRegistration,
           acceptedPolicyVersion == nil
            || acceptedPolicySHA256 == nil
            || acceptedLocale == nil {
            throw OwnershipAccountTransitionError.termsRequired
        }
        stage = next
    }

    mutating func resetForSignOut() {
        self = OwnershipAccountCheckpoint()
    }

    mutating func rotateClaimRequest() {
        claimRequestID = UUID()
    }

    mutating func completeRegistration() {
        registrationRequestID = UUID()
        stage = .accountReady
    }

    mutating func invalidateAcceptedTerms() {
        registrationRequestID = UUID()
        planRequestID = UUID()
        acceptedPolicyVersion = nil
        acceptedPolicySHA256 = nil
        acceptedLocale = nil
        pendingPlanSelection = nil
        stage = .termsReview
    }

    mutating func beginClaimAttempt() {
        claimRequestID = UUID()
        stage = .claimPending
    }

    mutating func reconcileClaim(claimed: Bool) {
        claimRequestID = UUID()
        stage = claimed ? .claimed : .accountReady
    }

    mutating func reconcileBandState(claimed: Bool) {
        if claimed {
            if stage == .accountReady || stage == .claimPending {
                reconcileClaim(claimed: true)
            }
        } else if stage == .claimed || stage == .complete {
            reconcileClaim(claimed: false)
        }
    }

    mutating func beginPlanSelection(_ selection: NoopProductPlan) {
        if pendingPlanSelection != selection {
            planRequestID = UUID()
        }
        pendingPlanSelection = selection
        stage = .planSelection
    }

    mutating func completePlanSelection(bandClaimed: Bool) {
        pendingPlanSelection = nil
        planRequestID = UUID()
        stage = bandClaimed ? .complete : .accountReady
    }

    mutating func rotatePlanRequest() {
        planRequestID = UUID()
    }

    mutating func requireReplacementAuthorization() {
        replacementRequestID = UUID()
        stage = .replacementRequired
    }

    mutating func beginReplacementAttempt() {
        replacementRequestID = UUID()
        stage = .replacementPending
    }

    mutating func reconcileReplacement(authorized: Bool) {
        replacementRequestID = UUID()
        stage = authorized ? .complete : .replacementRequired
    }

    private static func validDigest(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validPolicyComponent(
        _ value: String?,
        maximum: Int
    ) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.count <= maximum
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "._-"))
                    .contains($0)
            }
    }

    private static func validLocale(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.range(
            of: #"^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$"#,
            options: .regularExpression
        ) != nil
    }
}

extension OwnershipAccountCheckpoint {
    private enum CodingKeys: String, CodingKey {
        case schema
        case stage
        case registrationRequestID
        case claimRequestID
        case planRequestID
        case replacementRequestID
        case acceptedPolicyVersion
        case acceptedPolicySHA256
        case acceptedLocale
        case pendingPlanSelection
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        stage = try values.decode(OwnershipAccountStage.self, forKey: .stage)
        registrationRequestID = try values.decode(
            UUID.self,
            forKey: .registrationRequestID
        )
        claimRequestID = try values.decode(UUID.self, forKey: .claimRequestID)
        planRequestID = try values.decode(UUID.self, forKey: .planRequestID)
        replacementRequestID = try values.decodeIfPresent(
            UUID.self,
            forKey: .replacementRequestID
        ) ?? UUID()
        acceptedPolicyVersion = try values.decodeIfPresent(
            String.self,
            forKey: .acceptedPolicyVersion
        )
        acceptedPolicySHA256 = try values.decodeIfPresent(
            String.self,
            forKey: .acceptedPolicySHA256
        )
        acceptedLocale = try values.decodeIfPresent(
            String.self,
            forKey: .acceptedLocale
        )
        pendingPlanSelection = try values.decodeIfPresent(
            NoopProductPlan.self,
            forKey: .pendingPlanSelection
        )
    }
}

enum OwnershipAccountTransitionError: Error, Equatable {
    case invalidPolicy
    case invalidTransition
    case termsRequired
}

protocol OwnershipBandPossessionProviding: Sendable {
    var isAvailable: Bool { get }
    func response(for challenge: String) async throws -> String
}

struct UnavailableOwnershipBandPossessionProvider: OwnershipBandPossessionProviding {
    let isAvailable = false

    func response(for challenge: String) async throws -> String {
        _ = challenge
        throw OwnershipBandPossessionProviderError.unavailable
    }
}

enum OwnershipBandPossessionProviderError: Error, Equatable {
    case unavailable
    case rejected
    case timedOut
}

enum OwnershipEndpointPolicy {
    static func isValidBaseURL(
        _ url: URL,
        allowLocalHTTP: Bool,
        permitsLocalHTTP: Bool
    ) -> Bool {
        guard url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let host = url.host?.lowercased() else {
            return false
        }
        if url.scheme?.lowercased() == "https" {
            return true
        }
        return permitsLocalHTTP
            && allowLocalHTTP
            && url.scheme?.lowercased() == "http"
            && ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    static func isValidTermsDocumentURL(
        _ url: URL,
        allowedHost: String
    ) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == allowedHost.lowercased()
            && (url.port == nil || url.port == 443)
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }
}
