import SwiftUI
import StrandDesign

/// One explicit, reusable information action across Today and metric dossiers. The visible glass tile can
/// stay compact while the control always owns a 44×44 hit target for touch and accessibility.
struct MetricInfoButton: View {
    let title: String
    let tint: Color
    var visualSize: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: max(13, visualSize * 0.50), weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: visualSize, height: visualSize)
                .background(
                    LinearGradient(
                        colors: [tint.opacity(0.22), tint.opacity(0.09)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: max(8, visualSize * 0.32), style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: max(8, visualSize * 0.32), style: .continuous)
                        .strokeBorder(tint.opacity(0.28), lineWidth: 0.7)
                )
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
        .accessibilityHint("What it is and why it matters.")
        .help(title)
    }
}

/// The short-form "what is this and why should I care?" surface used by explicit metric info controls.
/// The full MetricDetailView carries the same education plus
/// personal trends; this sheet stays useful before a metric has any data.
struct MetricExplanationSheet: View {
    let metric: MetricDescriptor
    @Environment(\.dismiss) private var dismiss

    private var education: MetricEducation { MetricKnowledge.education(for: metric) }
    private var tint: Color {
        switch metric.category {
        case "Charge": return StrandPalette.chargeColor
        case "Rest": return StrandPalette.restColor
        case "Effort": return StrandPalette.effortColor
        case "Heart": return StrandPalette.metricRose
        case "Mind": return StrandPalette.metricPurple
        default: return StrandPalette.metricCyan
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    HStack(spacing: NoopMetrics.space4) {
                        MetricGlyph(metric.icon, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.title)
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            HStack(spacing: 6) {
                                explanationPill(education.cadence)
                                explanationPill(MetricKnowledge.dataKind(for: metric))
                            }
                        }
                    }

                    explanationCard(
                        title: String(localized: "WHAT IT IS"),
                        symbol: "info.circle.fill",
                        body: education.whatItIs
                    )
                    explanationCard(
                        title: String(localized: "WHY IT MATTERS"),
                        symbol: "sparkles",
                        body: education.whyItMatters
                    )

                    NoopCard(tint: tint) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            Label("How NOOP gets it", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(education.method)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider().overlay(StrandPalette.hairline)

                            Label("Limits", systemImage: "scope")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(education.limitations)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text(MetricKnowledge.safetyBoundary)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(metric.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func explanationCard(title: String, symbol: String, body: String) -> some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 26, height: 26)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(title)
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text(body)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func explanationPill(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.7))
    }
}
