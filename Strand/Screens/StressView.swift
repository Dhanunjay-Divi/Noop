import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Daily autonomic load
//
// This screen presents NOOP's experimental, non-clinical 0–3 autonomic-load
// estimate. It is derived locally from resting HR and HRV against strictly prior
// personal days through `DailyAutonomicLoad`; it is not an emotional-stress
// measurement, a diagnosis, or an attempt to reproduce WHOOP's proprietary score.
// Every historical point has its own causal baseline, so later data cannot rewrite it.

struct StressView: View {
    @EnvironmentObject var repo: Repository
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = SkyBehindCardsPrefs.defaultEnabled

    @State private var loaded = false
    /// Trend window for the chart (W/M/3M/6M/1Y/ALL).
    @State private var range: ExploreRange = .month

    /// Today's intraday stress read (hourly timeline + sustained-high flag), computed
    /// from the day's banked HR + R-R via the SAME 0–3 proxy the daily score uses. Nil
    /// until the async read completes; `.empty` when the day has no usable intraday HR.
    @State private var daytime: DaytimeStress.Result?
    /// Drives the Breathe sheet presented from the sustained-stress suggestion.
    @State private var showBreathe = false

    /// ADDITIVE, on-demand advanced readouts, computed live from the SAME day's R-R the
    /// daytime timeline already reads. These do NOT feed the 0..3 score or the timeline; they
    /// are two extra, clearly-labelled HRV lenses surfaced in their own card. Nil until the
    /// async read completes, and individually nil when their span/beat gates are not met.
    /// Baevsky Stress Index components (si / Mo / AMo / MxDMn).
    @State private var stressIndex: StressIndex.Components?
    /// Frequency-domain HRV bands (LF / HF / LF-HF / total power).
    @State private var freqHRV: HRVFreqDomain.Bands?

    /// Cached StressModel + the input signature it was built from. Rebuilding the
    /// model is expensive (z-score derivation + per-day date parsing over the full
    /// history), so we recompute it only when its inputs actually change — NOT on
    /// every body re-eval (hover / animation / 1 Hz HR ticks).
    @State private var model: StressModel?
    @State private var modelSignature: StressInputs?

    var body: some View {
        ScreenScaffold(title: "Autonomic Load", subtitle: "Your physiology relative to your own recent baseline",
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       lazy: true,
                       // The day-of-sky liquid backdrop, matching Today / Health / Live / Sleep / Trends: a
                       // fixed, full-bleed time-of-day sky behind the scroll content (does not scroll), so the
                       // Stress screen sits in the same liquid atmosphere as every other tab.
                       topBackground: liquidScaffoldSky()) {
            if let model {
                content(model)
            } else if !loaded {
                ComingSoon(what: "Reading your heart-rate variability and resting heart rate…")
            } else {
                calibrationState(StressModel.preferredAssessment(sourceRows: repo.vitalMetricRows))
            }
        }
        .onAppear { rebuildModelIfNeeded() }
        .onChangeCompat(of: repo.days) { _ in rebuildModelIfNeeded() }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func load() async {
        loaded = true
        rebuildModelIfNeeded()
        await loadDaytime()
    }

    /// Read TODAY's banked HR + R-R and build the intraday stress timeline. Local-day
    /// window [midnight, now]; the helper buckets it into waking hours and reuses the
    /// daily score's math, so this is the same proxy at a finer grain — never a new score.
    private func loadDaytime() async {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: Date())

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        // Too few HR samples: empty the timeline AND clear the advanced readouts in lockstep. Without this
        // reset a later refresh that hits this path would leave the Advanced HRV card showing stale values
        // next to an empty timeline (the readouts are only recomputed past this guard).
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            daytime = .empty
            stressIndex = nil
            freqHRV = nil
            return
        }
        let rr = (try? await repo.storeHandle()?.rrIntervals(
            deviceId: repo.deviceId, from: from, to: to, limit: 200_000)) ?? []

