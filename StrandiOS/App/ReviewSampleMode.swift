#if os(iOS)
import SwiftUI
import StrandDesign

enum ReviewSamplePhase: Equatable {
    case entry
    case disclosure
    case active
    case continueSetup

    var blocksStandardLaunch: Bool {
        switch self {
        case .entry, .disclosure, .active:
            return true
        case .continueSetup:
            return false
        }
    }
}

struct ReviewSampleEntryView: View {
    let onExplore: () -> Void
    let onContinueSetup: () -> Void

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()
            ScrollView {
                VStack(spacing: NoopMetrics.sectionSpacing) {
                    Spacer(minLength: NoopMetrics.space6)
                    BrandMark(size: 78)

                    VStack(spacing: NoopMetrics.space3) {
                        Text("Explore NOOP without hardware")
                            .font(StrandFont.title1)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("Review a complete fictional day before pairing a band or granting permissions.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    NoopCard(tint: StrandPalette.accent) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            Label("Review Sample", systemImage: "eye.fill")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Runs in memory with fictional wellness values. Bluetooth, Health, cloud, Friends, notifications, and Safety actions stay off.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(spacing: NoopMetrics.space3) {
                        NoopButton(
                            "Explore Review Sample",
                            systemImage: "sparkles",
                            kind: .primary,
                            fullWidth: true,
                            action: onExplore
                        )
                        .accessibilityIdentifier("noop.review.entry.explore")

                        NoopButton(
                            "Continue setup",
                            systemImage: "arrow.right",
                            kind: .secondary,
                            fullWidth: true,
                            action: onContinueSetup
                        )
                        .accessibilityIdentifier("noop.review.entry.continue")
                    }
                    Spacer(minLength: NoopMetrics.space6)
                }
                .frame(maxWidth: 560)
                .screenPadding()
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("noop.review.entry")
    }
}

struct ReviewSampleDisclosureView: View {
    let onBack: () -> Void
    let onEnter: () -> Void

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()
            ScrollView {
                VStack(spacing: NoopMetrics.sectionSpacing) {
                    Spacer(minLength: NoopMetrics.space6)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)

                    VStack(spacing: NoopMetrics.space3) {
                        Text("Fictional sample wellness data")
                            .font(StrandFont.title1)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("No sensor or medical reading is being taken.")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.statusWarningText)
                            .multilineTextAlignment(.center)
                    }

                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                            disclosureRow(
                                icon: "memorychip",
                                title: "In memory only",
                                body: "The sample is deterministic and is discarded when you exit."
                            )
                            Divider().overlay(StrandPalette.hairline)
                            disclosureRow(
                                icon: "antenna.radiowaves.left.and.right.slash",
                                title: "No external activity",
                                body: "No Bluetooth scan, Health access, upload, Friends request, notification, or Safety action can start."
                            )
                            Divider().overlay(StrandPalette.hairline)
                            disclosureRow(
                                icon: "waveform.path.ecg",
                                title: "General wellness illustration",
                                body: "Values demonstrate product presentation only and are not medical advice."
                            )
                        }
                    }

                    VStack(spacing: NoopMetrics.space3) {
                        NoopButton(
                            "Enter Review Sample",
                            systemImage: "arrow.right",
                            kind: .primary,
                            fullWidth: true,
                            action: onEnter
                        )
                        .accessibilityIdentifier("noop.review.disclosure.enter")

                        NoopButton(
                            "Back",
                            systemImage: "chevron.left",
                            kind: .tertiary,
                            fullWidth: true,
                            action: onBack
                        )
                    }
                    Spacer(minLength: NoopMetrics.space6)
                }
                .frame(maxWidth: 560)
                .screenPadding()
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("noop.review.disclosure")
    }

    private func disclosureRow(icon: String, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 28, height: 28)
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

private enum ReviewSampleTab: String, CaseIterable {
    case today
    case trends
    case workouts
    case sleep
    case more

    var title: LocalizedStringKey {
        switch self {
        case .today: return "Today"
        case .trends: return "Trends"
        case .workouts: return "Workouts"
        case .sleep: return "Sleep"
        case .more: return "More"
        }
    }

    var icon: String {
        switch self {
        case .today: return "circle.hexagongrid.fill"
        case .trends: return "chart.xyaxis.line"
        case .workouts: return "figure.run"
        case .sleep: return "moon.stars.fill"
        case .more: return "ellipsis"
        }
    }
}

