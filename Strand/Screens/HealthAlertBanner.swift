import SwiftUI
import StrandDesign

enum DailySignalAppearance {
    static let alertTint = Color(hex: "#FF453A")
}

/// Strain/illness early-warning banner. Observes AppModel in isolation so the ~1 Hz HR stream
/// re-renders only this small view, not the whole screen. Renders nothing when there's no alert.
struct HealthAlertBanner: View {
    @EnvironmentObject var model: AppModel

    private var title: String {
        model.illnessSignal?.level == .alreadyUnwell
            ? String(localized: "appwide.daily_signal.alert.unwell_title")
            : String(localized: "appwide.daily_signal.alert.title")
    }

    var body: some View {
        if let alert = model.healthAlert {
            NavigationLink(value: TabRoute.health) {
                NoopCard(padding: 14, tint: DailySignalAppearance.alertTint) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DailySignalAppearance.alertTint)
                            .frame(width: 32, height: 32)
                            .background(DailySignalAppearance.alertTint.opacity(0.16), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title)
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(alert)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 4) {
                                Text("appwide.daily_signal.alert.review")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(DailySignalAppearance.alertTint)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("appwide.daily_signal.alert.a11y.hint"))
        }
    }
}
