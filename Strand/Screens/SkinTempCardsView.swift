import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Skin-temperature suite cards (v5 pillar)
//
// Three self-contained, reusable cards built on the underused nightly skin-temperature
// signal, each driven entirely by a pure StrandAnalytics engine RESULT passed in via init
// (Wave 3 runs the engines in the analytics pass and mounts these in the Health hub):
//
//   • CycleAwarenessCard   — CyclePhaseEngine.Result. OPT-IN (period/cycle tracking is the
//                            most sensitive health category). Awareness only — NOT
//                            contraception, NOT a fertility/ovulation predictor, NOT a
//                            diagnosis. Phase + cycle-day RANGE + probabilistic next-period
//                            WINDOW (never a hard date).
//   • BodyClockCard        — CircadianEngine.PhaseEstimate (+ optional JetLagPlan). Estimated
//                            body-clock phase + a jet-lag / shift plan that is LIGHT + SLEEP
//                            TIMING only (never a supplement/drug).
//   • HeadsUpCard          — IllnessSignalEngine.Result. The confounder-suppressed illness
//                            "heads-up". On-device estimate - not a diagnosis.
//
// DESIGN-SYSTEM ONLY: NoopCard + DomainTheme/StrandPalette tokens, StrandFont, NoopMetrics,
// ScoreStatePill, the house buttons. No raw hex, no ad-hoc cards. Privacy-forward copy:
// local by default, with the optional user-owned sync destination stated honestly.
//
// The cards take VALUES, not stores — so a slip here stays local and can't take Health down,
// and the engines stay testable + I/O-free upstream. Wave 3 wiring is documented at the foot.

// MARK: - Shared chrome

/// The standing privacy promise repeated on every sensitive skin-temp surface (the single
/// biggest competitive wedge vs cloud cycle trackers, and the ethical stance).
private let skinTempPrivacyLine =
    String(localized: "Stored and analyzed on this device. Uploaded only if you explicitly enable your own self-hosted sync.")

/// A small, footnote-styled privacy row with a lock glyph — dropped at the foot of each
/// sensitive card so the promise is impossible to miss without shouting.
private struct PrivacyNote: View {
    var text: String = skinTempPrivacyLine
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 1. Cycle awareness card (OPT-IN)

/// Cycle phase awareness from the nightly skin-temperature shift, corroborated by the luteal
/// RHR rise + HRV drop. OPT-IN by design — the host shows this only after the user enables
/// cycle awareness (default OFF). Awareness only; never contraception/fertility/diagnosis.
struct CycleAwarenessCard: View {
    /// The classified result from `CyclePhaseEngine.classify(...)`, computed in the analytics pass.
    let result: CyclePhaseEngine.Result
    /// The nightly fused-index (or temp-deviation) series, oldest→newest, for the sparkline.
    /// Optional — the card is honest with or without a curve.
    var curve: [Double] = []
    /// Called when the user taps "Log period start" (opt-in logged-period mode). nil hides it.
    var onLogPeriod: (() -> Void)? = nil
    /// Called when the user opens the cycle detail screen. nil makes the card non-navigating.
    var onOpenDetail: (() -> Void)? = nil
    /// Called when the user turns cycle awareness OFF from here (#801). nil hides the off control.
    /// Provided so the feature can be turned off in-place exactly where it was turned on (the opt-in
    /// card's "Turn on" lives in the same Health spot), rather than only from Automations.
    var onTurnOff: (() -> Void)? = nil

    // Cycle awareness reads in the calm, NON-VALENCED Rest indigo world (mirroring Mind): a
    // phase is just information, never framed good/bad. No red, ever.
    private var hue: Color { StrandPalette.restColor }

    var body: some View {
        NoopCard(tint: hue) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                header

                // The headline phase line + cycle-day range.
                phaseHeadline

                if !curve.isEmpty, curve.count > 1 {
                    Sparkline(values: curve,
                              gradient: Gradient(colors: [hue.opacity(0.4), StrandPalette.restBright]),
                              showsHover: false)
                        .frame(height: 30)
                        .accessibilityHidden(true)
                }

                // Honest one-line status / next-period window.
                Text(statusLine)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let window = result.nextPeriodWindow {
                    nextPeriodRow(window)
                }

                actions

                Divider().overlay(StrandPalette.hairline)

                // The standing awareness-only legal line (verbatim from the engine) + privacy promise.
                Text(CyclePhaseEngine.awarenessLine)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                PrivacyNote()

                // In-place off control (#801): the toggle is now symmetric, it can be turned off
                // right where it was turned on, not only from Automations. A quiet ghost button so it
                // sits below the awareness/privacy lines without competing with the primary actions.
                if let onTurnOff {
                    Button("Turn off cycle awareness", action: onTurnOff)
                        .buttonStyle(.noopGhost)
                        .accessibilityHint("Stops reading a cycle phase from your nightly temperature. You can turn it back on here any time.")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cycle awareness").strandOverline()
                Text(result.cycleDayLow == nil
                     ? "From your nightly temperature"
                     : "From your logs + nightly temperature")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            ScoreStatePill(scoreState, text: confidenceLabel)
        }
    }

