import SwiftUI
import StrandDesign

// MARK: - Key-Metrics layout editor
//
// The editor owns display order only. It never changes a metric, source, formula, or stored health row.
// Selected metrics stay in their saved order; the complete Today-ready catalog remains discoverable below.

struct KeyMetricsEditorSheet: View {
    @Binding var layoutRaw: String

    @Environment(\.dismiss) private var dismiss
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false

    @State private var selected: [KeyMetric]
    @State private var searchText = ""

    init(layoutRaw: Binding<String>) {
        _layoutRaw = layoutRaw
        _selected = State(initialValue: KeyMetricPrefs.decodeEnabled(layoutRaw.wrappedValue))
    }

    private var selectedSet: Set<KeyMetric> { Set(selected) }

    private var availableMetrics: [KeyMetric] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return KeyMetric.defaultOrder.filter { metric in
            !selectedSet.contains(metric)
                && (query.isEmpty
                    || metric.title.localizedCaseInsensitiveContains(query)
                    || metric.category.title.localizedCaseInsensitiveContains(query)
                    || metric.origin.title.localizedCaseInsensitiveContains(query)
                    || metric.origin.detail.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        #if os(macOS)
        editor
            .frame(width: 520, height: 680)
        #else
        editor
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        #endif
    }

    private var editor: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, NoopMetrics.space5)
                .padding(.top, NoopMetrics.space5)
                .padding(.bottom, NoopMetrics.space3)

            searchField
                .padding(.horizontal, NoopMetrics.space5)
                .padding(.bottom, NoopMetrics.space4)

