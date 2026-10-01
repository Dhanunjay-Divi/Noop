import SwiftUI
import Combine
import StrandDesign

/// A notification-started two-minute reset. It records no workout or standing
/// claim; the timer is only a lightweight prompt the user can dismiss at any time.
struct MovementBreakView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var remainingSeconds =
        ActionableWellnessPolicy.movementDurationSeconds
    @State private var startedAtUptime: TimeInterval?
    @State private var completed = false
    @State private var recordedTerminalOutcome = false

    private let timer = Timer.publish(
        every: 0.25,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: completed ? "checkmark.circle.fill" : "figure.walk.motion")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(
                    completed
                        ? StrandPalette.statusPositive
                        : StrandPalette.accent
                )
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(
                    completed
                        ? String(
                            localized:
                                "appwide.wellness.movement.complete"
                        )
                        : String(
                            localized:
                                "appwide.wellness.movement.title"
                        )
                )
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)

                Text("appwide.wellness.movement.body")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack {
                Circle()
                    .stroke(StrandPalette.hairline, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        StrandPalette.accent,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 0.25),
                        value: remainingSeconds
                    )
                Text(timeText)
                    .font(StrandFont.number(38))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
            }
            .frame(width: 164, height: 164)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                String(
                    format: String(
                        localized:
                            "appwide.wellness.movement.remaining_accessibility"
                    ),
                    remainingSeconds
                )
            )

            Button {
                recordTerminalOutcome(completed ? "completed" : "dismissed")
                dismiss()
            } label: {
                Text("appwide.action.done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NoopPrimaryButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: 460)
        .background(StrandPalette.surfaceBase)
        .onAppear {
            if startedAtUptime == nil {
                startedAtUptime = ProcessInfo.processInfo.systemUptime
            }
            AppDiagnosticsRecorder.shared.record(
                "wellness_notification.movement_break",
                fields: ["outcome": "started"]
            )
        }
        .onReceive(timer) { _ in
            guard remainingSeconds > 0, let startedAtUptime else { return }
            remainingSeconds =
                ActionableWellnessPolicy.movementRemainingSeconds(
                    startedAtUptime: startedAtUptime,
                    nowUptime: ProcessInfo.processInfo.systemUptime
                )
            if remainingSeconds == 0 {
                completed = true
                recordTerminalOutcome("completed")
                StrandHaptic.success.play()
            }
        }
        .onDisappear {
            recordTerminalOutcome(completed ? "completed" : "dismissed")
        }
    }

    private var progress: Double {
        ActionableWellnessPolicy.movementProgress(
            remainingSeconds: remainingSeconds
        )
    }

    private var timeText: String {
        String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    private func recordTerminalOutcome(_ outcome: String) {
        guard !recordedTerminalOutcome else { return }
        recordedTerminalOutcome = true
        AppDiagnosticsRecorder.shared.record(
            "wellness_notification.movement_break",
            fields: ["outcome": outcome]
        )
    }
}
