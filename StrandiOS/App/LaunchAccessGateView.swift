#if os(iOS)
import SwiftUI
import StrandDesign
import UIKit

/// Temporary, local-only launch access screen. It deliberately collects no identity and performs no
/// network request; the entered value exists only long enough to compare against the bundled verifier.
struct LaunchAccessGateView: View {
    @ObservedObject var controller: LaunchAccessController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var candidate = ""
    @State private var feedback: Feedback?

    private enum Feedback {
        case rejected
        case persistenceFailed

        var message: String {
            switch self {
            case .rejected:
                return String(localized: "That access code didn’t match. Try again.")
            case .persistenceFailed:
                return String(localized: "NOOP couldn’t save access securely. Unlock this iPhone and try again.")
            }
        }
    }

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()

            ScrollView {
                VStack(spacing: NoopMetrics.sectionSpacing) {
                    Spacer(minLength: NoopMetrics.space8)
                    BrandMark(size: 88)

                    VStack(spacing: NoopMetrics.space3) {
                        Text("Welcome to NOOP")
                            .font(StrandFont.title1)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("Enter your access code to continue.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    if controller.state == .unavailable {
                        unavailableCard
                    } else {
                        accessForm
                    }

                    Text("Access is checked on this iPhone. NOOP does not send or store the code you enter.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: NoopMetrics.space6)
                }
                .frame(maxWidth: 560)
                .screenPadding()
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noop.launchAccess.gate")
        .onAppear { fieldFocused = controller.state == .locked }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: feedback?.message
        )
    }

    private var accessForm: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Text("Access code")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)

                SecureField("Enter access code", text: $candidate)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.go)
                    .privacySensitive()
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .padding(.horizontal, NoopMetrics.space4)
                    .frame(minHeight: 52)
                    .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                feedback == nil ? StrandPalette.hairline : StrandPalette.statusCritical,
                                lineWidth: 1
                            )
                    }
                    .accessibilityLabel("Access code")
                    .accessibilityHint("Enter the code provided for NOOP access.")
                    .accessibilityIdentifier("noop.launchAccess.field")

                if let feedback {
                    Label(feedback.message, systemImage: "exclamationmark.circle.fill")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusCriticalText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("noop.launchAccess.error")
                }

                NoopButton(
                    "Continue",
                    systemImage: "arrow.right",
                    kind: .primary,
                    fullWidth: true,
                    action: submit
                )
                .disabled(candidate.isEmpty)
                .accessibilityHint("Checks this code on your iPhone and opens NOOP.")
                .accessibilityIdentifier("noop.launchAccess.continue")
            }
        }
    }

    private var unavailableCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Label("Access is temporarily unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                Text("Unlock this iPhone, then retry. If the problem continues, this build needs an updated access configuration.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                NoopButton(
                    "Retry",
                    systemImage: "arrow.clockwise",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    controller.reload()
                    fieldFocused = controller.state == .locked
                }
                .accessibilityIdentifier("noop.launchAccess.retry")
            }
        }
    }

    private func submit() {
        guard !candidate.isEmpty else { return }
        let result = controller.submit(candidate)
        candidate = ""
        switch result {
        case .accepted:
            feedback = nil
            fieldFocused = false
        case .rejected:
            feedback = .rejected
            fieldFocused = true
            announce(feedback?.message)
        case .persistenceFailed, .configurationUnavailable:
            feedback = .persistenceFailed
            fieldFocused = true
            announce(feedback?.message)
        }
    }

    private func announce(_ message: String?) {
        guard let message else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
#endif
