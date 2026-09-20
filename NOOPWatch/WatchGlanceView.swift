import SwiftUI
import StrandDesign

// MARK: - WatchGlanceView — the watch app's single primary screen
//
// The NOOP score hierarchy scaled to the wrist: the three rings (Recovery / Effort / Sleep) with
// their numbers in SF-Rounded, each honouring measured, calibrating, missing, and stale states without
// fabricating a score, a live heart-rate readout from the watch's own sensor, and a one-line sleep summary.
// When nothing has synced yet we show a friendly "open NOOP on your iPhone" state, and we always label the
// scores with the snapshot's age ("as of 2h ago") rather than implying they are live.
struct WatchGlanceView: View {
    @EnvironmentObject private var store: WatchScoreStore
    @EnvironmentObject private var liveHR: WatchLiveHR
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The glance is page 1 of the watch app's swipeable page deck (WatchRootView): just the synced
        // scores, sized to ONE screen with no scrolling. Breathe / Workout / Intervals are their OWN pages
        // a swipe away, so the glance no longer pushes or links anywhere. The phone is the brain for the
        // SCORES here; the active features run on the watch's own sensors + haptics on their pages.
        adaptiveContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .onAppear {
                #if DEBUG
                // Screenshot routes run without a paired phone and must not be covered by Health's
                // first-run authorization sheet. Normal debug and every release build still request it.
                guard ProcessInfo.processInfo.environment["NOOP_DEMO_SCREEN"] == nil else { return }
                #endif
                liveHR.start()
            }
            .onDisappear { liveHR.stop() }
    }

    @ViewBuilder
    private var adaptiveContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                content
                    .padding(.vertical, 8)
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let snap = store.snapshot {
                glance(snap)
            } else {
                emptyState
            }
        }
    }

    // MARK: Synced state

    @ViewBuilder
    private func glance(_ snap: WatchScoreSnapshot) -> some View {
        // One staleness decision for the whole glance: when the snapshot has aged out (per the shared
        // contract) every ring enters its explicit stale state so an arbitrarily old snapshot never
        // shows live-looking numbers or masquerades as a score that is still calibrating.
        let stale = snap.isStale()
        let freshness = snap.freshnessText()
        VStack(spacing: 12) {
            // The three score rings. Each renders a number only when the phone earned one and it is
            // still current. Calibration, missing input, and stale transport each remain distinct.
            LazyVGrid(
                columns: dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.flexible())]
                    : Array(repeating: GridItem(.flexible()), count: 3),
                spacing: 8
            ) {
                // The labels ride a plain String property into ScoreRing, so they must be wrapped HERE;
                // a bare literal would bypass the string catalog entirely.
                ScoreRing(label: String(localized: "Recovery"),
                          state: ScoreRingState(value: snap.charge,
                                                calibrating: snap.chargeCalibrating,
                                                stale: stale,
                                                freshness: freshness),
                          color: StrandPalette.chargeColor)
                ScoreRing(label: String(localized: "Effort"),
                          state: ScoreRingState(value: snap.effort,
                                                calibrating: snap.effortCalibrating,
                                                stale: stale,
                                                freshness: freshness),
                          color: StrandPalette.effortColor)
                ScoreRing(label: String(localized: "Sleep"),
                          state: ScoreRingState(value: snap.rest,
                                                calibrating: snap.restCalibrating,
                                                stale: stale,
                                                freshness: freshness),
                          color: StrandPalette.restColor)
            }
            .frame(maxWidth: .infinity)

            heartRate
            // A stale snapshot's sleep line is also out of date, so drop it rather than imply it is today's.
            if !stale { sleepLine(snap.sleepSummary) }
            asOf(snap)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    /// Live heart rate from the watch's own sensor. A first-use permission prompt is always initiated by
    /// the visible button; mounting the glance never opens a system sheet.
    private var heartRate: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 13))
                .foregroundStyle(StrandPalette.statusCritical)
            switch liveHR.accessState {
            case .needsRequest:
                Button("Allow access") {
                    liveHR.requestAuthorization()
                }
                .disabled(liveHR.isRequesting)
                .font(StrandFont.caption)
            case .unavailable:
                Text("HR unavailable")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            case .checking:
                Text("appwide.watch.live_hr.checking")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            case .noReadableSample:
                VStack(alignment: .leading, spacing: 1) {
                    Text("appwide.watch.live_hr.no_recent")
                    Text("appwide.watch.live_hr.check_access")
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .font(StrandFont.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            case .queryFailed:
                Text("HR unavailable")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Button("Retry") {
                    liveHR.retry()
                }
                .font(StrandFont.caption)
            case .available:
                if let bpm = liveHR.bpm {
                    Text(verbatim: String(bpm))
                        .font(StrandFont.rounded(20, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                    Text("bpm")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("appwide.watch.live_hr.waiting")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
    }

    /// One-line sleep summary straight from the phone (e.g. "7h 12m · 81% sleep efficiency").
    /// The separate Sleep ring is the 0-100 Sleep Score. Empty string means skip the line.
    @ViewBuilder
    private func sleepLine(_ summary: String) -> some View {
        if !summary.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.restColor)
                Text(summary)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The honesty line: how recent the synced scores are, straight from the shared contract so the
    /// glance and the complication phrase it identically ("Today" / "Yesterday" / "2h ago"). When the
    /// snapshot is stale the rings above are already dashes, and this line carries the recency.
    private func asOf(_ snap: WatchScoreSnapshot) -> some View {
        let fresh = snap.freshnessText()
        return Text(snap.isStale() ? String(localized: "stale · \(fresh)") : String(localized: "as of \(fresh)"))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 28))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Open NOOP on your iPhone to sync")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(.horizontal, 12)
    }

    // Snapshot recency now comes from the shared contract (`freshnessText` / `isStale` on
    // WatchScoreSnapshot) so the glance and the complication never drift apart. The old local
    // ageString helper was retired with that move.
}

// MARK: - ScoreRing — one clean NOOP ring scaled for the wrist
//
// Wraps the shared GlowRing (the flat, crisp Apple-Fitness-x-WHOOP arc) so the watch matches the phone's
// rings exactly. Non-measured states keep an empty track and distinct content; Reduce Motion is respected
// inside GlowRing itself.
private enum ScoreRingState {
    case measured(Double)
    case calibrating
    case missing
    case stale(freshness: String)

    init(value: Double?, calibrating: Bool, stale: Bool, freshness: String) {
        if stale {
            self = .stale(freshness: freshness)
        } else if calibrating {
            self = .calibrating
        } else if let value {
            self = .measured(value)
        } else {
            self = .missing
        }
    }
}

private struct ScoreRing: View {
    let label: String
    let state: ScoreRingState
    let color: Color

    private let diameter: CGFloat = 52
    private let lineWidth: CGFloat = 6

    var body: some View {
        VStack(spacing: 4) {
            ring
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var ring: some View {
        switch state {
        case .measured(let value):
            GlowRing(fraction: value / 100,
                     value: value,
                     format: { "\(Int($0.rounded()))" },
                     color: color,
                     diameter: diameter,
                     lineWidth: lineWidth)
        case .calibrating:
            emptyRing {
                Image(systemName: "hourglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
            }
        case .missing:
            emptyRing {
                Text("–")
                    .font(GlowRing.centerFont(diameter: diameter))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        case .stale:
            emptyRing {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func emptyRing<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.textPrimary.opacity(0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            content()
        }
        .frame(width: diameter, height: diameter)
    }

    private var accessibilityValue: Text {
        switch state {
        case .measured(let value):
            return Text(verbatim: "\(Int(value.rounded()))")
        case .calibrating:
            return Text("Calibrating")
        case .missing:
            return Text("No data")
        case .stale(let freshness):
            return Text("Last sync: \(freshness)")
        }
    }
}
