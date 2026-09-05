struct ReleaseWelcomeInstallState: Equatable {
    let pending: Bool
    let completed: Bool

    static func prepared(
        onboarded: Bool,
        storedPending: Bool,
        storedCompleted: Bool
    ) -> ReleaseWelcomeInstallState {
        if storedCompleted {
            return ReleaseWelcomeInstallState(pending: false, completed: true)
        }
        if storedPending {
            return ReleaseWelcomeInstallState(pending: true, completed: false)
        }
        if !onboarded {
            return ReleaseWelcomeInstallState(pending: true, completed: false)
        }
        if onboarded {
            return ReleaseWelcomeInstallState(pending: false, completed: true)
        }
        return ReleaseWelcomeInstallState(pending: false, completed: false)
    }

    func completingWelcome() -> ReleaseWelcomeInstallState {
        ReleaseWelcomeInstallState(pending: false, completed: true)
    }
}
