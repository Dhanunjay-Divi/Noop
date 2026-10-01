import WhoopStore

/// Pure first-run routing rules shared by restoration, navigation, and tests.
extension OnboardingWizard {
    static let requiredAccountOnboardingVersion = 1
    static let requiredAccountOnboardingVersionStorageKey =
        "noop.requiredAccountOnboardingVersion"

    static func requiresRequiredAccountOnboarding(
        onboarded: Bool,
        completedVersion: Int
    ) -> Bool {
        !onboarded || completedVersion < requiredAccountOnboardingVersion
    }

    static func onboardingSteps(
        ownershipConfigured _: Bool
    ) -> [Step] {
        [
            .welcome,
            .bluetooth,
            .scan,
            .account,
            .ownership,
            .profile,
            .plan,
            .done,
        ]
    }

    static func restoredOnboardingStep(
        storedValue: String?,
        ownershipConfigured: Bool
    ) -> Step {
        let restored = Step.allCases.first {
            $0.storageValue == storedValue
        } ?? .welcome
        return normalizedOnboardingStep(
            restored,
            ownershipConfigured: ownershipConfigured
        )
    }

    static func normalizedOnboardingStep(
        _ candidate: Step,
        ownershipConfigured: Bool
    ) -> Step {
        let steps = onboardingSteps(
            ownershipConfigured: ownershipConfigured
        )
        guard steps.contains(candidate) else { return .welcome }
        return candidate
    }

    static func ownershipDestination(
        for candidate: Step,
        ownershipConfigured: Bool,
        reconciliationComplete: Bool,
        phase: OwnershipServicePhase,
        supplierClaimRequired: Bool = true,
        deviceSetupComplete: Bool = true
    ) -> Step? {
        if candidate == .welcome
            || candidate == .bluetooth
            || candidate == .scan {
            return candidate
        }
        guard deviceSetupComplete else { return .scan }
        if candidate == .account { return .account }
        guard ownershipConfigured else { return .account }
        guard reconciliationComplete else { return nil }
        guard accountStepCanContinue(
            ownershipConfigured: true,
            reconciliationComplete: true,
            phase: phase
        ) else {
            return .account
        }
        let requiresCompletedClaim = supplierClaimRequired
            && [.profile, .plan, .done].contains(candidate)
        guard !requiresCompletedClaim
            || ownershipCanAccessPostClaimOnboarding(
                isAvailable: true,
                phase: phase
            ) else {
            return .ownership
        }
        return candidate
    }

    static func accountStepCanContinue(
        ownershipConfigured: Bool,
        reconciliationComplete: Bool,
        phase: OwnershipServicePhase
    ) -> Bool {
        guard ownershipConfigured, reconciliationComplete else {
            return false
        }
        switch phase {
        case .accountReady, .possessionUnavailable, .claiming, .claimed,
             .complete, .replacementRequired, .authorizingReplacement:
            return true
        case .unavailable, .localRecoveryRequired, .signedOut,
             .emailVerification, .termsReview, .registering,
             .deletionPending:
            return false
        }
    }

    static func claimStepCanContinue(
        supplierClaimRequired: Bool,
        claimed: Bool,
        reconciliationComplete: Bool
    ) -> Bool {
        !supplierClaimRequired || (claimed && reconciliationComplete)
    }
}
