#if os(iOS)
import SwiftUI
import StrandDesign

/// #155 — the opt-in surface for the Apple-Health-free export. Sideloaded installs (free 7-day
/// signing) can't carry the HealthKit entitlement, so HealthKitBridge never runs for them; this
/// toggle instead has NOOP rewrite Documents/noop_sync.txt on every background transition, and the
/// user's Siri Shortcut reads the file and logs the rows into Apple Health. Default OFF.
struct ShortcutExportSettingsView: View {
    @AppStorage(ShortcutHealthExport.enabledKey) private var enabled = false

    var body: some View {
        ScreenScaffold(title: "Shortcuts Export",
                       subtitle: "Noop Band data into Apple Health without HealthKit, for sideloaded installs.") {
            exportCard
        }
    }

    private var exportCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up.on.square.fill")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Shortcuts file export")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Toggle(isOn: $enabled) {
                    Text("Export for Shortcuts (Apple Health)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                // The file keeps its historical four-column shape, but only heart-rate samples are
                // populated. The two reserved metric columns stay blank so old Shortcuts keep parsing.
                Label("Heart rate", systemImage: "checkmark.circle.fill")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack {
                    Label("Steps (estimated)", systemImage: "xmark.circle")
                    Spacer(minLength: 12)
                    Text("Unavailable")
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                Text("Estimated from Noop Band motion, calibrated to your phone. Not a measured step count.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