private struct ReviewSampleMetric: Identifiable, Hashable {
    let id: String
    let title: LocalizedStringKey
    let value: LocalizedStringKey
    let unit: LocalizedStringKey?
    let summary: LocalizedStringKey
    let values: [Double]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static let all: [ReviewSampleMetric] = [
        .init(
            id: "recovery",
            title: "Recovery",
            value: "78",
            unit: "%",
            summary: "Ready for a productive day with moderate training.",
            values: [64, 69, 73, 66, 75, 72, 78]
        ),
        .init(
            id: "effort",
            title: "Effort",
            value: "9.6",
            unit: nil,
            summary: "Daily movement and the sample workout both contribute.",
            values: [6.1, 7.4, 8.8, 5.9, 10.2, 8.4, 9.6]
        ),
        .init(
            id: "sleep",
            title: "Sleep",
            value: "7h 42m",
            unit: nil,
            summary: "92% of the fictional sleep need was met.",
            values: [6.8, 7.1, 7.6, 6.9, 8.0, 7.3, 7.7]
        ),
        .init(
            id: "hrv",
            title: "HRV",
            value: "64",
            unit: "ms",
            summary: "Inside the fictional 30-day baseline of 58-67 ms.",
            values: [57, 60, 63, 59, 66, 62, 64]
        ),
        .init(
            id: "rhr",
            title: "Resting HR",
            value: "54",
            unit: "bpm",
            summary: "Stable against the fictional baseline of 53-57 bpm.",
            values: [57, 56, 54, 55, 53, 54, 54]
        ),
        .init(
            id: "spo2",
            title: "Blood oxygen",
            value: "97",
            unit: "%",
            summary: "A fictional overnight estimate, not a medical measurement.",
            values: [97, 96, 97, 98, 97, 97, 97]
        ),
    ]
}

private enum ReviewSampleMoreDestination: String, Hashable {
    case friends
    case privacy
    case devices
}

private extension View {
    func reviewSampleContentPadding() -> some View {
        screenPadding()
            .padding(.vertical, NoopMetrics.space4)
    }
}

private struct ReviewSampleBanner: View {
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: "eye.fill")
            Text("REVIEW SAMPLE · FICTIONAL DATA")
                .font(StrandFont.overline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityIdentifier("noop.review.root")
            Spacer()
            Button(action: onExit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
            }
            .accessibilityLabel("Exit Review Sample")
            .accessibilityIdentifier("noop.review.exit")
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, NoopMetrics.space4)
        .frame(minHeight: NoopMetrics.controlHeight)
        .background(
            StrandPalette.surfaceRaised,
            in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .stroke(StrandPalette.hairline, lineWidth: 1)
        }
    }
}

struct ReviewSampleRootView: View {
    let onExit: () -> Void
    @State private var selectedTab: ReviewSampleTab = .today
    @State private var selectedMetric: ReviewSampleMetric?
    @State private var selectedMoreDestination: ReviewSampleMoreDestination?

