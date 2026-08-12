import SwiftUI
import StrandDesign

/// Version/build policy for the iPhone trial disclosure. The acknowledged identity is persisted in
/// `UserDefaults`, so a build is shown once rather than once per process launch. Comparing both bundle
/// fields matters for TestFlight-style releases, where a replacement build can keep the same marketing
/// version while advancing `CFBundleVersion`.
enum TrialNoticePolicy {
    static let acknowledgedBuildStorageKey = "noop.lastAcknowledgedTrialBuild"

    /// Stable, schema-prefixed value stored by `iOSRootView`. Bundle version components are restricted by
    /// Apple to version-like text; trimming here also prevents an accidentally blank build setting from
    /// creating a marker that changes between launches.
    static func buildIdentifier(
        marketingVersion: String,
        buildNumber: String
    ) -> String {
        let version = normalized(marketingVersion) ?? "0"
        let build = normalized(buildNumber) ?? "0"
        return "1|\(version)|\(build)"
    }

    static func currentBuildIdentifier(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> String {
        buildIdentifier(
            marketingVersion: stringValue(infoDictionary["CFBundleShortVersionString"]) ?? "0",
            buildNumber: stringValue(infoDictionary["CFBundleVersion"]) ?? "0"
        )
    }

    static func shouldPresent(
        acknowledgedBuildIdentifier: String,
        currentBuildIdentifier: String,
        demoBypass: Bool
    ) -> Bool {
        guard !demoBypass else { return false }
        guard let current = BuildIdentity(currentBuildIdentifier) else {
            // Fail safe for an invalid current bundle identity: show once for that exact value, but do not
            // get stuck in an every-launch loop after it has been acknowledged.
            return acknowledgedBuildIdentifier != currentBuildIdentifier
        }
        guard let acknowledged = BuildIdentity(acknowledgedBuildIdentifier) else { return true }
        return current.isNewer(than: acknowledged)
    }

    /// The automatic What's New sheet is release-version gated rather than build gated: a TestFlight
    /// rebuild with unchanged notes still gets the trial disclosure above, but does not replay identical
    /// notes. Numeric comparison prevents a downgrade from being treated as a new release.
    static func isNewerMarketingVersion(
        _ currentVersion: String,
        than acknowledgedVersion: String
    ) -> Bool {
        guard let current = normalized(currentVersion) else { return false }
        guard let acknowledged = normalized(acknowledgedVersion) else { return true }
        return current.compare(
            acknowledged,
            options: [.numeric, .caseInsensitive]
        ) == .orderedDescending
    }

    private struct BuildIdentity {
        let marketingVersion: String
        let buildNumber: String

        init?(_ persistedValue: String) {
            let fields = persistedValue.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  fields[0] == "1",
                  let version = normalized(String(fields[1])),
                  let build = normalized(String(fields[2])) else { return nil }
            marketingVersion = version
            buildNumber = build
        }

        func isNewer(than other: BuildIdentity) -> Bool {
            let versionOrder = marketingVersion.compare(
                other.marketingVersion,
                options: [.numeric, .caseInsensitive]
            )
            if versionOrder != .orderedSame { return versionOrder == .orderedDescending }
            return buildNumber.compare(
                other.buildNumber,
                options: [.numeric, .caseInsensitive]
            ) == .orderedDescending
        }
    }

    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("|") else { return nil }
        return trimmed
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return normalized(value) }
        if let value = value as? NSNumber { return normalized(value.stringValue) }
        return nil
    }
}

/// Full-screen trial disclosure shown before Terms and onboarding once for each newer iOS app build.
/// The wording distinguishes NOOP-operated cloud storage (none) from explicit optional
/// destinations the user may choose, so the promise remains true if self-hosted sync is enabled.
struct TrialNoticeView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()

            ScrollView {
                VStack(spacing: NoopMetrics.sectionSpacing) {
                    Spacer(minLength: NoopMetrics.space8)

                    BrandMark(size: 88)

                    Text("TESTFLIGHT TRIAL")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, NoopMetrics.space3)
                        .padding(.vertical, NoopMetrics.space2)
                        .background(
                            StrandPalette.accentMuted,
                            in: Capsule()
                        )

                    VStack(spacing: NoopMetrics.space3) {
                        Text("A private preview of NOOP")
                            .font(StrandFont.title1)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("Use this trial to view and compare experimental wellness metrics from your wearable.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: NoopMetrics.gap) {
                        trialPoint(
                            icon: "iphone.gen3",
                            title: "Stored on this iPhone",
                            body: "NOOP has no account or NOOP-operated cloud in this trial. Metrics stay on this device by default."
                        )
                        trialPoint(
                            icon: "arrow.up.forward.app",
                            title: "Sharing stays your choice",
                            body: "External sharing or self-hosted sync happens only after you explicitly configure and enable it."
                        )
                        trialPoint(
                            icon: "waveform.path.ecg",
                            title: "For viewing, not diagnosis",
                            body: "These metrics are experimental estimates, not medical advice or a medical device."
                        )
                    }

                    Text("Removing NOOP may remove its local data. Apple Health and device backups follow the privacy settings you control on your iPhone.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    NoopButton(
                        "Continue to NOOP",
                        systemImage: "arrow.right",
                        kind: .primary,
                        fullWidth: true,
                        action: onContinue
                    )
                    .accessibilityIdentifier("noop.trial.continue")

                    Spacer(minLength: NoopMetrics.space6)
                }
                .frame(maxWidth: 560)
                .screenPadding()
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noop.trial.notice")
    }

    private func trialPoint(
        icon: String,
        title: LocalizedStringKey,
        body: LocalizedStringKey
    ) -> some View {
        NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.space4) {
                Image(systemName: icon)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: NoopMetrics.space8)
                    .accessibilityHidden(true)

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
}