        daytime = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: tz)

        // ADDITIVE advanced readouts, computed on-demand from the SAME `rr` (no extra fetch, no
        // DB / schema change, and no effect on the 0..3 score above). Each engine returns nil when
        // its own gate is not met (Baevsky needs >= 20 clean beats; freq-HRV needs >= 60 s span),
        // in which case its row is simply hidden.
        stressIndex = StressIndex.components(rr: rr)
        freqHRV = HRVFreqDomain.freqDomain(rr: rr)
    }

    /// Recompute the cached `StressModel` only when daily inputs
    /// actually changed since the last build. Equality is an O(n) value compare,
    /// far cheaper than the model rebuild it guards.
    private func rebuildModelIfNeeded() {
        let signature = StressInputs(rows: repo.vitalMetricRows)
        guard signature != modelSignature else { return }
        modelSignature = signature
        model = StressModel(sourceRows: repo.vitalMetricRows)
    }

    // MARK: Loaded content

    @ViewBuilder
    private func content(_ model: StressModel) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {

            // 1. HERO — the liquid stress-level vessel + band + one plain-English line, all in one card.
            heroCard(model)
                .staggeredAppear(index: 0)

            // 1b. ADVANCED HRV readouts (additive, on-demand). A separate, clearly-labelled card
            //     that appears only when at least one engine returned a value. It sits BELOW the
            //     hero and never alters the hero, the markers or the timeline.
            if hasAdvancedReadouts {
                advancedReadoutsCard()
                    .staggeredAppear(index: 1)
            }

            // 2. Today's numbers — uniform tiles in one grid.
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Latest Read", overline: "Markers",
                              trailing: String(localized: "vs prior baseline"))
                tileGrid(model)
            }
            .staggeredAppear(index: 1)

            // 3. Today's intraday timeline — when in the day stress ran high, + a
            //    passive Breathe suggestion when the recent hours stay elevated.
            if let daytime, !daytime.scored.isEmpty {
                daytimeSection(daytime)
                    .staggeredAppear(index: 2)
            }

            // 4. Trend over the chosen window.
            trendSection(model)
                .staggeredAppear(index: 3)

            // 5. Transparency — how the number is built.
            methodologyCard(model)
                .staggeredAppear(index: 4)
        }
        // The sustained-stress suggestion opens the existing Breathe trainer in a sheet —
        // in-app and passive (no alert / notification), inheriting the app environment.
        .sheet(isPresented: $showBreathe) {
            NavigationStack {
                BreathingView()
                    .toolbar {
                        ToolbarItem {
                            Button("Done") { showBreathe = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(width: 520, height: 760)
            #endif
        }
    }

    // MARK: 3 · Daytime timeline (intraday, same 0–3 proxy)

    @ViewBuilder
    private func daytimeSection(_ day: DaytimeStress.Result) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Today's Timeline", overline: "Intraday",
                          trailing: timelineTrailing(day))

            NoopCard(tint: StressRamp.calm) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    HStack {
                    Text("Intraday autonomic load").strandOverline()
                        Spacer()
                        if let peak = day.peak, let lvl = peak.level {
                            Text("peak \(String(format: "%.1f", lvl)) · \(hourLabel(peak.hour))")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StressRamp.color(lvl))
                        }
                    }

                    // README screen-9: the day autonomic-load LINE, drawn with the same
                    // 3-stop blue→green→amber WHOOP gradient as the gauge.
                    DaytimeLoadLine(hours: day.hours)

                    // Hour ruler under the line (first / midday / last covered hour).
                    if let lo = day.hours.first?.hour, let hi = day.hours.last?.hour {
                        HStack {
                            Text(hourLabel(lo)).font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer()
                            Text(hourLabel((lo + hi) / 2)).font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer()
                            Text(hourLabel(hi)).font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }

                    Divider().overlay(StrandPalette.hairline)

                    // README screen-9: the Calm / Moderate / High totals bar — one stacked
                    // bar split by how many waking hours sat in each band, with durations.
                    StressTotalsBar(totals: StressTotals(hours: day.hours))

                    Text("This separate intraday proxy uses available waking-hour signals from today. It is experimental, may have gaps, and does not measure emotional stress.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Sustained-high suggestion — only when the recent run stays in the HIGH band.
            if day.sustainedHigh { sustainedBreatheCard(day) }
        }
    }

    /// "avg 1.4 · 9h" summary for the timeline header, from the scored hours.
    private func timelineTrailing(_ day: DaytimeStress.Result) -> String {
        let n = day.scored.count
        guard let mean = day.dayMean else { return String(localized: "\(n)h") }
        return String(localized: "avg \(String(format: "%.1f", mean)) · \(n)h")
    }

    /// A passive, in-app nudge to run a Breathe session after a sustained high-stress run.
    /// No notification — just a card with a CTA that opens the existing trainer.
    private func sustainedBreatheCard(_ day: DaytimeStress.Result) -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.rowSpacing) {
                    Image(systemName: "lungs.fill")
                        .foregroundStyle(StressRamp.calm)
                    Text("Sustained elevated load").strandOverline()
                    Spacer()
                    StatePill("\(day.sustainedRun)h elevated", tone: .warning, showsDot: true)
                }
                Text("Several adjacent, R-R-supported windows are elevated relative to today's calmer hours. If it feels useful, try a short paced-breathing session and reassess how you feel.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Start a Breathe session", systemImage: "wind",
                           kind: .primary, fullWidth: true) {
                    showBreathe = true
                }
            }
        }
        .softCardTransition()
    }

    /// Hour-of-day label following the device's locale + 12-/24-hour preference ("2 PM" / "14 Uhr"),
    /// instead of a hard-coded English "am/pm" (which read "3 pm" for 24-hour locales like German).
    private func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: 1 · Hero — the liquid stress-level vessel.
    //
    // The 0–3 load estimate reads as the signature liquid gauge: a LiquidVessel that fills to score/3
    // and is tinted by the live band (calm blue → steady green → tense amber), with the count-up value +
    // "of 3" over it (the Today HeroScoreCell / Live BPM-gauge idiom). The band pill sits top-trailing and
    // one plain-English line explains the number below. Frosted card, liquid finish.

    private func heroCard(_ model: StressModel) -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    Text("NOOP autonomic load").strandOverline()
                    Spacer()
                    StatePill("\(model.band.title)", tone: model.band.tone, showsDot: true)
                }

                HStack(alignment: .center, spacing: NoopMetrics.space5) {
                    // The stress-level vessel: fills to score/3, tinted to the live band, the value
                    // counting up over it. Taps splash the gauge (the numeral is hit-transparent).
                    StressHeroGauge(score: model.score, tint: StressRamp.color(model.score))

                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text(model.band.title)
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StressRamp.color(model.score))
                        // One plain-English line beside the gauge.
                        Text(model.explanation)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                Divider().overlay(StrandPalette.hairline)
                HStack(spacing: NoopMetrics.space2) {
                    Label(model.confidenceTitle, systemImage: model.confidenceSystemImage)
                        .foregroundStyle(model.confidenceColor)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(model.provenanceSummary)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .font(StrandFont.footnote)
                .lineLimit(2)
            }
        }
    }

    // MARK: 1b · Advanced HRV readouts (additive, on-demand)
    //
    // Two extra, clearly-labelled lenses on the SAME day's R-R the timeline already reads, surfaced
    // in their own card so they are visibly separate from the 0..3 monitor. Each row is shown only
    // when its engine produced a value (the engines self-gate on clean-beat count / record span),
    // and the whole card is gated by `hasAdvancedReadouts`. Nothing here feeds the score.

    /// True when at least one advanced readout is presentable (an SI value, or an LF/HF ratio, or
    /// at least the HF power). Drives whether the advanced card is shown at all.
    private var hasAdvancedReadouts: Bool {
        if stressIndex != nil { return true }
        if let f = freqHRV, f.lfhf != nil || f.hf > 0 { return true }
        return false
    }

    @ViewBuilder
    private func advancedReadoutsCard() -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    Text("Advanced HRV").strandOverline()
                    Spacer()
                    Text("on demand · today's R-R")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                    alignment: .leading,
                    spacing: NoopMetrics.gap
                ) {
                    // Baevsky Stress Index, a whole number; higher means a more rigid, stressed rhythm.
                    if let si = stressIndex {
                        StatTile(
                            label: "Baevsky rhythm index",
                            value: "\(Int(si.si.rounded()))",
                            systemImage: "gauge.with.dots.needle.67percent",
                            caption: String(localized: "A rhythm-derived research index affected by posture, breathing and signal quality; it is not diagnostic."),
                            accent: StressRamp.tense
                        )
                    }

                    // Frequency-domain HRV: prefer the LF/HF ratio; if the span was too short for
                    // LF (lfhf nil) fall back to the HF (rest) band power so the lens still reads.
                    if let f = freqHRV {
                        if let ratio = f.lfhf {
                            StatTile(
                                label: "LF/HF ratio",
                                value: String(format: "%.1f", ratio),
                                systemImage: "waveform.path.ecg",
                                caption: String(localized: "A frequency-domain ratio affected by breathing, posture and recording conditions. It does not cleanly separate sympathetic and parasympathetic activity."),
                                accent: StressRamp.steady
                            )
                        } else if f.hf > 0 {
                            StatTile(
                                label: "HF power",
                                value: "\(Int(f.hf.rounded()))",
                                systemImage: "heart.text.square.fill",
                                caption: String(localized: "High-frequency variability power, influenced by breathing and recording conditions."),
                                accent: StressRamp.steady
                            )
                        }
                    }
                }

                Text("These exploratory R-R readouts do not change NOOP's daily estimate. They are non-clinical and do not measure emotional stress.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 2 · Today's tiles (uniform grid)

    private func tileGrid(_ model: StressModel) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
            alignment: .leading,
            spacing: NoopMetrics.gap
        ) {
            // Latest experimental daily autonomic-load value, with its band as the caption.
            StatTile(
                label: "Autonomic load",
                value: String(format: "%.1f", model.score),
                systemImage: "gauge.with.dots.needle.50percent",
                caption: String(localized: "of 3 · \(model.band.title)"),
                accent: StressRamp.color(model.score),
                sparkline: model.sparkValues.count > 1 ? model.sparkValues : nil,
                sparkColor: StressRamp.color(model.score)
            )
            // Resting HR — an INCREASE is the stressful direction.
            markerTile(
                label: "Resting HR",
                value: model.rhrToday.map { String(localized: "\($0) bpm") } ?? "-",
                systemImage: "heart.text.square.fill",
                delta: model.rhrDelta,
                accent: StrandPalette.metricRose,
                higherIsStress: true
            )
            // HRV — a DECREASE is the stressful direction.
            markerTile(
                label: "HRV",
                value: model.hrvToday.map { String(localized: "\(Int($0.rounded())) ms") } ?? "-",
                systemImage: "waveform.path.ecg",
                delta: model.hrvDelta,
                accent: StrandPalette.metricPurple,
                higherIsStress: false
            )
            // Estimated low-load share among recent scorable days.
            StatTile(
                label: "Low-load days",
                value: model.calmTimeValue,
                systemImage: "wind",
                caption: model.calmTimeCaption,
                accent: StressRamp.calm
            )
        }
    }

    /// A vs-baseline marker as a fixed-height StatTile. The delta is tinted by
    /// whether the move is toward stress (warning) or recovery (positive).
    private func markerTile(
        label: LocalizedStringKey,
        value: String,
        systemImage: String,
        delta: Double?,
        accent: Color,
        higherIsStress: Bool
    ) -> some View {
        let deltaText: String?
        let deltaColor: Color
        if let delta, abs(delta) >= 0.5 {
            let up = delta > 0
            let isStressful = (up == higherIsStress)
            deltaText = String(localized: "\(up ? "+" : "−")\(Int(abs(delta).rounded())) vs base")
            deltaColor = isStressful ? StrandPalette.statusWarning : StrandPalette.statusPositive
        } else {
            deltaText = String(localized: "at baseline")
            deltaColor = StrandPalette.textTertiary
        }
        return StatTile(
            label: label,
            value: value,
            systemImage: systemImage,
            caption: nil,
            accent: accent,
            delta: deltaText,
            deltaColor: deltaColor
        )
    }

    // MARK: 3 · Trend (range-controlled)

    @ViewBuilder
    private func trendSection(_ model: StressModel) -> some View {
        let points = windowedTrend(model)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Autonomic Load Trend", overline: "History", trailing: range.name)
            if points.count >= 2 {
                let avg = points.map(\.value).reduce(0, +) / Double(points.count)
                // Axis top = highest reading rounded up, plus a little headroom, so a peak curve and
                // the top axis label clear the plot clip (#974). Floor of 1 keeps a flat calm history
                // from collapsing to a zero-height axis. The gradient stays on the full 0–3 scale
                // because TrendChart keys its colors off `valueRange`, not this domain.
                let peak = (points.map(\.value).max() ?? 3).rounded(.up)
                let yTop = max(1, peak + 0.3)
                ChartCard(
                    title: "NOOP Load · \(range.label)",
                    subtitle: String(localized: "Causal daily 0-3 estimate"),
                    trailing: String(localized: "avg \(String(format: "%.1f", avg))"),
                    tint: StressRamp.calm
                ) {
                    TrendChart(
                        points: points,
                        gradient: StressRamp.gradient,
                        valueRange: 0...3,
                        showsArea: true,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { String(format: "%.1f", $0) },
                        accessibilityLabel: String(localized: "NOOP autonomic load trend"),
                        yDomain: 0...yTop
                    )
                } footer: {
                    ChartFooter([
                        ("Today", String(format: "%.1f", model.score)),
                        ("Average", String(format: "%.1f", avg)),
                        ("Days", "\(points.count)"),
                    ])
                }
                // The one segmented control. Its eight options use the shared adaptive-width mode so
                // the control stays inside the same page gutter as the chart on compact iPhones.
                SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                     adaptsToAvailableWidth: true) { $0.label }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                NoopCard(tint: StressRamp.calm) {
                    Text("A trend appears after multiple days pass the baseline and signal-quality gates.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// The full daily proxy trend, sliced to the selected trailing window. Falls
    /// back to ALL when the trailing slice holds < 2 points.
    private func windowedTrend(_ model: StressModel) -> [TrendPoint] {
        let all = model.fullTrend
        guard let days = range.days, let last = all.last?.date else { return all }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        let slice = all.filter { $0.date >= cutoff }
        return slice.count >= 2 ? slice : all
    }

    // MARK: 4 · Methodology (transparency)

    private func methodologyCard(_ model: StressModel) -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("How this is computed").strandOverline()
                Text("NOOP experimental autonomic-load estimate")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("For each day, NOOP compares resting heart rate and HRV with up to 30 strictly earlier personal days. A signal contributes only after at least 7 valid prior days and measurable baseline variation. Later data never rewrites an older point, and NOOP never fills missing evidence with a neutral 1.5.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    methodologyFact("As of", model.asOfDisplay)
                    methodologyFact("Confidence", model.confidenceTitle)
                    methodologyFact("Baseline", "\(model.baselineDays)d")
                }
                Text("Inputs used: \(model.observedInputsTitle). This is a wellness estimate, not emotional stress, a diagnosis, or WHOOP score parity. Illness, alcohol, training, sleep, breathing, posture, medication and sensor quality can all affect these signals.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.limitationSummary.isEmpty {
                    Text(model.limitationSummary)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(StrandPalette.hairline)
                HStack(spacing: 0) {
                    bandLegend("0-1", String(localized: "LOW"), StressRamp.calm)
                    bandLegend("1-2", String(localized: "MEDIUM"), StressRamp.steady)
                    bandLegend("2-3", String(localized: "HIGH"), StressRamp.tense)
                }
            }
        }
    }

    private func bandLegend(_ range: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                Text(range).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func methodologyFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(StrandFont.overline)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty state

    private func calibrationState(_ assessment: StressModel.SourceAssessment) -> some View {
        let readout = assessment.readout
        let count = readout.baselineDays
        let progress = min(Double(count) / Double(DailyAutonomicLoad.minimumBaselineDays), 1)
        return VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            NoopCard(tint: StressRamp.calm) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    HStack {
                        Text("CALIBRATING").strandOverline()
                        Spacer()
                        StatePill("\(count)/\(DailyAutonomicLoad.minimumBaselineDays)", tone: .warning, showsDot: true)
                    }
                    Text(calibrationTitle(readout))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(calibrationMessage(readout))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: progress)
                        .tint(StressRamp.calm)
                    Text("\(count) valid prior day\(count == 1 ? "" : "s") available · minimum \(DailyAutonomicLoad.minimumBaselineDays)")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(assessment.title)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                    if let note = assessment.note {
                        Text(note)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            NoopCard(tint: StressRamp.calm) {
                Text("NOOP waits for enough personal history and real baseline variation rather than inventing a score. The estimate is experimental, non-clinical, and is not emotional stress or WHOOP score parity.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func calibrationTitle(_ readout: DailyAutonomicLoad.Readout) -> String {
        if readout.limitations.contains(.targetSignalsMissing) {
            return String(localized: "Waiting for a daily signal")
        }
        if readout.limitations.contains(.restingHeartRateBaselineHasNoSpread)
            || readout.limitations.contains(.heartRateVariabilityBaselineHasNoSpread) {
            return String(localized: "More natural variation needed")
        }
        return String(localized: "Building your personal baseline")
    }

    private func calibrationMessage(_ readout: DailyAutonomicLoad.Readout) -> String {
        if readout.limitations.contains(.targetSignalsMissing) {
            return String(localized: "Wear a supported device through sleep so NOOP can observe resting heart rate or HRV.")
        }
        if readout.limitations.contains(.restingHeartRateBaselineHasNoSpread)
            || readout.limitations.contains(.heartRateVariabilityBaselineHasNoSpread) {
            return String(localized: "There is enough history, but the available baseline is too flat for a meaningful standardized comparison. NOOP will keep collecting rather than showing a made-up neutral value.")
        }
        let remaining = max(0, DailyAutonomicLoad.minimumBaselineDays - readout.baselineDays)
        return String(localized: "Collect \(remaining) more valid prior day\(remaining == 1 ? "" : "s") for the first evidence-backed estimate.")
    }
}

// MARK: - Stress hero gauge (liquid vessel + count-up score)

/// The stress-level vessel: a LiquidVessel filled to `score`/3 and tinted to the live band, with the
/// 0–3 value counting up over it and "of 3" beneath (the Today HeroScoreCell / Live BPM-gauge idiom).
/// CountUpText self-animates the number roll; the numeral is hit-transparent so a tap reaches the
/// vessel and splashes it.
private struct StressHeroGauge: View {
    let score: Double        // 0–3
    let tint: Color

    private var frac: Double { max(0, min(1, score / 3.0)) }

    var body: some View {
        ZStack {
            LiquidVessel(value: frac, tint: tint, animated: true)
                .frame(width: 104, height: 104)
            VStack(spacing: 0) {
                // CountUpText self-animates (counts up from 0 on appear, re-rolls on value change),
                // so the score is passed straight through — no external roll state needed.
                CountUpText(
                    value: score,
                    format: { String(format: "%.1f", $0) },
                    font: StrandFont.rounded(34, weight: .bold),
                    color: .white
                )
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                Text("of 3")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.onDarkSecondary)
            }
            .allowsHitTesting(false)   // taps fall through to the vessel → splash
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stress \(String(format: "%.1f", score)) of 3")
    }
}

// MARK: - Stress band

enum StressBand {
    case low, medium, high

    init(score: Double) {
        switch score {
        case ..<1.0: self = .low
        case ..<2.0: self = .medium
        default:     self = .high
        }
    }

    var title: String {
        switch self {
        case .low:    return String(localized: "LOW")
        case .medium: return String(localized: "MEDIUM")
        case .high:   return String(localized: "HIGH")
        }
    }

    var tone: StrandTone {
        switch self {
        case .low:    return .positive
        case .medium: return .warning
        case .high:   return .critical
        }
    }
}

// MARK: - Autonomic-load ramp (blue → green → amber)
//
// The screen's one ramp: lower load reads blue, mid-range green, and higher load amber. The
// semicircle gauge fill, the day autonomic-load line, the Calm/Moderate/High totals bar
// and the trend all sample this SAME ramp, so the colour language is identical across
// the screen. Never the gold or red→green recovery ramp.

enum StressRamp {
    /// Band anchors, lifted from the shared palette (no hard-coded hex). These are the
    /// blue / green / amber the totals legend and band dots use, kept in lock-step with
    /// the gauge gradient below.
    static let calm    = StrandPalette.accent
    static let steady  = StrandPalette.statusPositive
    static let tense   = StrandPalette.statusWarning

    /// The 3-stop gauge ramp, evenly spaced (blue → green → amber).
    static let stops: [Gradient.Stop] = [
        .init(color: calm,   location: 0.00),
        .init(color: steady, location: 0.50),
        .init(color: tense,  location: 1.00),
    ]

    /// The blue→green→amber gauge gradient, built from the WHOOP band anchors above.
    static let gradient = Gradient(stops: stops)

    /// Sample the ramp at a 0–3 stress score.
    static func color(_ score: Double) -> Color {
        StrandPalette.sample(stops: stops, at: min(max(score / 3.0, 0), 1))
    }
}

// MARK: - Stress model inputs (cache key)

/// An `Equatable` snapshot of everything `StressModel.init` reads, used to decide
/// when the cached model must be rebuilt. `DailyMetric` is already `Equatable`;
/// the stored series is a tuple array (not `Equatable`), so we mirror it into an
/// `Equatable` shape. Comparison is O(n) — cheap versus rebuilding the model.
private struct StressInputs: Equatable {
    let rows: [SourcedDailyMetric]

    init(rows: [SourcedDailyMetric]) {
        self.rows = rows
    }
}

// MARK: - Stress model (causal, source-isolated experimental estimate)

struct StressModel {
    let score: Double            // 0–3 (today)
    let band: StressBand
    let explanation: String
    let rhrToday: Int?
    let hrvToday: Double?
    let rhrDelta: Double?        // today − baseline mean (bpm)
    let hrvDelta: Double?        // today − baseline mean (ms)
    let fullTrend: [TrendPoint]  // entire daily proxy history, oldest→newest
    let calmTimeValue: String    // e.g. "58%"
    let calmTimeCaption: String  // e.g. "of last 30 days"
    /// Kept for source compatibility with older call sites. NOOP no longer trusts an opaque
    /// persisted `stress` series as interchangeable with this experimental estimate.
    let usingStored: Bool
    let asOfDay: String
    let baselineDays: Int
    let confidence: DailyAutonomicLoad.Confidence
    let observedSignals: [DailyAutonomicLoad.Signal]
    let limitations: [DailyAutonomicLoad.Limitation]
    let sourceTitle: String
    let sourceNote: String?

    /// Last up-to-14 trend values, for the hero tile sparkline.
    var sparkValues: [Double] { Array(fullTrend.suffix(14)).map(\.value) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    struct SourceAssessment {
        let source: DailyMetricSource
        let title: String
        let note: String?
        let days: [DailyMetric]
        let readout: DailyAutonomicLoad.Readout

        var isScorable: Bool {
            readout.value != nil
                && readout.baselineDays >= DailyAutonomicLoad.minimumBaselineDays
        }
    }

    /// Legacy API retained for Today/LiquidToday compatibility. Opaque stored stress points are
    /// intentionally ignored: their algorithm/provenance cannot be assumed equivalent to NOOP's.
    init?(days: [DailyMetric], stored _: [(day: String, value: Double)]) {
        self.init(assessment: Self.assessment(
            source: .localCache,
            days: days
        ))
    }

    /// Source-aware UI path. A full series is selected first, then evaluated; values from WHOOP,
    /// NOOP and Apple Health are never blended into a synthetic baseline.
    init?(sourceRows: [SourcedDailyMetric]) {
        self.init(assessment: Self.preferredAssessment(sourceRows: sourceRows))
    }

    private init?(assessment: SourceAssessment) {
        guard let s = assessment.readout.value,
              let asOf = assessment.readout.asOf,
              let today = assessment.days.last(where: { $0.day == asOf })
        else { return nil }

        let engineDays = Self.engineDays(assessment.days)
        let trendReadouts = DailyAutonomicLoad.causalTrend(days: engineDays)
        let pts = trendReadouts.compactMap { readout -> TrendPoint? in
            guard let value = readout.value,
                  let day = readout.asOf,
                  let date = Self.dayParser.date(from: day)
            else { return nil }
            return TrendPoint(date: date, value: value)
        }

        let prior = assessment.days
            .filter { $0.day < asOf }
            .suffix(DailyAutonomicLoad.baselineWindowDays)
        let rhrBase = prior.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = prior.compactMap(\.avgHrv)
        let meanRHR = StressMath.mean(rhrBase)
        let meanHRV = StressMath.mean(hrvBase)
        let usesRHR = assessment.readout.observedSignals.contains(.restingHeartRate)
        let usesHRV = assessment.readout.observedSignals.contains(.heartRateVariability)

        self.usingStored = false
        self.score = s
        self.band = StressBand(score: s)
        self.rhrToday = usesRHR ? today.restingHr : nil
        self.hrvToday = usesHRV ? today.avgHrv : nil
        self.rhrDelta = usesRHR ? Self.delta(today.restingHr.map(Double.init), meanRHR) : nil
        self.hrvDelta = usesHRV ? Self.delta(today.avgHrv, meanHRV) : nil
        self.fullTrend = pts
        self.asOfDay = asOf
        self.baselineDays = assessment.readout.baselineDays
        self.confidence = assessment.readout.confidence
        self.observedSignals = assessment.readout.observedSignals
        self.limitations = assessment.readout.limitations
        self.sourceTitle = assessment.title
        self.sourceNote = assessment.note
        self.explanation = StressMath.explanation(
            band: self.band,
            rhrDelta: self.rhrDelta,
            hrvDelta: self.hrvDelta,
            usingStored: false
        )

        // Share of the last 30 independently scorable causal points in the LOW band.
        let recent = Array(pts.suffix(30))
        if recent.isEmpty {
            self.calmTimeValue = "-"
            self.calmTimeCaption = String(localized: "needs history")
        } else {
            let calm = recent.filter { $0.value < 1.0 }.count
            let pct = Int((Double(calm) / Double(recent.count) * 100).rounded())
            self.calmTimeValue = "\(pct)%"
            self.calmTimeCaption = String(localized: "low-load days · \(recent.count)d")
        }
    }

    static func engineDays(_ days: [DailyMetric]) -> [DailyAutonomicLoad.Day] {
        days.map {
            DailyAutonomicLoad.Day(day: $0.day,
                                   restingHeartRate: $0.restingHr.map(Double.init),
                                   hrv: $0.avgHrv)
        }
    }

    /// The assessment used for either the loaded model or the calibration card. Direct NOOP strap
    /// data wins only once it is actually scorable; until then a complete Apple Health reference
    /// can be used without blending its values with the strap. When nothing is scorable, show the
    /// candidate with the most real prior support instead of implying all history is absent.
    static func preferredAssessment(sourceRows: [SourcedDailyMetric]) -> SourceAssessment {
        let candidates: [SourceAssessment] = [
            assessment(source: .noopComputed, sourceRows: sourceRows),
            assessment(source: .whoopImport, sourceRows: sourceRows),
            assessment(source: .appleHealth, sourceRows: sourceRows),
            assessment(source: .localCache, sourceRows: sourceRows),
        ].filter { !$0.days.isEmpty }

        if let direct = candidates.first(where: { $0.source == .noopComputed && $0.isScorable }) {
            return direct
        }
        if let apple = candidates.first(where: { $0.source == .appleHealth && $0.isScorable }) {
            return apple
        }
        if let exported = candidates.first(where: { $0.source == .whoopImport && $0.isScorable }) {
            return exported
        }
        if let local = candidates.first(where: { $0.source == .localCache && $0.isScorable }) {
            return local
        }
        return candidates.max {
            if $0.readout.baselineDays == $1.readout.baselineDays {
                return sourceRank($0.source) > sourceRank($1.source)
            }
            return $0.readout.baselineDays < $1.readout.baselineDays
        } ?? assessment(source: .localCache, days: [])
    }

    private static func assessment(source: DailyMetricSource,
                                   sourceRows: [SourcedDailyMetric]) -> SourceAssessment {
        assessment(source: source,
                   days: sourceRows.filter { $0.source == source }.map(\.metric))
    }

    private static func assessment(source: DailyMetricSource,
                                   days: [DailyMetric]) -> SourceAssessment {
        let sorted = days.sorted { $0.day < $1.day }
        let metadata = sourceMetadata(source)
        return SourceAssessment(source: source, title: metadata.title, note: metadata.note,
                                days: sorted,
                                readout: DailyAutonomicLoad.readout(days: engineDays(sorted)))
    }

    private static func sourceRank(_ source: DailyMetricSource) -> Int {
        switch source {
        case .noopComputed: return 0
        case .whoopImport: return 1
        case .appleHealth: return 2
        case .localCache: return 3
        }
    }

    private static func sourceMetadata(_ source: DailyMetricSource) -> (title: String, note: String?) {
        switch source {
        case .noopComputed:
            return (String(localized: "Noop Band"), nil)
        case .whoopImport:
            return (String(localized: "WHOOP export reference"),
                    String(localized: "Derived by NOOP from a single WHOOP export series; not WHOOP score parity."))
        case .appleHealth:
            return (String(localized: "Apple Health reference"),
                    String(localized: "Apple Health HRV sampling and method may differ from strap RMSSD, so compare trends within this source only."))
        case .localCache:
            return (String(localized: "Local daily reference"), nil)
        }
    }

    private static func delta(_ value: Double?, _ mean: Double?) -> Double? {
        guard let value, let mean else { return nil }
        return value - mean
    }

    var confidenceTitle: String {
        switch confidence {
        case .reliable: return String(localized: "2-signal support")
        case .limited: return String(localized: "1-signal support")
        case .unavailable: return String(localized: "Unavailable")
        }
    }

    var confidenceSystemImage: String {
        confidence == .reliable ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
    }

    var confidenceColor: Color {
        confidence == .reliable ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }

    var asOfDisplay: String {
        guard let date = Self.dayParser.date(from: asOfDay) else { return asOfDay }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    var provenanceSummary: String {
        String(localized: "\(sourceTitle) · \(asOfDisplay) · \(baselineDays)d base")
    }

    var observedInputsTitle: String {
        let labels = observedSignals.map {
            switch $0 {
            case .restingHeartRate: return String(localized: "resting HR")
            case .heartRateVariability: return String(localized: "HRV")
            }
        }
        return labels.isEmpty ? String(localized: "none") : labels.joined(separator: " + ")
    }

    var limitationSummary: String {
        var notes: [String] = []
        if limitations.contains(.singleSignalEstimate) {
            notes.append(String(localized: "Limited support: only one signal passed every gate."))
        }
        if limitations.contains(.staleSourceDay) {
            notes.append(String(localized: "The latest day lacked usable inputs, so this carries the last observed day and labels its real date."))
        }
        if let sourceNote { notes.append(sourceNote) }
        return notes.joined(separator: " ")
    }
}

// MARK: - Stress math (pure, testable helpers)

enum StressMath {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. RHR-up and HRV-down both push it positive.
    static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR            // up = stress
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV            // down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5).
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    static func explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?, usingStored: Bool) -> String {
        let rhrUp = (rhrDelta ?? 0) > 1.0
        let rhrDn = (rhrDelta ?? 0) < -1.0
        let hrvUp = (hrvDelta ?? 0) > 1.0
        let hrvDn = (hrvDelta ?? 0) < -1.0

        switch band {
        case .high:
            if rhrUp && hrvDn {
                return String(localized: "Resting HR is above and HRV is below your prior baseline. That combination raises this experimental physiological-load estimate.")
            } else if hrvDn {
                return String(localized: "HRV is below your prior baseline, which raises this experimental estimate. Check the context and how you feel before acting on it.")
            } else if rhrUp {
                return String(localized: "Resting heart rate is above your prior baseline, which raises this experimental estimate. One signal cannot identify the cause.")
            }
            return String(localized: "Available autonomic markers sit above their recent range. This is a physiological pattern, not a diagnosis or emotional-stress reading.")
        case .medium:
            if rhrUp || hrvDn {
                return rhrUp
                    ? String(localized: "Resting HR is modestly above your prior baseline. Consider sleep, training, illness and measurement context.")
                    : String(localized: "HRV is modestly below your prior baseline. Consider sleep, training, illness and measurement context.")
            }
            return String(localized: "The available signals sit near their recent personal range. That does not establish how stressed or recovered you feel.")
        case .low:
            if rhrDn && hrvUp {
                return String(localized: "Resting HR is below and HRV is above your prior baseline, lowering this physiological-load estimate.")
            } else if hrvUp {
                return String(localized: "HRV is above your prior baseline, lowering this estimate. It does not by itself establish recovery or emotional state.")
            }
            return String(localized: "Available autonomic markers sit below their recent range. Interpret this experimental estimate alongside context and how you feel.")
        }
    }
}

// MARK: - Daytime autonomic-load line (README screen-9)
//
// The day's intraday stress proxy drawn as a smooth LINE across the waking hours, filled
// under the curve and stroked with the SAME 3-stop blue→green→amber ramp as
// the gauge. Only scored hours contribute points (no-data hours are skipped, never a
// guessed value); the smooth line connects the ones we have. The y-axis is the 0–3 scale
// and a faint dashed mid-line marks the 1.5 baseline.

struct DaytimeLoadLine: View {
    let hours: [DaytimeStress.HourPoint]

    private let chartHeight: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let n = max(hours.count, 1)
            // x for an hour index; y maps a 0–3 level into the chart (0 at bottom).
            // (closures, not `func` — a `@ViewBuilder` closure can't contain declarations)
            let x: (Int) -> CGFloat = { i in n <= 1 ? w / 2 : w * CGFloat(i) / CGFloat(n - 1) }
            let y: (Double) -> CGFloat = { level in h - h * CGFloat(min(max(level / 3.0, 0), 1)) }

            let pts: [(CGFloat, CGFloat)] = hours.enumerated().compactMap { i, p in
                p.level.map { (x(i), y($0)) }
            }

            ZStack {
                // Baseline (1.5 of 3) reference line.
                Path { p in
                    let yb = y(1.5)
                    p.move(to: CGPoint(x: 0, y: yb))
                    p.addLine(to: CGPoint(x: w, y: yb))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                if pts.count >= 2 {
                    // Soft area fill under the curve.
                    areaPath(pts, width: w, height: h)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    StressRamp.calm.opacity(0.22),
                                    StressRamp.calm.opacity(0.02),
                                ]),
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    // The gradient line itself (blue→green→amber, left→right).
                    linePath(pts)
                        .stroke(
                            LinearGradient(gradient: StressRamp.gradient,
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                } else if let only = pts.first {
                    // A single scored hour: a lone dot rather than a line.
                    Circle()
                        .fill(StressRamp.color(1.5))
                        .frame(width: 6, height: 6)
                        .position(x: only.0, y: only.1)
                }
            }
        }
        .frame(height: chartHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// A smooth (Catmull-Rom-ish) stroke through the scored points.
    private func linePath(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let midX = (prev.0 + cur.0) / 2
            path.addCurve(
                to: CGPoint(x: cur.0, y: cur.1),
                control1: CGPoint(x: midX, y: prev.1),
                control2: CGPoint(x: midX, y: cur.1)
            )
        }
        return path
    }

    private func areaPath(_ pts: [(CGFloat, CGFloat)], width: CGFloat, height: CGFloat) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    private var accessibilitySummary: String {
        let scored = hours.compactMap { p in p.level.map { (p.hour, $0) } }
        guard !scored.isEmpty else { return String(localized: "No intraday stress data yet today.") }
        let parts = scored.map { "\($0.0):00 \(String(format: "%.1f", $0.1))" }
        return String(localized: "Autonomic load today: \(parts.joined(separator: ", "))")
    }
}

// MARK: - Stress totals (Calm / Moderate / High) split for the day

/// Splits the day's SCORED waking hours into the three stress bands and exposes each
/// band's share + duration. Each intraday bucket is one hour (`DaytimeStress.bucketSeconds`),
/// so the band's hour-count is its duration. Calm = 0–1, Moderate = 1–2, High = 2–3.
struct StressTotals {
    let calmHours: Int
    let moderateHours: Int
    let highHours: Int

    init(hours: [DaytimeStress.HourPoint]) {
        var c = 0, m = 0, hi = 0
        for p in hours {
            guard let lvl = p.level else { continue }
            switch StressBand(score: lvl) {
            case .low:    c += 1
            case .medium: m += 1
            case .high:   hi += 1
            }
        }
        calmHours = c; moderateHours = m; highHours = hi
    }

    var total: Int { calmHours + moderateHours + highHours }

    /// 0...1 share of the scored day spent in each band (0 when no scored hours).
    func fraction(_ band: StressBand) -> Double {
        guard total > 0 else { return 0 }
        switch band {
        case .low:    return Double(calmHours) / Double(total)
        case .medium: return Double(moderateHours) / Double(total)
        case .high:   return Double(highHours) / Double(total)
        }
    }

    func hours(_ band: StressBand) -> Int {
        switch band {
        case .low:    return calmHours
        case .medium: return moderateHours
        case .high:   return highHours
        }
    }
}

// MARK: - Stress totals bar (README screen-9, liquid finish)
//
// The Calm / Moderate / High split of the scored day, rendered as three labelled liquid tubes (the
// signature LiquidTube, matching Health's recovery contributors and Today's Key-Metrics tubes). Each
// tube fills to that band's SHARE of the scored day and is tinted to the band's colour (blue /
// steady green / tense amber), with the band name + its duration above it. A day with no scored hours
// leaves all three tubes empty (no fabricated fill).

struct StressTotalsBar: View {
    let totals: StressTotals

    private struct Band: Identifiable {
        let id = UUID()
        let band: StressBand
        let label: String
        let color: Color
    }

    private var bands: [Band] {
        [
            Band(band: .low,    label: String(localized: "Calm"),     color: StressRamp.calm),
            Band(band: .medium, label: String(localized: "Moderate"), color: StressRamp.steady),
            Band(band: .high,   label: String(localized: "High"),     color: StressRamp.tense),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(bands) { b in
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(b.label)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(durationLabel(totals.hours(b.band)))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    // The signature liquid tube: fills to the band's share of the scored day, tinted to the
                    // band colour. Static (posed) — a row of small bars shouldn't each run a live Canvas.
                    LiquidTube(frac: totals.fraction(b.band), tint: b.color, height: 10, animated: false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "Today's stress split: calm \(durationLabel(totals.calmHours)), moderate \(durationLabel(totals.moderateHours)), high \(durationLabel(totals.highHours)).")
        )
    }

    /// "-" when a band had no scored hours, else "Nh" (each scored bucket is one hour).
    private func durationLabel(_ hours: Int) -> String {
        hours <= 0 ? "-" : String(localized: "\(hours)h")
    }
}

// MARK: - Preview

#if DEBUG
private func sampleStressTrend(_ n: Int) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<n).map { i in
        let date = cal.date(byAdding: .day, value: -(n - 1 - i), to: today)!
        let v = 1.4 + 0.9 * sin(Double(i) / 2.4) + Double((i * 13) % 5) * 0.12
        return TrendPoint(date: date, value: min(max(v, 0), 3))
    }
}

/// A sample waking-hour timeline (06:00→22:00) for the preview, with a couple of
/// no-signal gaps so the line break reads honestly.
private func sampleDaytimeHours() -> [DaytimeStress.HourPoint] {
    let base = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
    return (DaytimeStress.wakingStartHour...DaytimeStress.wakingEndHour).map { h in
        let curve = 1.3 + 1.1 * sin(Double(h - 6) / 3.2)
        // Drop two hours to show the gap behaviour.
        let level: Double? = (h == 11 || h == 17) ? nil : min(max(curve, 0), 3)
        return DaytimeStress.HourPoint(hour: h, startTs: base + h * 3600,
                                       level: level, meanHR: 64, rmssd: 38)
    }
}

private struct StressPreviewHarness: View {
    let score: Double
    @State private var range: ExploreRange = .month
    var body: some View {
        let band = StressBand(score: score)
        let hours = sampleDaytimeHours()
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Stress").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)

                // Liquid hero — the stress-level vessel + band + one plain-English line.
                NoopCard(tint: StressRamp.calm) {
                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        HStack {
                            Text("NOOP autonomic load").strandOverline()
                            Spacer()
                            StatePill("\(band.title)", tone: band.tone)
                        }
                        HStack(alignment: .center, spacing: NoopMetrics.space5) {
                            StressHeroGauge(score: score, tint: StressRamp.color(score))
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                Text(band.title).font(StrandFont.overline)
                                    .tracking(StrandFont.overlineTracking)
                                    .foregroundStyle(StressRamp.color(score))
                                Text(StressMath.explanation(band: band, rhrDelta: 3, hrvDelta: -8, usingStored: false))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                // Screen-9 day autonomic-load line + Calm/Moderate/High totals bar.
                NoopCard(tint: StressRamp.calm) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Autonomic load through the day").strandOverline()
                        DaytimeLoadLine(hours: hours)
                        Divider().overlay(StrandPalette.hairline)
                        StressTotalsBar(totals: StressTotals(hours: hours))
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                          alignment: .leading, spacing: NoopMetrics.gap) {
                    StatTile(label: "Autonomic load", value: String(format: "%.1f", score),
                             caption: "of 3 · \(band.title)", accent: StressRamp.color(score))
                    StatTile(label: "Resting HR", value: "54 bpm", accent: StrandPalette.metricRose,
                             delta: "+3 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "HRV", value: "48 ms", accent: StrandPalette.metricPurple,
                             delta: "−8 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "Low-load days", value: "58%", caption: "low-load days · 30d",
                             accent: StressRamp.calm)
                }

                ChartCard(title: "NOOP Load · M", subtitle: "Causal daily 0-3 estimate", trailing: "avg 1.5") {
                    TrendChart(points: sampleStressTrend(30), gradient: StressRamp.gradient,
                               valueRange: 0...3, showsArea: true, height: NoopMetrics.chartHeight,
                               valueFormat: { String(format: "%.1f", $0) })
                } footer: {
                    ChartFooter([("Today", String(format: "%.1f", score)), ("Average", "1.5"), ("Days", "30")])
                }
                SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                     adaptsToAvailableWidth: true) { $0.label }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Stress - HIGH") {
    StressPreviewHarness(score: 2.4)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}

#Preview("Stress - LOW") {
    StressPreviewHarness(score: 0.6)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}
#endif
