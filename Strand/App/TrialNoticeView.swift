import SwiftUI
import StrandDesign

/// Process-launch policy for the iPhone trial disclosure. This deliberately uses
/// in-memory state rather than AppStorage: every cold launch shows the notice again,
/// while the screenshot/demo harness can bypass it deterministically.
enum TrialNoticePolicy {
    static func shouldPresent(
        acknowledgedThisLaunch: Bool,
        demoBypass: Bool
    ) -> Bool {
        !acknowledgedThisLaunch && !demoBypass
    }
}

/// Full-screen trial disclosure shown before Terms and onboarding on every iOS launch.
/// The wording distinguishes NOOP-operated cloud storage (none) from explicit optional
/// destinations the user may choose, so the promise remains true if self-hosted sync is enabled.
struct TrialNoticeView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()

            ScrollView {
                VStack(spacing: NoopMetrics.sectionSpacing) {
                    Spacer(minLength: NoopMetrics.space8)

                    BrandMark(size: 88)

                    Text("TESTFLIGHT TRIAL")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, NoopMetrics.space3)
                        .padding(.vertical, NoopMetrics.space2)
                        .background(
                            StrandPalette.accentMuted,
                            in: Capsule()
                        )

                    VStack(spacing: NoopMetrics.space3) {
                        Text("A private preview of NOOP")
                            .font(StrandFont.title1)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("Use this trial to view and compare experimental wellness metrics from your wearable.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: NoopMetrics.gap) {
                        trialPoint(
                            icon: "iphone.gen3",
                            title: "Stored on this iPhone",
                            body: "NOOP has no account or NOOP-operated cloud in this trial. Metrics stay on this device by default."
                        )
                        trialPoint(
                            icon: "arrow.up.forward.app",
                            title: "Sharing stays your choice",
                            body: "External sharing or self-hosted sync happens only after you explicitly configure and enable it."
                        )
                        trialPoint(
                            icon: "waveform.path.ecg",
                            title: "For viewing, not diagnosis",
                            body: "These metrics are experimental estimates, not medical advice or a medical device."
                        )
                    }

                    Text("Removing NOOP may remove its local data. Apple Health and device backups follow the privacy settings you control on your iPhone.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    NoopButton(
                        "Continue to NOOP",
                        systemImage: "arrow.right",
                        kind: .primary,
                        fullWidth: true,
                        action: onContinue
                    )
                    .accessibilityIdentifier("noop.trial.continue")

                    Spacer(minLength: NoopMetrics.space6)
                }
                .frame(maxWidth: 560)
                .screenPadding()
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noop.trial.notice")
    }

    private func trialPoint(
        icon: String,
        title: LocalizedStringKey,
        body: LocalizedStringKey
    ) -> some View {
        NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.space4) {
                Image(systemName: icon)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: NoopMetrics.space8)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(body)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