    var body: some View {
        Group {
            if let metric = selectedMetric {
                ReviewSampleMetricDetailView(
                    metric: metric,
                    onBack: { selectedMetric = nil },
                    onExit: onExit
                )
            } else if let destination = selectedMoreDestination {
                ReviewSampleMoreDetailView(
                    destination: destination,
                    onBack: { selectedMoreDestination = nil },
                    onExit: onExit
                )
            } else {
                TabView(selection: $selectedTab) {
                    ReviewSampleTodayView(
                        onMetric: { selectedMetric = $0 },
                        onExit: onExit
                    )
                    .tabItem { Label(ReviewSampleTab.today.title, systemImage: ReviewSampleTab.today.icon) }
                    .tag(ReviewSampleTab.today)
                    ReviewSampleTrendsView(
                        onMetric: { selectedMetric = $0 },
                        onExit: onExit
                    )
                    .tabItem { Label(ReviewSampleTab.trends.title, systemImage: ReviewSampleTab.trends.icon) }
                    .tag(ReviewSampleTab.trends)
                    ReviewSampleWorkoutsView(onExit: onExit)
                        .tabItem { Label(ReviewSampleTab.workouts.title, systemImage: ReviewSampleTab.workouts.icon) }
                        .tag(ReviewSampleTab.workouts)
                    ReviewSampleSleepView(onExit: onExit)
                        .tabItem { Label(ReviewSampleTab.sleep.title, systemImage: ReviewSampleTab.sleep.icon) }
                        .tag(ReviewSampleTab.sleep)
                    ReviewSampleMoreView(
                        onOpen: { selectedMoreDestination = $0 },
                        onExit: onExit
                    )
                    .tabItem { Label(ReviewSampleTab.more.title, systemImage: ReviewSampleTab.more.icon) }
                    .tag(ReviewSampleTab.more)
                }
                .tint(StrandPalette.accent)
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}

private struct ReviewSampleTodayView: View {
    let onMetric: (ReviewSampleMetric) -> Void
    let onExit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ReviewSampleBanner(onExit: onExit)

                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Good morning")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityIdentifier("noop.review.today.heading")
                    Text("Fictional Monday · updated 8:12 AM")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                NoopCard(tint: StrandPalette.statusPositive) {
                    HStack(alignment: .center, spacing: NoopMetrics.space4) {
                        ZStack {
                            Circle()
                                .stroke(StrandPalette.hairlineStrong, lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: 0.78)
                                .stroke(
                                    StrandPalette.statusPositive,
                                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                            Text("78")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        .frame(width: 82, height: 82)

                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("Steady capacity")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("A balanced day is appropriate in this fictional example.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: NoopMetrics.space3),
                        GridItem(.flexible(), spacing: NoopMetrics.space3),
                    ],
                    spacing: NoopMetrics.space3
                ) {
                    ForEach(ReviewSampleMetric.all) { metric in
                        Button(action: { onMetric(metric) }) {
                            ReviewSampleMetricCard(metric: metric)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("noop.review.metric.\(metric.id)")
                    }
                }

                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Label("Next useful action", systemImage: "sparkles")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Take a short walk after lunch and keep tonight’s 10:35 PM wind-down.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .reviewSampleContentPadding()
        }
        .background(StrandPalette.surfaceBase)
    }
}

private struct ReviewSampleMetricCard: View {
    let metric: ReviewSampleMetric

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(metric.title)
                    .font(StrandFont.overline)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(metric.value)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                    if let unit = metric.unit {
                        Text(unit)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Text("Open detail")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
            }
            .frame(minHeight: 106, alignment: .topLeading)
        }
    }
}

private struct ReviewSampleMetricDetailView: View {
    let metric: ReviewSampleMetric
    let onBack: () -> Void
    let onExit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ReviewSampleBanner(onExit: onExit)

                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("noop.review.back")

                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text(metric.title)
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        Text(metric.value)
                            .font(StrandFont.display(64))
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let unit = metric.unit {
                            Text(unit)
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    Text(metric.summary)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        Text("Last 7 fictional days")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        ReviewSampleBars(values: metric.values)
                    }
                }

                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("How to read this")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("NOOP compares a day with the person’s own recent baseline. A real value appears only when its required evidence is available.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .reviewSampleContentPadding()
        }
        .background(StrandPalette.surfaceBase)
        .accessibilityIdentifier("noop.review.metric.detail")
    }
}

private struct ReviewSampleBars: View {
    let values: [Double]
    private static let dayLabels: [LocalizedStringKey] = [
        "Tue", "Wed", "Thu", "Fri", "Sat", "Sun", "Mon",
    ]