            Divider().overlay(StrandPalette.hairline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.space5) {
                    selectedSection
                    availableSection
                }
                .padding(NoopMetrics.space5)
            }

            Divider().overlay(StrandPalette.hairline)
            footer
                .padding(.horizontal, NoopMetrics.space5)
                .padding(.vertical, NoopMetrics.space3)
        }
        .background(StrandPalette.surfaceOverlay)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 5) {
                Text("KEY METRICS")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(String(localized: "Choose your snapshot"))
                    .font(StrandFont.rounded(24, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(String(localized: "Show 3 to 6 metrics on Today. Every other supported metric stays available here and in history."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NoopMetrics.space2)
            Text(String(localized: "\(selected.count)/\(KeyMetricPrefs.maximumSelectionCount)"))
                .font(StrandFont.captionNumber)
                .foregroundStyle(
                    selected.count == KeyMetricPrefs.maximumSelectionCount
                        ? StrandPalette.statusPositive
                        : StrandPalette.textSecondary
                )
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(
                    Capsule()
                        .fill(StrandPalette.surfaceRaised)
                        .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 1))
                )
                .accessibilityLabel(
                    String(localized: "\(selected.count) of \(KeyMetricPrefs.maximumSelectionCount) selected")
                )
                .accessibilityIdentifier("noop.key-metric.selection-count")
        }
    }

    private var searchField: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            TextField("Search metrics", text: $searchText)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityIdentifier("noop.key-metric.search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear metric search"))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StrandPalette.surfaceInset)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
        )
    }

    private var selectedSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            sectionHeader("ON TODAY", trailing: "Drag order with the arrows")
            VStack(spacing: NoopMetrics.space2) {
                ForEach(Array(selected.enumerated()), id: \.element.id) { index, metric in
                    selectedRow(metric, at: index)
                }
            }
        }
    }

    private var availableSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            sectionHeader("AVAILABLE METRICS", trailing: "\(KeyMetric.allCases.count) supported")

            if availableMetrics.isEmpty {
                Text(
                    searchText.isEmpty
                        ? String(localized: "All supported metrics are selected.")
                        : String(localized: "No metrics match this search.")
                )
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                ForEach(KeyMetric.Origin.allCases) { origin in
                    let metrics = availableMetrics.filter { $0.origin == origin }
                    if !metrics.isEmpty {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(origin.title.uppercased())
                                    .font(StrandFont.overlineScaled(9))
                                    .tracking(0)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                Text(origin.detail)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 2)
                            VStack(spacing: NoopMetrics.space2) {
                                ForEach(metrics) { metric in
                                    availableRow(metric)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Text(title)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: NoopMetrics.space2)
            Text(trailing)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func selectedRow(_ metric: KeyMetric, at index: Int) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            MetricGlyph(metric.icon, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(metric.category.title) · \(metric.origin.compactTitle)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("noop.key-metric.selected.\(metric.rawValue)")
            Spacer(minLength: NoopMetrics.space2)
            Button {
                move(from: index, to: index - 1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(index == 0 ? StrandPalette.textTertiary : StrandPalette.textSecondary)
            .disabled(index == 0)
            .accessibilityLabel("Move \(metric.title) up")

            Button {
                move(from: index, to: index + 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(index == selected.count - 1 ? StrandPalette.textTertiary : StrandPalette.textSecondary)
            .disabled(index == selected.count - 1)
            .accessibilityLabel("Move \(metric.title) down")

            Button {
                remove(metric)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                selected.count <= KeyMetricPrefs.minimumSelectionCount
                    ? StrandPalette.textTertiary
                    : StrandPalette.metricRose
            )
            .disabled(selected.count <= KeyMetricPrefs.minimumSelectionCount)
            .accessibilityLabel(String(localized: "Remove \(metric.title) from Today"))
            .accessibilityHint(
                selected.count <= KeyMetricPrefs.minimumSelectionCount
                    ? "At least three metrics must remain."
                    : "Removes this metric from the Today snapshot."
            )
            .accessibilityIdentifier("noop.key-metric.remove.\(metric.rawValue)")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 58)
        .background(rowBackground(tint: accent(for: metric), selected: true))
    }

    private func availableRow(_ metric: KeyMetric) -> some View {
        let hydrationBlocked = metric == .hydration && !hydrationEnabled
        let atLimit = selected.count >= KeyMetricPrefs.maximumSelectionCount
        let canAdd = !hydrationBlocked && !atLimit

        return Button {
            add(metric)
        } label: {
            HStack(spacing: NoopMetrics.space3) {
                MetricGlyph(metric.icon, size: 30)
                    .opacity(canAdd ? 1 : 0.48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title)
                        .font(StrandFont.body)
                        .foregroundStyle(canAdd ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    if hydrationBlocked {
                        Text(String(localized: "Enable hydration tracking in Settings"))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        Text(metric.category.title)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: hydrationBlocked ? "lock.fill" : "plus.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(canAdd ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                    .frame(width: 30, height: 30)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 54)
            .background(rowBackground(tint: accent(for: metric), selected: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .accessibilityLabel(String(localized: "Add \(metric.title) to Today"))
        .accessibilityHint(availableHint(hydrationBlocked: hydrationBlocked, atLimit: atLimit))
        .accessibilityIdentifier("noop.key-metric.add.\(metric.rawValue)")
    }

    private func rowBackground(tint: Color, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(StrandPalette.surfaceRaised.opacity(selected ? 0.92 : 0.68))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? tint.opacity(0.34) : StrandPalette.hairline,
                        lineWidth: 1
                    )
            )
    }

    private func availableHint(hydrationBlocked: Bool, atLimit: Bool) -> String {
        if hydrationBlocked {
            return String(localized: "Enable hydration tracking in Settings before adding this metric.")
        }
        if atLimit {
            return String(localized: "Six metrics are already selected.")
        }
        return String(localized: "Adds this metric to the Today snapshot.")
    }

    private var footer: some View {
        HStack(spacing: NoopMetrics.space3) {
            Button("Reset") {
                selected = KeyMetric.defaultSelection
            }
            .buttonStyle(.plain)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textSecondary)
            .accessibilityLabel("Reset Key Metrics to default")

            Spacer(minLength: NoopMetrics.space3)

            Button {
                layoutRaw = KeyMetricPrefs.encode(selected)
                dismiss()
            } label: {
                Text("Done")
                    .font(StrandFont.body)
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(StrandPalette.statusPositive))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done editing Key Metrics")
        }
    }

    private func add(_ metric: KeyMetric) {
        guard selected.count < KeyMetricPrefs.maximumSelectionCount,
              !selected.contains(metric),
              metric != .hydration || hydrationEnabled else {
            return
        }
        selected.append(metric)
    }

    private func remove(_ metric: KeyMetric) {
        guard selected.count > KeyMetricPrefs.minimumSelectionCount else { return }
        selected.removeAll { $0 == metric }
    }

    private func move(from: Int, to: Int) {
        guard selected.indices.contains(from), selected.indices.contains(to) else { return }
        let metric = selected.remove(at: from)
        selected.insert(metric, at: to)
    }

    private func accent(for metric: KeyMetric) -> Color {
        switch metric {
        case .charge, .respiratory, .weight, .stress:
            return StrandPalette.accent
        case .effort, .calories, .skinTemp, .maxHr:
            return StrandPalette.metricAmber
        case .rest, .hrv, .asleepTime, .vitality:
            return StrandPalette.metricPurple
        case .restingHr, .averageHr:
            return StrandPalette.metricRose
        case .bloodOxygen, .steps, .vo2Max, .hydration:
            return StrandPalette.metricCyan
        }
    }
}

#if DEBUG
#Preview("Key-Metrics editor") {
    KeyMetricsEditorSheet(layoutRaw: .constant(""))
        .preferredColorScheme(.dark)
}
#endif
