import SwiftUI
import StrandDesign

/// Opens the owner-configured public order page without exposing or logging it.
struct BandOrderLinkView: View {
    let orderURL: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 8) {
            Button(action: openOrderPage) {
                Label(
                    String(
                        localized: "appwide.onboarding.get_one_now"
                    ),
                    systemImage: "bag"
                )
                .font(StrandFont.subhead)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                orderURL == nil
                    ? StrandPalette.textTertiary
                    : StrandPalette.accent
            )
            .disabled(orderURL == nil)
            .accessibilityIdentifier("noop.onboarding.order-band")

            if orderURL == nil {
                Text(
                    String(
                        localized:
                            "appwide.onboarding.order_unavailable"
                    )
                )
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
            }
        }
    }

    private func openOrderPage() {
        guard let orderURL else {
            recordOutcome("unavailable")
            return
        }
        recordOutcome("opened")
        openURL(orderURL)
    }

    private func recordOutcome(_ outcome: String) {
        AppDiagnosticsRecorder.shared.record(
            "onboarding.band_order",
            fields: ["outcome": outcome]
        )
    }
}
