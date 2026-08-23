import SwiftUI
import Combine
import StrandDesign

// StressCheckInCard.swift - the L3 closed-loop JITAI surface (the "passive" layer), retained for a
// future live source that supplies timestamp-matched wrist motion. The current source is capability-
// gated to manual Breathe, so it cannot present this card. When that evidence is eventually wired and
// the unit-tested `StressOnsetDetector` fires, the central hook posts a pending nudge on
// `StressNudgeCenter`; this dismissible card surfaces it. NEVER an alarm, NEVER a push (unless the
// user separately opted into notifications), NEVER a diagnosis — it describes only the measured
// short-window/baseline relationship, with
// Breathe now / Not now / Turn off, matching DaytimeStress's "passive suggestion" stance.
//
// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3 / UX → "Auto-nudge (passive)").

/// The single observable the L3 hook posts to and the card observes. Self-contained — the central wiring
/// (Wave 3) holds one instance and calls `present()` when `StressOnsetDetector.evaluate` returns
/// `shouldNudge`; the card binds to `pending`. Keeping it here (not in AppModel) means the UI lane owns
/// the whole surface; Wave 3 only needs to inject the instance + call `present`.
@MainActor
final class StressNudgeCenter: ObservableObject {
    /// A live nudge awaiting the user, or nil. Carries the engine's honest numbers for the card copy.
    @Published var pending: Nudge? = nil

    struct Nudge: Equatable {
        /// The fast short-window RMSSD at the moment of the dip (ms), for the honest sub-line.
        let fastRMSSD: Double?
        /// The slow baseline RMSSD (ms) it dipped below.
        let baselineRMSSD: Double?
        /// When it fired.
        let firedAt: Date
    }

    /// Post a nudge (the central L3 hook calls this on a fire). Idempotent-ish: a newer fire replaces an
    /// un-acted one.
    func present(fastRMSSD: Double?, baselineRMSSD: Double?) {
        pending = Nudge(fastRMSSD: fastRMSSD, baselineRMSSD: baselineRMSSD, firedAt: Date())
    }

    func dismiss() { pending = nil }
}

/// The dismissible Stress check-in card. Self-contained — pass the `StressNudgeCenter` and a
/// `onBreatheNow` closure (the host starts a 60-s session at the user's locked pace); `onTurnOff` flips
/// the master toggle off via `BiofeedbackPrefs`. Renders only when a nudge is pending.
struct StressCheckInCard: View {
    @ObservedObject var center: StressNudgeCenter
    /// Start a one-minute breathing cue (the host wires this to the controller at the resonance/5.5 pace).
    var onBreatheNow: () -> Void

    var body: some View {
        if let nudge = center.pending {
            StrandCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    HStack(spacing: NoopMetrics.space2) {
                        Image(systemName: "wind")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.restBright)
                            .accessibilityHidden(true)
                        Text("Stress check-in").strandOverline()
                        Spacer()
                        StatePill("Passive", tone: .neutral, showsDot: true)
                    }

                    Text("Your short-window HRV moved below its recent baseline. Want a minute to breathe?")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let line = honestLine(nudge) {
                        Text(line)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: NoopMetrics.rowSpacing) {
                        NoopButton("Breathe now", systemImage: "wind", kind: .primary) {
                            center.dismiss()
                            onBreatheNow()
                        }

                        NoopButton("Not now", kind: .secondary) { center.dismiss() }

                        NoopButton("Turn off", kind: .tertiary) {
                            BiofeedbackPrefs.checkInEnabled = false
                            center.dismiss()
                        }
                    }

                    Text("Relaxation guidance from your own numbers: not a health alert, and not a diagnosis. Trends matter more than any single number.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.opacity)
        }
    }

    /// An honest one-liner with the two estimates the engine surfaced, framed as "your own number".
    private func honestLine(_ nudge: StressNudgeCenter.Nudge) -> String? {
        guard let fast = nudge.fastRMSSD, let base = nudge.baselineRMSSD, base > 0 else { return nil }
        return String(format: String(localized: "RMSSD %.0f ms now vs your recent ~%.0f ms baseline (estimate)."),
                      fast, base)
    }
}