    private var phaseHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(phaseTitle)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            if let dayText = cycleDayText {
                Text(dayText)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityHeadline)
    }

    private func nextPeriodRow(_ window: CyclePhaseEngine.NextPeriodWindow) -> some View {
        // A probabilistic WINDOW, never a single confident date — the copy reflects that.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hue)
                .accessibilityHidden(true)
            Text("A period is likely between \(prettyDay(window.earliestDay)) and \(prettyDay(window.latestDay)) (a window, not a fixed date).")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: NoopMetrics.gap) {
            if let onLogPeriod {
                Button("Log period start", action: onLogPeriod)
                    .buttonStyle(.noopSecondary)
                    .accessibilityHint("Optional. Stored only on this device.")
            }
            if let onOpenDetail {
                Button("View detail", action: onOpenDetail)
                    .buttonStyle(.noopGhost)
            }
        }
    }

    // MARK: derived copy

    private var phaseTitle: String {
        switch result.phase {
        case .follicular:   return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal:       return String(localized: "Luteal")
        case .unknown:      return String(localized: "No clear pattern")
        case .learning:     return String(localized: "Learning your pattern")
        }
    }

    /// "~day 18–22" - always a RANGE, never a single point.
    private var cycleDayText: String? {
        guard let lo = result.cycleDayLow, let hi = result.cycleDayHigh else { return nil }
        return lo == hi ? String(localized: "· ~day \(lo)") : String(localized: "· ~day \(lo)-\(hi)")
    }

    private var statusLine: String { localizedCycleNote(result) }

    private var confidenceLabel: LocalizedStringKey {
        switch result.confidence {
        case .learning: return "Learning"
        case .building: return "Building"
        case .solid:    return "Solid"
        }
    }

    private var scoreState: ScoreState {
        switch result.confidence {
        case .learning: return .calibrating
        case .building: return .building
        case .solid:    return .solid
        }
    }

    private var accessibilityHeadline: String {
        if let lo = result.cycleDayLow, let hi = result.cycleDayHigh {
            return lo == hi
                ? String(localized: "Cycle phase: \(phaseTitle). About day \(lo).")
                : String(localized: "Cycle phase: \(phaseTitle). About day \(lo) to \(hi).")
        }
        return String(localized: "Cycle phase: \(phaseTitle).")
    }
}

// MARK: - Cycle awareness opt-in (empty / disabled states)

/// Shown in place of `CycleAwarenessCard` when the user has NOT opted in. A single calm
/// opt-in card restating the privacy promise at the point of consent (manual-first; default OFF).
struct CycleAwarenessOptInCard: View {
    /// Toggles cycle awareness ON (the host persists the preference, default OFF).
    var onEnable: () -> Void

