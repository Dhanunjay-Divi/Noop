import Foundation
import StrandDesign
import SwiftUI

/// Device-local, default-private choices for passive live-heart-rate presentation.
///
/// These preferences never start collection, request notification permission, or change BLE behavior.
/// They only decide whether an already-fresh reading may appear on the current device's UI surface.
enum LiveHeartRatePresentationPreferences {
    static let inAppBannerKey = "liveHeartRate.presentation.inAppBanner"
    static let macToolbarKey = "liveHeartRate.presentation.macToolbar"
    static let privacyMigrationKey = "liveHeartRate.presentation.privacyOptInMigration.v1"

    static func migratePrivacyIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: privacyMigrationKey) else { return }
        for key in [inAppBannerKey, macToolbarKey]
        where defaults.object(forKey: key) == nil {
            defaults.set(false, forKey: key)
        }
        defaults.set(true, forKey: privacyMigrationKey)
    }

    static func inAppBannerEnabled(defaults: UserDefaults = .standard) -> Bool {
        migratePrivacyIfNeeded(defaults: defaults)
        return defaults.bool(forKey: inAppBannerKey)
    }

    static func macToolbarEnabled(defaults: UserDefaults = .standard) -> Bool {
        migratePrivacyIfNeeded(defaults: defaults)
        return defaults.bool(forKey: macToolbarKey)
    }

    static func recordChange(surface: String, enabled: Bool) {
        AppDiagnosticsRecorder.shared.record(
            "live_hr.presentation_preference",
            fields: [
                "surface": surface,
                "state": enabled ? "enabled" : "disabled",
            ]
        )
    }
}

enum LiveHeartRatePresentationState: Equatable {
    case hidden
    case waiting
    case reconnecting
    case live(Int)

    static func resolve(
        enabled: Bool,
        connected: Bool,
        bpm: Int?,
        observedAt: Date?,
        now: Date
    ) -> LiveHeartRatePresentationState {
        guard enabled, connected else { return .hidden }
        guard LiveHeartRateSurfacePolicy.isLive(
            connected: true,
            bpm: bpm,
            observedAt: observedAt,
            now: now
        ), let bpm else {
            return bpm != nil || observedAt != nil ? .reconnecting : .waiting
        }
        return .live(bpm)
    }

    var accessibilityValue: String {
        switch self {
        case .hidden:
            return ""
        case .waiting:
            return String(localized: "appwide.health.live_hr.waiting")
        case .reconnecting:
            return String(localized: "appwide.health.live_hr.reconnecting")
        case .live(let bpm):
            return String(
                format: String(localized: "appwide.health.live_hr.accessibility_value"),
                locale: .current,
                Int64(bpm)
            )
        }
    }
}

private struct LiveHeartRateTopPill: View {
    let state: LiveHeartRatePresentationState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullContent
            compactContent
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 420, minHeight: 32)
        .background(StrandPalette.surfaceRaised.opacity(0.94), in: Capsule())
        .overlay {
            Capsule()
                .stroke(StrandPalette.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("appwide.health.live_hr.surface_label"))
        .accessibilityValue(Text(verbatim: state.accessibilityValue))
    }

    private var fullContent: some View {
        HStack(spacing: 8) {
            heartIcon

            Text("appwide.health.live_hr.surface_label")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)

            Rectangle()
                .fill(StrandPalette.hairline)
                .frame(width: 1, height: 16)

            stateLabel
                .font(StrandFont.rounded(13, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 7) {
            heartIcon
            stateLabel
                .font(StrandFont.rounded(13, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var heartIcon: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StrandPalette.statusCritical)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .waiting:
            Text("appwide.health.live_hr.waiting")
        case .reconnecting:
            Text("appwide.health.live_hr.reconnecting")
        case .live(let bpm):
            Text(
                String(
                    format: String(localized: "appwide.health.live_hr.bpm_format"),
                    locale: .current,
                    Int64(bpm)
                )
            )
        }
    }
}

#if os(iOS)
struct InAppLiveHeartRateBanner: View {
    @ObservedObject private var live: LiveState
    @AppStorage(LiveHeartRatePresentationPreferences.inAppBannerKey)
    private var enabled = LiveHeartRatePresentationPreferences.inAppBannerEnabled()

    init(live: LiveState) {
        self.live = live
    }

    var body: some View {
        if enabled {
            TimelineView(.periodic(from: .now, by: 5)) { timeline in
                let state = LiveHeartRatePresentationState.resolve(
                    enabled: true,
                    connected: live.connected || live.streamingLiveHR,
                    bpm: live.heartRate,
                    observedAt: live.heartRateSample?.receivedAt,
                    now: timeline.date
                )
                if state != .hidden {
                    LiveHeartRateTopPill(state: state)
                }
            }
        }
    }
}
#endif

#if os(macOS)
struct MacLiveHeartRateToolbarSurface: View {
    @EnvironmentObject private var live: LiveState
    @AppStorage(LiveHeartRatePresentationPreferences.macToolbarKey)
    private var enabled = LiveHeartRatePresentationPreferences.macToolbarEnabled()

    var body: some View {
        if enabled {
            TimelineView(.periodic(from: .now, by: 5)) { timeline in
                let state = LiveHeartRatePresentationState.resolve(
                    enabled: true,
                    connected: live.connected || live.streamingLiveHR,
                    bpm: live.heartRate,
                    observedAt: live.heartRateSample?.receivedAt,
                    now: timeline.date
                )
                if state != .hidden {
                    LiveHeartRateTopPill(state: state)
                }
            }
        }
    }
}
#endif
