import SwiftUI
import StrandDesign

/// Root — the sidebar shell, with the first-run onboarding/pairing wizard overlaid until complete,
/// and a "What's New" changelog sheet shown automatically after an update.
struct ContentView: View {
    private let onOnboardingFinished: () -> Void
    @AppStorage("noop.onboarded") private var onboarded = false
    @AppStorage("noop.lastSeenChangelogVersion") private var lastSeenChangelog = ""
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTerms = ""
    /// Local timestamp of the last terms acceptance — the on-device consent record (version + when).
    @AppStorage("noop.acceptedTermsAt") private var acceptedTermsAt = ""
    @AppStorage("noop.firstInstallWelcomePending") private var firstInstallWelcomePending = false
    @AppStorage("noop.completedFirstInstallWelcome") private var completedFirstInstallWelcome = false
    @State private var showWhatsNew = false

    private var isStrengthGuideDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--demo-strength-guide")
            || ProcessInfo.processInfo.environment["NOOP_STRENGTH_GUIDE_DEMO"] != nil
        #else
        false
        #endif
    }

    init(onOnboardingFinished: @escaping () -> Void = {}) {
        self.onOnboardingFinished = onOnboardingFinished
    }

    var body: some View {
        ZStack {
            // RootView starts repository refresh, backup catch-up and optional remote sync from its task.
            // Keep those operational side effects outside the pre-acceptance view hierarchy.
            if acceptedTerms == Terms.currentVersion || isStrengthGuideDemo {
                RootView()
            } else {
                StrandPalette.surfaceBase.ignoresSafeArea()
            }
            if acceptedTerms == Terms.currentVersion && !onboarded && !isStrengthGuideDemo {
                OnboardingWizard(onFinished: {
                    onOnboardingFinished()
                    onboarded = true
                })
                .transition(.opacity)
                .zIndex(1)
            }
            // Terms acknowledgment gate — before onboarding or the operational shell until
            // the current terms version is accepted; re-appears if the terms materially change.
            if acceptedTerms != Terms.currentVersion && !isStrengthGuideDemo {
                TermsGateView(onAccept: {
                    acceptedTermsAt = ISO8601DateFormatter().string(from: Date())
                    acceptedTerms = Terms.currentVersion
                })
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        // Calm easing cubic-bezier(0.22,1,0.36,1) at the README sheet-present duration (~0.42s) for
        // the full-screen onboarding / terms overlays — decelerating, nothing overshoots.
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.42), value: onboarded)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.42), value: acceptedTerms)
        .sheet(isPresented: $showWhatsNew, onDismiss: completeWhatsNewPresentation) {
            WhatsNewView(
                presentation: .welcome(firstInstall: firstInstallWelcomePending),
                onSkip: { showWhatsNew = false },
                onClose: { showWhatsNew = false }
            )
        }
        // The Terms gate must stay "over everything" - don't pop What's New on top of it after a
        // combined terms+version update. Gate on terms being current, and re-check when they're
        // accepted (onAppear already fired before acceptance), so What's New shows right after.
        .onAppear {
            prepareFirstInstallExperience()
            showWhatsNewIfDue()
            // Seed the current What's New into the Updates inbox (idempotent per version) so the bell
            // collects it even if the user dismisses the auto sheet.
            UpdateStore.shared.seedWhatsNewIfNeeded()
        }
        .onChangeCompat(of: acceptedTerms) { _ in showWhatsNewIfDue() }
        .onChangeCompat(of: onboarded) { _ in showWhatsNewIfDue() }
    }

    private func showWhatsNewIfDue() {
        // Existing users who updated, plus a brand-new user after onboarding: their last-seen version
        // is genuinely behind the current one. A downgrade never replays newer notes.
        if onboarded && acceptedTerms == Terms.currentVersion
            && TrialNoticePolicy.isNewerMarketingVersion(
                AppChangelog.currentVersion,
                than: lastSeenChangelog
            ) {
            showWhatsNew = true
        }
    }

    private func prepareFirstInstallExperience() {
        let prepared = ReleaseWelcomeInstallState.prepared(
            onboarded: onboarded,
            storedPending: firstInstallWelcomePending,
            storedCompleted: completedFirstInstallWelcome
        )
        firstInstallWelcomePending = prepared.pending
        completedFirstInstallWelcome = prepared.completed
    }

    private func completeWhatsNewPresentation() {
        lastSeenChangelog = AppChangelog.currentVersion
        let completed = ReleaseWelcomeInstallState(
            pending: firstInstallWelcomePending,
            completed: completedFirstInstallWelcome
        ).completingWelcome()
        firstInstallWelcomePending = completed.pending
        completedFirstInstallWelcome = completed.completed
    }
}
