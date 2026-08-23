import SwiftUI
import StrandDesign

// MARK: - Key-Metrics layout editor (#251)
//
// A Today-local sheet for choosing which Key-Metric tiles lead the Control Center and in what order.
// Display-only: it edits the persisted `today.keyMetrics` pin string, never any stored metric. Every tile
// remains visible; three to five pinned tiles render first. Explicit controls behave identically on macOS
// and iOS without depending on List EditMode.

struct KeyMetricsEditorSheet: View {
    /// The persisted layout string (comma-joined pinned `KeyMetric` rawValues, in order). Bound straight
    /// to the Today screen's @AppStorage so an edit takes effect live and survives relaunch.
    @Binding var layoutRaw: String

    @Environment(\.dismiss) private var dismiss

    /// Working copy: the full ordered list with a pinned flag per tile. Pinned tiles come first in their
    /// saved order, then the unpinned remainder in default order, so every known tile appears exactly once.
    @State private var items: [Item]

    private struct Item: Identifiable {
        let metric: KeyMetric
        var enabled: Bool
        var id: String { metric.rawValue }
    }

    private var selectedCount: Int { items.lazy.filter(\.enabled).count }

    init(layoutRaw: Binding<String>) {
        _layoutRaw = layoutRaw
        let enabled = KeyMetricPrefs.decodeEnabled(layoutRaw.wrappedValue)
        let enabledSet = Set(enabled)
        // Pinned tiles first (saved order), then the rest in the canonical default order.
        var working = enabled.map { Item(metric: $0, enabled: true) }
        for m in KeyMetric.defaultOrder where !enabledSet.contains(m) {
            working.append(Item(metric: m, enabled: false))
        }
        _items = State(initialValue: working)
    }