    var body: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack(spacing: 8) {
                    Image(systemName: "drop.degreesign")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.restColor)
                        .accessibilityHidden(true)
                    Text("Cycle awareness")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                }
                Text("NOOP can estimate a coarse menstrual-cycle phase from nightly skin temperature. On iPhone, turning this on can ask to read cycle-start dates from Apple Health; you can decline and log dates manually. Optional flow and symptom details stay private and are used only as context. Awareness only: not contraception, not a fertility predictor, not a medical service.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                PrivacyNote()
                Button("Turn on cycle awareness", action: onEnable)
                    .buttonStyle(.noopSecondary)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Honest placeholder used while the opt-in recompute is opening the tracker. It never invents a
/// cycle day, phase, cadence, or forecast.
func cycleTrackingLearningResult() -> CyclePhaseEngine.Result {
    CyclePhaseEngine.Result(
        phase: .learning,
        confidence: .learning,
        cycleDayLow: nil,
        cycleDayHigh: nil,
        cycleLengthDays: nil,
        nextPeriodWindow: nil,
        shiftMarkers: [],
        note: "Log a period start and wear Noop Band overnight to begin a private estimate.",
        noteKinds: [.startLogging]
    )
}

/// Circular presentation of the awareness model. The arcs are a phase guide, not fertile/safe days:
/// the only period mark is the user-confirmed day-1 anchor, and the current marker is shown only when
/// the engine has a bounded cycle-day range.
private struct CycleTimelineRing: View {
    let result: CyclePhaseEngine.Result
    let hasLoggedStart: Bool

    private struct Segment {
        let start: Double
        let end: Double
        let color: Color
    }

    private var cycleLength: Int {
        max(result.cycleLengthDays ?? CyclePhaseEngine.defaultCycleDays,
            result.cycleDayHigh ?? 1)
    }

    private var shiftCenter: Int {
        min(max(8, cycleLength - 13), max(8, cycleLength - 7))
    }

    private var segments: [Segment] {
        let midStart = max(2, shiftCenter - 2)
        let midEnd = min(cycleLength - 1, shiftCenter + 2)
        let total = Double(cycleLength)
        return [
            Segment(start: 0, end: Double(midStart - 1) / total,
                    color: StrandPalette.metricCyan),
            Segment(start: Double(midStart - 1) / total, end: Double(midEnd) / total,
                    color: StrandPalette.statusWarning),
            Segment(start: Double(midEnd) / total, end: 1,
                    color: StrandPalette.restColor),
        ]
    }

    private var currentFraction: Double? {
        guard let low = result.cycleDayLow, let high = result.cycleDayHigh else { return nil }
        let midpoint = Double(low + high) / 2
        return min(1, max(0, (midpoint - 1) / Double(cycleLength)))
    }

    private var dayValue: String {
        guard let low = result.cycleDayLow, let high = result.cycleDayHigh else {
            return String(localized: "appwide.cycle.status.learning")
        }
        return low == high ? "\(low)" : "\(low)-\(high)"
    }

    private var phaseTitle: String {
        switch result.phase {
        case .follicular: return String(localized: "appwide.cycle.phase.follicular")
        case .periOvulatory: return String(localized: "appwide.cycle.phase.mid_cycle_shift")
        case .luteal: return String(localized: "appwide.cycle.phase.luteal")
        case .unknown: return String(localized: "appwide.cycle.phase.no_clear_pattern")
        case .learning: return String(localized: "appwide.cycle.phase.building_pattern")
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = max(0, side / 2 - 14)

            ZStack {
                Circle()
                    .stroke(StrandPalette.hairline.opacity(0.7), lineWidth: 18)

                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Circle()
                        .trim(from: min(segment.end, segment.start + 0.008),
                              to: max(segment.start, segment.end - 0.008))
                        .stroke(segment.color,
                                style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }

                if hasLoggedStart {
                    // A rose day-1 mark identifies a confirmed log without guessing period duration.
                    Circle()
                        .fill(StrandPalette.metricRose)
                        .frame(width: 9, height: 9)
                        .position(x: center.x, y: center.y - radius)
                }

                if let fraction = currentFraction {
                    let angle = 2 * Double.pi * fraction - Double.pi / 2
                    Circle()
                        .fill(StrandPalette.surfaceBase)
                        .overlay(Circle().stroke(StrandPalette.textPrimary, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(
                            x: center.x + CGFloat(cos(angle)) * radius,
                            y: center.y + CGFloat(sin(angle)) * radius
                        )
                }

                VStack(spacing: 4) {
                    Text(result.cycleDayLow == nil
                         ? String(localized: "appwide.cycle.ring.cycle")
                         : String(localized: "appwide.cycle.ring.estimated_day"))
                        .font(StrandFont.overline)
                        .tracking(0)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(dayValue)
                        .font(StrandFont.rounded(result.cycleDayLow == nil ? 22 : 32))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(phaseTitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: side * 0.52)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 228)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = String(
            format: String(localized: "appwide.cycle.ring.a11y.phase_format"),
            locale: .current,
            phaseTitle
        )
        if let low = result.cycleDayLow, let high = result.cycleDayHigh {
            label = low == high
                ? String(
                    format: String(localized: "appwide.cycle.ring.a11y.day_format"),
                    locale: .current,
                    label,
                    low
                )
                : String(
                    format: String(localized: "appwide.cycle.ring.a11y.day_range_format"),
                    locale: .current,
                    label,
                    low,
                    high
                )
        }
        if let length = result.cycleLengthDays {
            label = String(
                format: String(localized: "appwide.cycle.ring.a11y.cadence_format"),
                locale: .current,
                label,
                length
            )
        }
        return label
    }
}

private struct CycleTimelineLegend: View {
    let hasLoggedStart: Bool

    private var items: [(String, Color)] {
        var values: [(String, Color)] = [
            (String(localized: "appwide.cycle.phase.follicular"), StrandPalette.metricCyan),
            (String(localized: "appwide.cycle.phase.mid_cycle_shift"), StrandPalette.statusWarning),
            (String(localized: "appwide.cycle.phase.luteal"), StrandPalette.restColor),
        ]
        if hasLoggedStart {
            values.append((String(localized: "appwide.cycle.ring.logged_day_one"),
                           StrandPalette.metricRose))
        }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("appwide.cycle.ring.guide")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(item.1)
                            .frame(width: 7, height: 7)
                        Text(item.0)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cycle tracker detail

/// Local period-start history used to anchor the awareness engine, plus OPTIONAL per-day detail the user
/// types in themselves.
///
/// Scope, stated precisely because this is reproductive-health data:
///   • ALWAYS: one period-start date per cycle (`CycleTrackingStore.Entry`), and whether that anchor was
///     entered in NOOP or imported from Apple Health. Manual and imported sources stay isolated.
///   • OPTIONAL, user-entered only: flow level and symptoms (`CycleTrackingStore.DailyLog`, surfaced by
///     `selectedFlow` / `selectedSymptoms` below). Never imported, never inferred from the wearable, and
///     independently erasable via the "delete flow and symptom entries" control.
///   • NEVER: fertility predictions, contraception data, or any diagnosis.
///
/// This comment previously claimed the store recorded "one date per cycle—not symptoms, flow ...", which
/// stopped being true when optional flow/symptom logging was added. A privacy-scope comment that lies is
/// worse than no comment, because it is what the next reader will trust.
struct CycleTrackerView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let result: CyclePhaseEngine.Result
    var curve: [Double] = []

    @State private var selectedDate = Date()
    @State private var entries: [CycleTrackingStore.Entry] = []
    @State private var dailyLogs: [CycleTrackingStore.DailyLog] = []
    @State private var selectedFlow: CycleTrackingStore.Flow?
    @State private var selectedSymptoms: Set<CycleTrackingStore.Symptom> = []
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteAllDetails = false
    @State private var operationFailed = false

    private var currentResult: CyclePhaseEngine.Result { model.cyclePhase ?? result }
    private var selectedDay: String { Repository.localDayKey(selectedDate) }
    private var alreadyLogged: Bool { entries.contains { $0.day == selectedDay } }
    private var selectedLog: CycleTrackingStore.DailyLog? {
        dailyLogs.first { $0.day == selectedDay }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    statusCard
                    logCard
                    detailsCard
                    historyCard
                    if !dailyLogs.isEmpty {
                        dailyHistoryCard
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(CyclePhaseEngine.awarenessLine)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        PrivacyNote()
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Cycle tracker")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: repo.cycleTrackingSeq) { await reload() }
            .onChangeCompat(of: selectedDate) { _ in loadSelectedDetails() }
            .confirmationDialog("Delete all manually logged period starts?",
                                isPresented: $confirmDeleteAll,
                                titleVisibility: .visible) {
                Button("Delete all manual period history", role: .destructive) {
                    Task { await deleteAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes dates entered in NOOP. Apple Health-imported dates and sensor history are unchanged.")
            }
            .confirmationDialog("Delete all daily cycle details?",
                                isPresented: $confirmDeleteAllDetails,
                                titleVisibility: .visible) {
                Button("Delete all details", role: .destructive) {
                    Task { await deleteAllDetails() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes flow and symptom entries. Period-start dates and wearable history are unchanged.")
            }
            .alert("Couldn’t update cycle history", isPresented: $operationFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing was changed. Please try again after the local database finishes opening.")
            }
        }
    }

    private var statusCard: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("appwide.cycle.ring.current_estimate")
                            .strandOverline()
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        ScoreStatePill(confidenceState, text: confidenceTitle)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("appwide.cycle.ring.current_estimate").strandOverline()
                        ScoreStatePill(confidenceState, text: confidenceTitle)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                CycleTimelineRing(result: currentResult, hasLoggedStart: !entries.isEmpty)
                CycleTimelineLegend(hasLoggedStart: !entries.isEmpty)

                if curve.count > 1 {
                    Sparkline(values: curve,
                              gradient: Gradient(colors: [StrandPalette.restColor.opacity(0.4),
                                                          StrandPalette.restBright]),
                              showsHover: false)
                        .frame(height: 40)
                        .accessibilityHidden(true)
                }
                Text(localizedCycleNote(currentResult))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let window = currentResult.nextPeriodWindow {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.metricRose)
                            .accessibilityHidden(true)
                        Text(
                            String(
                                format: String(localized: "appwide.cycle.period_window_format"),
                                locale: .current,
                                prettyDay(window.earliestDay),
                                prettyDay(window.latestDay)
                            )
                        )
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var confidenceState: ScoreState {
        switch currentResult.confidence {
        case .learning: return .calibrating
        case .building: return .building
        case .solid: return .solid
        }
    }

    private var confidenceTitle: LocalizedStringKey {
        switch currentResult.confidence {
        case .learning: return "appwide.cycle.status.learning"
        case .building: return "appwide.cycle.status.building"
        case .solid: return "appwide.cycle.status.solid"
        }
    }

    private var logCard: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Log a period start").strandOverline()
                DatePicker("Period started on", selection: $selectedDate, in: ...Date(),
                           displayedComponents: .date)
                    .font(StrandFont.body)
                Button(alreadyLogged ? "Already logged" : "Log period start") {
                    Task { await logSelectedDay() }
                }
                .buttonStyle(.noopSecondary)
                .disabled(alreadyLogged)
                Text("This optional date anchors cycle day 1 and is checked against your nightly temperature pattern.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detailsCard: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Daily details").strandOverline()
                Text(prettyDay(selectedDay))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)

                Picker("Flow", selection: $selectedFlow) {
                    Text("Not entered")
                        .tag(Optional<CycleTrackingStore.Flow>.none)
                    ForEach(CycleTrackingStore.Flow.allCases, id: \.self) { flow in
                        Text(flowLabel(flow))
                            .tag(Optional(flow))
                    }
                }
                .pickerStyle(.menu)

                Text("Symptoms")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(CycleTrackingStore.Symptom.allCases, id: \.self) { symptom in
                        Button {
                            if selectedSymptoms.contains(symptom) {
                                selectedSymptoms.remove(symptom)
                            } else {
                                selectedSymptoms.insert(symptom)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: selectedSymptoms.contains(symptom)
                                      ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedSymptoms.contains(symptom)
                                                     ? StrandPalette.restColor
                                                     : StrandPalette.textTertiary)
                                    .accessibilityHidden(true)
                                Text(symptomLabel(symptom))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symptomLabel(symptom))
                        .accessibilityValue(selectedSymptoms.contains(symptom)
                                            ? "Selected" : "Not selected")
                    }
                }

                Button(selectedLog == nil ? "Save daily details" : "Update daily details") {
                    Task { await saveDailyDetails() }
                }
                .buttonStyle(.noopSecondary)
                .disabled(selectedFlow == nil && selectedSymptoms.isEmpty)

                if selectedLog != nil {
                    Button("Clear this day", role: .destructive) {
                        Task { await deleteDailyDetails(selectedDay) }
                    }
                    .buttonStyle(.noopGhost)
                }

                Text("Optional context only. These entries do not diagnose a condition, predict safe or fertile days, or trigger an emergency alert.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var historyCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    Text("Logged starts").strandOverline()
                    Spacer()
                    if entries.contains(where: { $0.source == .manual }) {
                        Button("Delete all") { confirmDeleteAll = true }
                            .buttonStyle(.noopGhost)
                            .foregroundStyle(StrandPalette.statusCritical)
                    }
                }

                if entries.isEmpty {
                    Text("No period starts logged yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    ForEach(Array(entries.reversed()), id: \.day) { entry in
                        HStack {
                            Image(systemName: "drop.fill")
                                .foregroundStyle(StrandPalette.restColor)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prettyDay(entry.day))
                                    .font(StrandFont.bodyNumber)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(entry.source == .manual ? "Entered in NOOP" : "Apple Health")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                            if entry.source == .manual {
                                Button {
                                    Task { await delete(entry.day) }
                                } label: {
                                    Image(systemName: "trash")
                                        .accessibilityLabel("Delete \(prettyDay(entry.day))")
                                }
                                .buttonStyle(.noopGhost)
                                .foregroundStyle(StrandPalette.statusCritical)
                            } else {
                                Image(systemName: "heart.fill")
                                    .font(.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .accessibilityLabel("Managed in Apple Health")
                            }
                        }
                    }
                    if entries.contains(where: { $0.source == .appleHealth }) {
                        Text("Edit or delete Apple Health dates in the Health app. NOOP reconciles them automatically while cycle awareness is on.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var dailyHistoryCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    Text("Daily history").strandOverline()
                    Spacer()
                    Button("Delete all") { confirmDeleteAllDetails = true }
                        .buttonStyle(.noopGhost)
                        .foregroundStyle(StrandPalette.statusCritical)
                }

                ForEach(Array(dailyLogs.reversed().prefix(14)), id: \.day) { log in
                    HStack(alignment: .top, spacing: 10) {
                        Text(prettyDay(log.day))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(dailySummary(log))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func reload() async {
        async let entryRead = repo.periodStartEntries()
        async let detailRead = repo.cycleDailyLogs()
        entries = await entryRead
        dailyLogs = await detailRead
        loadSelectedDetails()
    }

    private func loadSelectedDetails() {
        let log = dailyLogs.first { $0.day == selectedDay }
        selectedFlow = log?.flow
        selectedSymptoms = log?.symptoms ?? []
    }

    private func logSelectedDay() async {
        guard await repo.logPeriodStart(day: selectedDay) else { operationFailed = true; return }
        await model.refreshV5Signals()
    }

    private func delete(_ day: String) async {
        guard await repo.deletePeriodStart(day: day) else { operationFailed = true; return }
        await model.refreshV5Signals()
    }

    private func deleteAll() async {
        guard await repo.deleteAllPeriodStarts() else { operationFailed = true; return }
        await model.refreshV5Signals()
    }

    private func saveDailyDetails() async {
        guard await repo.saveCycleDailyLog(
            day: selectedDay,
            flow: selectedFlow,
            symptoms: selectedSymptoms
        ) else {
            operationFailed = true
            return
        }
        await reload()
    }

    private func deleteDailyDetails(_ day: String) async {
        guard await repo.deleteCycleDailyLog(day: day) else {
            operationFailed = true
            return
        }
        await reload()
    }

    private func deleteAllDetails() async {
        guard await repo.deleteAllCycleDailyLogs() else {
            operationFailed = true
            return
        }
        await reload()
    }

    private func phaseTitle(_ phase: CyclePhaseEngine.Phase) -> String {
        switch phase {
        case .follicular: return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal: return String(localized: "Luteal")
        case .unknown: return String(localized: "No clear pattern")
        case .learning: return String(localized: "Learning your pattern")
        }
    }

    private func prettyDay(_ day: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return day }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func flowLabel(_ flow: CycleTrackingStore.Flow) -> String {
        switch flow {
        case .none: return String(localized: "No bleeding")
        case .spotting: return String(localized: "Spotting")
        case .light: return String(localized: "Light")
        case .medium: return String(localized: "Medium")
        case .heavy: return String(localized: "Heavy")
        }
    }

    private func symptomLabel(_ symptom: CycleTrackingStore.Symptom) -> String {
        switch symptom {
        case .cramps: return String(localized: "Cramps")
        case .headache: return String(localized: "Headache")
        case .fatigue: return String(localized: "Fatigue")
        case .bloating: return String(localized: "Bloating")
        case .moodChanges: return String(localized: "Mood changes")
        case .breastTenderness: return String(localized: "Breast tenderness")
        case .acne: return String(localized: "Acne")
        case .nausea: return String(localized: "Nausea")
        case .backPain: return String(localized: "Back pain")
        case .cravings: return String(localized: "Cravings")
        }
    }

    private func dailySummary(_ log: CycleTrackingStore.DailyLog) -> String {
        var parts: [String] = []
        if let flow = log.flow { parts.append(flowLabel(flow)) }
        if !log.symptoms.isEmpty {
            parts.append(
                log.symptoms.sorted { $0.rawValue < $1.rawValue }
                    .map(symptomLabel)
                    .joined(separator: ", ")
            )
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 2. Body Clock card

/// Estimated body-clock phase + an optional jet-lag / shift plan. The plan is LIGHT + SLEEP
/// TIMING only — never a supplement. Behavioural awareness, approximate.
struct BodyClockCard: View {
    /// The phase estimate from `CircadianEngine.estimatePhase(...)`, computed in the analytics pass.
    let estimate: CircadianEngine.PhaseEstimate
    /// Optional active re-entrainment plan (jet-lag / shift). nil = no plan running.
    var plan: CircadianEngine.JetLagPlan? = nil
    /// Opens the body-clock detail / jet-lag planner. nil makes the card non-navigating.
    var onOpenPlanner: (() -> Void)? = nil

    // The body clock reads in the cool Rest world — calm, sleep-adjacent, non-valenced.
    private var hue: Color { StrandPalette.restColor }

    var body: some View {
        NoopCard(tint: hue) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                header

                offsetHeadline

                Text(estimate.note)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The estimated temperature-minimum clock time — the canonical phase marker.
                HStack(spacing: 6) {
                    Image(systemName: "moon.stars")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hue)
                        .accessibilityHidden(true)
                    Text("Estimated body-clock low around \(clockString(estimate.tempMinHour))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .accessibilityElement(children: .combine)

                if let plan, plan.direction != .none, let firstDay = plan.days.first {
                    Divider().overlay(StrandPalette.hairline)
                    planSummary(plan, firstDay: firstDay)
                }

                if let onOpenPlanner {
                    Button(plan == nil ? "Plan a trip or shift" : "View the full plan", action: onOpenPlanner)
                        .buttonStyle(.noopGhost)
                        .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Body clock").strandOverline()
                Text("Light + sleep timing only")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            ScoreStatePill(scoreState, text: confidenceLabel)
        }
    }

    private var offsetHeadline: some View {
        Text(offsetTitle)
            .font(StrandFont.title2)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(offsetTitle)
    }

    private func planSummary(_ plan: CircadianEngine.JetLagPlan, firstDay: CircadianEngine.DayPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan · \(plan.estimatedDays)-day shift")
                .strandOverline()
            // Day 1's concrete light + lights-out cue — light + sleep timing only.
            Text("Day 1: bright light \(clockString(firstDay.brightLightStartHour))-\(clockString(firstDay.brightLightEndHour)), lights-out around \(clockString(firstDay.targetSleepHour)).")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(plan.note)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: derived copy

    /// "About 25 min later than your schedule" - a plain, skimmable headline.
    private var offsetTitle: String {
        let mins = Int(abs(estimate.offsetVsScheduleMinutes).rounded())
        if estimate.confidence == .unreadable {
            return String(localized: "Hard to read right now")
        }
        if mins <= 20 {
            return String(localized: "About in sync with your schedule")
        }
        return estimate.offsetVsScheduleMinutes > 0
            ? String(localized: "About \(mins) min later than your schedule")
            : String(localized: "About \(mins) min earlier than your schedule")
    }

    private var confidenceLabel: LocalizedStringKey {
        switch estimate.confidence {
        case .unreadable: return "Calibrating"
        case .wide:       return "Building"
        case .solid:      return "Solid"
        }
    }

    private var scoreState: ScoreState {
        switch estimate.confidence {
        case .unreadable: return .calibrating
        case .wide:       return .building
        case .solid:      return .solid
        }
    }

    /// Render a fractional clock hour as "HH:MM" (locale-free, matching the engine's own helper).
    private func clockString(_ hour: Double) -> String {
        var h = hour.truncatingRemainder(dividingBy: 24)
        if h < 0 { h += 24 }
        var hh = Int(h)
        var mm = Int(((h - Double(hh)) * 60).rounded())
        if mm == 60 { mm = 0; hh = (hh + 1) % 24 }
        return String(format: "%02d:%02d", hh, mm)
    }
}

// MARK: - 3. Heads-Up card (illness early-warning, confounder-suppressed)

/// The confounder-suppressed illness "heads-up". Renders the engine's already-decided level +
/// copy; the host only mounts it when the engine returns a non-quiet level. On-device estimate
/// — not a diagnosis. Mirrors the existing amber HealthAlertBanner treatment.
struct HeadsUpCard: View {
    /// The decision from `IllnessSignalEngine.evaluate(...)`, computed in the analytics pass.
    let result: IllnessSignalEngine.Result
    /// Optional parallel Mahalanobis distance (IllnessDistance), computed on the SAME z-vector. It does
    /// NOT gate this card (the engine's level already did); when the level is raised and a distance is
    /// present we append a subtle "Confidence" line so the user can gauge how strong the signal is.
    var distance: IllnessDistance.Result? = nil

    var body: some View {
        NoopCard(padding: 14, tint: hue) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: glyph)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(hue)
                        .frame(width: 30, height: 30)
                        .background(hue.opacity(0.16), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(result.copy)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                // The visible "why": which signals fired. Explainability is what earns trust.
                if !result.firedSignals.isEmpty {
                    whyRow(label: "Signals up", values: result.firedSignals, tint: hue)
                }
                // Nearby context can move the same signals; surface it without claiming causation.
                if !result.suppressedBy.isEmpty {
                    whyRow(label: "Also logged", values: result.suppressedBy, tint: StrandPalette.textTertiary)
                }
                // Optional confidence read from the parallel Mahalanobis distance, only when the level is
                // raised. Subtle by design: it augments, never gates (the engine already decided to raise).
                if let confidence = confidenceLine {
                    Text(confidence)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(result.copy)")
    }

    private func whyRow(label: LocalizedStringKey, values: [String], tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).strandOverline()
            // Each fired signal / confounder as a quiet chip.
            FlowChips(values: values, tint: tint)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: derived presentation

    /// The card hue follows the level: raised/already-unwell = amber warning (matches the
    /// shipped banner); suppressed/mild = a calmer neutral so it never scares.
    private var hue: Color {
        switch result.level {
        case .raised, .alreadyUnwell: return StrandPalette.statusWarning
        case .suppressed, .mild:      return StrandPalette.restColor
        case .quiet:                  return StrandPalette.restColor
        }
    }

    private var glyph: String {
        switch result.level {
        case .raised:        return "exclamationmark.triangle.fill"
        case .alreadyUnwell: return "bed.double.fill"
        case .suppressed:    return "info.circle.fill"
        case .mild:          return "waveform.path"
        case .quiet:         return "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch result.level {
        case .raised:        return String(localized: "Heads-up")
        case .alreadyUnwell: return String(localized: "Rest up")
        case .suppressed:    return String(localized: "Related context found")
        case .mild:          return String(localized: "A few signals are up")
        case .quiet:         return String(localized: "Nothing notable")
        }
    }

    /// A subtle confidence read from the parallel Mahalanobis distance, surfaced ONLY on the RAISED state
    /// (and when a distance is present). nil otherwise. The already-unwell state is driven purely by the
    /// user's own log and can have a near-zero distance (0-1 present features), giving a misleading
    /// "Confidence: slight (distance 0.0)", so it's excluded. The raised path always has >= 2 present
    /// features, so its distance is meaningful. The band mirrors Android exactly. (Augment-only, never gates.)
    private var confidenceLine: String? {
        guard result.level == .raised,
              let d = distance else { return nil }
        return String(localized: "Confidence: \(IllnessConfidence.band(d.distance)) (distance \(IllnessConfidence.formatted(d.distance)))")
    }
}

// MARK: - Illness confidence band (shared wording, mirrored byte-for-byte on Android)

/// Maps the parallel Mahalanobis distance to a plain confidence word + a one-decimal display value.
/// This is presentation-only: it NEVER decides whether the Heads-Up card shows (the engine's level
/// already did). Bands: >= 3.5 strong, >= 2.5 moderate, else slight. Identical to the Kotlin twin.
enum IllnessConfidence {
    static func band(_ distance: Double) -> String {
        if distance >= 3.5 { return String(localized: "strong") }
        if distance >= 2.5 { return String(localized: "moderate") }
        return String(localized: "slight")
    }
    static func formatted(_ distance: Double) -> String {
        String(format: "%.1f", distance)
    }
}

// MARK: - Small chip flow (shared by Heads-Up)

/// A wrapping row of small tinted chips. Used for fired signals / confounders so a long list
/// never clips. Decorative wrapping; the parent combines it into one VoiceOver stop.
private struct FlowChips: View {
    let values: [String]
    var tint: Color = StrandPalette.textTertiary
    var body: some View {
        // A simple wrapping HStack via a flexible layout; for the small counts here a plain
        // HStack with wrapping fallback is enough and avoids a custom Layout dependency.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }
    @ViewBuilder private var chips: some View {
        ForEach(values, id: \.self) { v in
            Text(v)
                .font(StrandFont.captionNumber)
                .foregroundStyle(tint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(tint.opacity(0.14), in: Capsule(style: .continuous))
        }
    }
}

private func localizedCycleNote(_ result: CyclePhaseEngine.Result) -> String {
    guard !result.noteKinds.isEmpty else { return result.note }
    return result.noteKinds.map(localizedCycleNote).joined(separator: " ")
}

private func localizedCycleNote(_ kind: CyclePhaseEngine.NoteKind) -> String {
    switch kind {
    case .learningNightly:
        return String(localized: "appwide.cycle.note.learning_nightly")
    case .noClearPattern:
        return String(localized: "appwide.cycle.note.no_clear_pattern")
    case .noClearContext:
        return String(localized: "appwide.cycle.note.no_clear_context")
    case .logShiftMismatch:
        return String(localized: "appwide.cycle.note.log_shift_mismatch")
    case .phaseFollicular:
        return String(localized: "appwide.cycle.note.phase_follicular")
    case .phaseMidCycle:
        return String(localized: "appwide.cycle.note.phase_mid_cycle")
    case .phaseLuteal:
        return String(localized: "appwide.cycle.note.phase_luteal")
    case .staleLog:
        return String(localized: "appwide.cycle.note.stale_log")
    case .unreliableLogs:
        return String(localized: "appwide.cycle.note.unreliable_logs")
    case .forecastPassed:
        return String(localized: "appwide.cycle.note.forecast_passed")
    case .broadPrior:
        return String(localized: "appwide.cycle.note.broad_prior")
    case .personalIntervals:
        return String(localized: "appwide.cycle.note.personal_intervals")
    case .startLogging:
        return String(localized: "appwide.cycle.note.start_logging")
    case .turnOnAwareness:
        return String(localized: "appwide.cycle.note.turn_on_awareness")
    }
}

// MARK: - Day formatting

/// "12 Jun" from a "yyyy-MM-dd" key (locale-aware for display only; the engine math stays UTC).
private func prettyDay(_ key: String) -> String {
    let parts = key.split(separator: "-")
    guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m) else { return key }
    let months = [String(localized: "Jan"), String(localized: "Feb"), String(localized: "Mar"),
                  String(localized: "Apr"), String(localized: "May"), String(localized: "Jun"),
                  String(localized: "Jul"), String(localized: "Aug"), String(localized: "Sep"),
                  String(localized: "Oct"), String(localized: "Nov"), String(localized: "Dec")]
    return "\(d) \(months[m - 1])"
}

#if DEBUG
#Preview("Skin-temp cards") {
    ScrollView {
        VStack(spacing: NoopMetrics.sectionGap) {
            CycleAwarenessCard(
                result: CyclePhaseEngine.Result(
                    phase: .luteal, confidence: .solid,
                    cycleDayLow: 20, cycleDayHigh: 24, cycleLengthDays: 28,
                    nextPeriodWindow: .init(earliestDay: "2026-06-24", latestDay: "2026-06-28"),
                    shiftMarkers: [], note: "Luteal range - temperature is running above your baseline."),
                curve: (0..<60).map { 0.1 * sin(Double($0) / 9) + 0.05 },
                onLogPeriod: {}, onOpenDetail: {})

            CycleAwarenessOptInCard(onEnable: {})

            BodyClockCard(
                estimate: CircadianEngine.PhaseEstimate(
                    tempMinHour: 5.2, acrophaseHours: 16.0, offsetVsScheduleMinutes: 38,
                    confidence: .solid, note: "Your body clock looks later (a night-owl lean)."),
                plan: CircadianEngine.JetLagPlan(
                    direction: .advance, totalShiftHours: 3, estimatedDays: 3,
                    days: [.init(dayIndex: 1, brightLightStartHour: 7, brightLightEndHour: 9,
                                 dimFromHour: 21, targetSleepHour: 22.75, targetWakeHour: 6.5,
                                 guidance: "")],
                    note: "Shifting your clock 3.0 h earlier, about an hour a day. Light and sleep timing only."),
                onOpenPlanner: {})

            HeadsUpCard(result: IllnessSignalEngine.Result(
                score: 64, level: .raised,
                firedSignals: ["RHR +6", "HRV −22%", "skin temp +0.7 °C"],
                suppressedBy: [], signalCount: 3,
                copy: "Several signals shifted together - RHR +6, HRV −22%, skin temp +0.7 °C. Many things can cause this pattern; review how you feel and consider a gentler day."))

            HeadsUpCard(result: IllnessSignalEngine.Result(
                score: 28, level: .suppressed,
                firedSignals: ["RHR +5", "skin temp +0.6 °C"],
                suppressedBy: ["alcohol"], signalCount: 2,
                copy: "Some signals are up (RHR +5, skin temp +0.6 °C), but you logged alcohol - likely that, not illness. On-device estimate - not a diagnosis."))
        }
        .padding(NoopMetrics.screenPadding)
    }
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
