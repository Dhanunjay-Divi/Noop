import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            Group {
                if LaunchSurfaceAuthorization.isAuthorized() {
                    HStack(spacing: 14) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.title2)
                            .foregroundStyle(StrandPalette.statusCritical)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.title)
                                .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                            Text(context.isStale ? "Update paused" : "\(context.state.bpm.map(String.init) ?? "–") bpm")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(context.isStale ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                        }
                        Spacer()
                        // Charge + Effort (#446) on the banner, mirroring the Dynamic Island expanded stats.
                        HStack(spacing: 12) {
                            if let r = context.state.recovery {
                                bannerStat(label: "Charge", value: "\(r)%")
                            }
                            if let e = context.state.effort {
                                bannerStat(label: "Effort", value: "\(e)")
                            }
                        }
                    }
                } else {
                    LaunchLockedLiveActivityView()
                }
            }
            .padding()
            .noopAppearance(WidgetAppearancePreference.load())
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
            .opacity(context.isStale ? 0.72 : 1)
        } dynamicIsland: { context in
            let authorized = LaunchSurfaceAuthorization.isAuthorized()
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if authorized {
                        Label(context.isStale ? "Paused" : "\(context.state.bpm.map(String.init) ?? "–")",
                              systemImage: context.isStale ? "pause.fill" : "heart.fill")
                            .foregroundStyle(context.isStale ? .secondary : StrandPalette.statusCritical)
                    } else {
                        Label("Locked", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if authorized {
                        // Charge + Effort (#446) — one more stat alongside the leading live HR.
                        HStack(spacing: 10) {
                            if let r = context.state.recovery {
                                statColumn(label: "Charge", value: "\(r)%")
                            }
                            if let e = context.state.effort {
                                statColumn(label: "Effort", value: "\(e)")
                            }
                        }
                    } else {
                        Text("NOOP").foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(authorized ? context.attributes.title : String(localized: "launch.locked.instruction"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: authorized ? (context.isStale ? "pause.fill" : "heart.fill") : "lock.fill")
                    .foregroundStyle(authorized && !context.isStale ? StrandPalette.statusCritical : .secondary)
            } compactTrailing: {
                Text(authorized ? (context.isStale ? "—" : "\(context.state.bpm.map(String.init) ?? "–")") : "NOOP")
            } minimal: {
                Image(systemName: authorized ? (context.isStale ? "pause.fill" : "heart.fill") : "lock.fill")
                    .foregroundStyle(authorized && !context.isStale ? StrandPalette.statusCritical : .secondary)
            }
        }
    }
}

private struct LaunchLockedLiveActivityView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(StrandPalette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("launch.locked.title")
                    .font(.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("launch.locked.instruction")
                    .font(.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
        }
    }
}

/// Lock-Screen banner stat column (label over value). File-scope because the `ActivityConfiguration`
/// content closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value are CENTRE-aligned so each value sits directly under its own label. The
/// old `.trailing` alignment right-pinned both to the column's edge: when the value was narrower than
/// the label (e.g. "12" under "Effort") it drifted to the label's right edge instead of under it, which
/// read as "the number doesn't line up with its label". `fixedSize` stops either line truncating so the
/// pairing is never clipped at narrow widths.
@ViewBuilder
private func bannerStat(label: LocalizedStringKey, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        Text(value).font(.headline).foregroundStyle(StrandPalette.textPrimary)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: LocalizedStringKey, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.headline)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