    var body: some View {
        // The sheet is also presented from liquid Today on iPhone — the macOS-shaped fixed 420pt width
        // would overflow a 390pt phone, and ten rows outgrow a sheet's
        // height, so the phone presentation scrolls and sizes to the screen instead.
        #if os(macOS)
        editorContent
            .padding(24)
            .frame(width: 420)
            .background(StrandPalette.surfaceOverlay)
        #else
        ScrollView {
            editorContent.padding(20)
        }
        .background(StrandPalette.surfaceOverlay)
        #endif
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            // Each tile is its own frosted row, tinted by that metric's own accent, so the editor
            // reads like a stack of the cards it controls rather than a flat settings list.
            VStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item, at: index)
                }
            }
            footer
        }
    }

    // MARK: Rows

    private func row(_ item: Item, at index: Int) -> some View {
        let accent = accent(for: item.metric)
        let toggleLocked = toggleIsLocked(item)
        return NoopCard(padding: 12, tint: item.enabled ? accent : nil) {
            HStack(spacing: 12) {
                MetricGlyph(item.metric.icon, size: 30)
                    .opacity(item.enabled ? 1 : 0.42)
                // Pin toggle. An unpinned tile stays visible on Today, after the priority set.
                Toggle(isOn: enabledBinding(at: index)) {
                    Text(item.metric.title)
                        .font(StrandFont.body)
                        .foregroundStyle(item.enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                }
                .toggleStyle(KeyMetricSelectionToggleStyle())
                .disabled(toggleLocked)
                .accessibilityIdentifier("noop.key-metric.toggle.\(item.metric.rawValue)")
                .accessibilityLabel("Pin \(item.metric.title)")
                .accessibilityHint(toggleHint(item))

                Spacer(minLength: 0)

                // Explicit reorder — robust on macOS + iOS without List EditMode/drag.
                Button {
                    move(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(index == 0 ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .accessibilityLabel("Move \(item.metric.title) up")

                Button {
                    move(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(index == items.count - 1 ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index == items.count - 1)
                .accessibilityLabel("Move \(item.metric.title) down")
            }
        }
    }

    /// The accent each metric carries on the Today grid — kept in sync with TodayView's tiles so a
    /// row's dot/wash matches the tile it toggles. Local to the editor (presentation only).
    private func accent(for metric: KeyMetric) -> Color {
        switch metric {
        case .charge:      return StrandPalette.accent
        case .effort:      return StrandPalette.effortColor
        case .rest:        return StrandPalette.metricPurple
        case .hrv:         return StrandPalette.metricPurple
        case .restingHr:   return StrandPalette.metricRose
        case .bloodOxygen: return StrandPalette.metricCyan
        case .respiratory: return StrandPalette.accent
        case .steps:       return StrandPalette.metricCyan
        case .weight:      return StrandPalette.accent
        case .calories:    return StrandPalette.metricAmber
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CONTROL CENTER").font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Edit Key Metrics")
                .font(StrandFont.rounded(24, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Pin 3 to 5 metrics at the top. Every metric stays visible.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(selectedCount) of \(KeyMetricPrefs.maximumSelectionCount) pinned")
                .font(StrandFont.captionNumber)
                .foregroundStyle(
                    selectedCount == KeyMetricPrefs.maximumSelectionCount
                        ? StrandPalette.statusPositive
                        : StrandPalette.textTertiary
                )
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset") { resetToDefault() }
                .buttonStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityLabel("Reset Key Metrics to default")
            Spacer()
            Button {
                commit()
                dismiss()
            } label: {
                Text("Done")
                    .font(StrandFont.body)
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .background {
                        Capsule().fill(StrandPalette.statusPositive)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done editing Key Metrics")
        }
    }

    // MARK: Mutations

    private func enabledBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { items[index].enabled },
            set: { newValue in
                let current = items[index].enabled
                guard newValue != current else { return }
                if newValue {
                    guard selectedCount < KeyMetricPrefs.maximumSelectionCount else { return }
                } else {
                    guard selectedCount > KeyMetricPrefs.minimumSelectionCount else { return }
                }
                items[index].enabled = newValue
            }
        )
    }

    private func toggleIsLocked(_ item: Item) -> Bool {
        if item.enabled {
            return selectedCount <= KeyMetricPrefs.minimumSelectionCount
        }
        return selectedCount >= KeyMetricPrefs.maximumSelectionCount
    }

    private func toggleHint(_ item: Item) -> String {
        if item.enabled, selectedCount <= KeyMetricPrefs.minimumSelectionCount {
            return String(localized: "At least three metrics must stay pinned.")
        }
        if !item.enabled, selectedCount >= KeyMetricPrefs.maximumSelectionCount {
            return String(localized: "Five metrics are already pinned.")
        }
        return String(localized: "Pin or unpin this metric.")
    }

    private func move(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    private func resetToDefault() {
        let defaults = Set(KeyMetric.defaultSelection)
        items = KeyMetric.defaultOrder.map { Item(metric: $0, enabled: defaults.contains($0)) }
    }

    /// Persist the pinned tiles in their current order. Unpinned tiles are omitted from the stored string;
    /// `KeyMetricPrefs.decodeEnabled` rebuilds the editor's unpinned remainder from the
    /// default order on next open, so nothing is lost.
    private func commit() {
        layoutRaw = KeyMetricPrefs.encode(items.filter { $0.enabled }.map(\.metric))
    }
}

/// Keeps boundary-locked metrics visibly selected while `Toggle.disabled` exposes the real state to
/// VoiceOver and Switch Control. The guarded binding remains the persistence boundary for other callers.
private struct KeyMetricSelectionToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Spacer(minLength: 8)
            ZStack {
                Capsule()
                    .fill(
                        configuration.isOn
                            ? StrandPalette.statusPositive
                            : StrandPalette.textTertiary.opacity(0.55)
                    )
                Circle()
                    .fill(Color.white)
                    .padding(2)
                    .offset(x: configuration.isOn ? 10 : -10)
                    .animation(.easeInOut(duration: 0.18), value: configuration.isOn)
            }
            .frame(width: 51, height: 31)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            configuration.isOn.toggle()
        }
    }
}

#if DEBUG
#Preview("Key-Metrics editor") {
    KeyMetricsEditorSheet(layoutRaw: .constant(""))
        .preferredColorScheme(.dark)
}
#endif