    var body: some View {
        let maximum = max(values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(spacing: NoopMetrics.space1) {
                    Capsule()
                        .fill(index == values.indices.last ? StrandPalette.accent : StrandPalette.textTertiary)
                        .frame(height: max(14, 98 * value / maximum))
                    Text(Self.dayLabels[index])
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 122, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

private struct ReviewSampleTrendsView: View {
    let onMetric: (ReviewSampleMetric) -> Void
    let onExit: () -> Void
    @State private var interval = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ReviewSampleBanner(onExit: onExit)

                Text("Trends")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)

                Picker("Interval", selection: $interval) {
                    Text("7D").tag(0)
                    Text("30D").tag(1)
                    Text("90D").tag(2)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("noop.review.trends.interval")

                ForEach(ReviewSampleMetric.all.prefix(4)) { metric in
                    Button(action: { onMetric(metric) }) {
                        NoopCard {
                            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                                HStack {
                                    Text(metric.title)
                                        .font(StrandFont.headline)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Spacer()
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(metric.value)
                                        if let unit = metric.unit {
                                            Text(unit)
                                        }
                                    }
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.accent)
                                }
                                ReviewSampleBars(values: metric.values)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .reviewSampleContentPadding()
        }
        .background(StrandPalette.surfaceBase)
    }
}

private struct ReviewSampleWorkoutsView: View {
    let onExit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ReviewSampleBanner(onExit: onExit)

                Text("Workouts")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)

                NoopCard(tint: StrandPalette.accent) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        HStack {
                            Label("Strength training", systemImage: "dumbbell.fill")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text("42 min")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.accent)
                        }
                        Text("Fictional session · 6:10 PM")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Divider().overlay(StrandPalette.hairline)
                        metricRow("Average heart rate", "126 bpm")
                        metricRow("Peak heart rate", "161 bpm")
                        metricRow("Active energy", "318 kcal")
                        metricRow("Workout effort", "7.4")
                    }
                }

                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("Weekly plan")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("2 of 3 fictional sessions complete")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                        ProgressView(value: 2, total: 3)
                            .tint(StrandPalette.accent)
                    }
                }
            }
            .reviewSampleContentPadding()
        }
        .background(StrandPalette.surfaceBase)
    }

    private func metricRow(
        _ title: LocalizedStringKey,
        _ value: LocalizedStringKey
    ) -> some View {
        HStack {
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

private struct ReviewSampleSleepView: View {
    let onExit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ReviewSampleBanner(onExit: onExit)

                Text("Sleep")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)

                NoopCard(tint: StrandPalette.sleepDeep) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                Text("7h 42m")
                                    .font(StrandFont.display(56))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("10:48 PM – 6:46 AM")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer()
                            Text("92%")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.sleepDeep)
                        }

                        GeometryReader { geometry in
                            HStack(spacing: 2) {
                                Rectangle().fill(StrandPalette.textTertiary).frame(width: geometry.size.width * 0.08)
                                Rectangle().fill(StrandPalette.accent).frame(width: geometry.size.width * 0.49)
                                Rectangle().fill(StrandPalette.sleepDeep).frame(width: geometry.size.width * 0.20)
                                Rectangle().fill(StrandPalette.statusPositive).frame(width: geometry.size.width * 0.21)
                            }
                            .clipShape(Capsule())
                        }
                        .frame(height: 14)
                    }
                }

                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        sleepRow("Awake", "38 min", StrandPalette.textTertiary)
                        sleepRow("Light", "3h 47m", StrandPalette.accent)
                        sleepRow("Deep", "1h 34m", StrandPalette.sleepDeep)
                        sleepRow("REM", "2h 21m", StrandPalette.statusPositive)
                    }
                }

                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("Wake events")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("3 brief fictional events · 18 minutes awake after sleep onset")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .reviewSampleContentPadding()
        }
        .background(StrandPalette.surfaceBase)
    }

    private func sleepRow(
        _ title: LocalizedStringKey,
        _ value: LocalizedStringKey,
        _ color: Color
    ) -> some View {
        HStack {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

private struct ReviewSampleMoreView: View {
    let onOpen: (ReviewSampleMoreDestination) -> Void
    let onExit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ReviewSampleBanner(onExit: onExit)

                Text("More")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)

                NoopCard {
                    VStack(spacing: 0) {
                        moreLink(.friends, title: "Friends", icon: "person.2.fill")
                        Divider().overlay(StrandPalette.hairline)
                        moreLink(.privacy, title: "Data Sources & Privacy", icon: "hand.raised.fill")
                        Divider().overlay(StrandPalette.hairline)
                        moreLink(.devices, title: "Devices", icon: "applewatch.radiowaves.left.and.right")
                    }
                }

                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Label("Review isolation", systemImage: "lock.shield.fill")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("No sample value is written to the NOOP database, Apple Health, cloud storage, or a notification schedule.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                NoopButton(
                    "Exit Review Sample",
                    systemImage: "xmark.circle",
                    kind: .secondary,
                    fullWidth: true,
                    action: onExit
                )
            }
            .reviewSampleContentPadding()
        }
        .background(StrandPalette.surfaceBase)
    }

    private func moreLink(
        _ destination: ReviewSampleMoreDestination,
        title: LocalizedStringKey,
        icon: String
    ) -> some View {
        Button(action: { onOpen(destination) }) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: icon)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 26)
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
    }
}

private struct ReviewSampleMoreDetailView: View {
    let destination: ReviewSampleMoreDestination
    let onBack: () -> Void
    let onExit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ReviewSampleBanner(onExit: onExit)

                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("noop.review.back")

                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        Label(title, systemImage: icon)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(detailCopy)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    NoopCard {
                        HStack {
                            Text(row.0)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text(row.1)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
            .reviewSampleContentPadding()
        }
        .background(StrandPalette.surfaceBase)
    }

    private var title: LocalizedStringKey {
        switch destination {
        case .friends: return "Friends"
        case .privacy: return "Data Sources & Privacy"
        case .devices: return "Devices"
        }
    }

    private var icon: String {
        switch destination {
        case .friends: return "person.2.fill"
        case .privacy: return "hand.raised.fill"
        case .devices: return "applewatch.radiowaves.left.and.right"
        }
    }

    private var detailCopy: LocalizedStringKey {
        switch destination {
        case .friends:
            return "The review sample never contacts real people. A fictional circle is shown only to demonstrate consent-first sharing."
        case .privacy:
            return "All permissions and network lanes remain off. The fictional values live only in this view hierarchy and disappear on exit."
        case .devices:
            return "No hardware is connected. Scanning, pairing, commands, and background collection are disabled in Review Sample."
        }
    }

    private var rows: [(LocalizedStringKey, LocalizedStringKey)] {
        switch destination {
        case .friends:
            return [("Sample circle", "3 fictional members"), ("Pokes", "Disabled"), ("Location", "Not shared")]
        case .privacy:
            return [("Bluetooth", "Not requested"), ("Apple Health", "Not requested"), ("Cloud", "Off"), ("Notifications", "Off")]
        case .devices:
            return [("Connected device", "None"), ("Bluetooth scan", "Disabled"), ("Stored hardware data", "None")]
        }
    }
}
#endif
