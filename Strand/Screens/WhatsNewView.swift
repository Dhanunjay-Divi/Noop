import Foundation
import SwiftUI
import StrandDesign

enum WhatsNewPresentation {
    case welcome(firstInstall: Bool)
    case history

    var isWelcome: Bool {
        if case .welcome = self { return true }
        return false
    }

    var showsFirstInstallGlow: Bool {
        if case .welcome(let firstInstall) = self { return firstInstall }
        return false
    }
}

/// "What's New" - a proper in-app changelog, shown automatically after an update and reachable any
/// time from Settings. It also restates, up top, what NOOP is and what to expect, so people who never
/// open GitHub still understand the experimental footing and the WHOOP 5/MG status.
struct WhatsNewView: View {
    let presentation: WhatsNewPresentation
    let onSkip: () -> Void
    let onClose: () -> Void

    init(
        presentation: WhatsNewPresentation = .history,
        onSkip: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.onSkip = onSkip
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                // A scenic Charge-tinted hero behind the title region — the same premium backdrop
                // the Today rings float over, so the changelog opens on-brand.
                .background {
                    ScenicHeroBackground(domain: .charge, starCount: 28, fadesToBase: true)
                }
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                // PERF: the changelog grows with every release, so this is an ever-lengthening column.
                // LazyVStack (byte-identical layout to VStack inside a ScrollView — same leading
                // alignment + sectionGap spacing) builds the off-screen release cards on demand instead
                // of constructing the entire history up-front each time the sheet opens.
                LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if presentation.isWelcome {
                        if let release = AppChangelog.releases.first {
                            releaseCard(release, isLatest: true)
                        }
                    } else {
                        ForEach(Array(AppChangelog.releases.enumerated()), id: \.element.id) { index, release in
                            // The newest release is the headline — give it the brand-green wash; the
                            // rest stay frosted-neutral so the latest stands out at a glance.
                            releaseCard(release, isLatest: index == 0)
                            if index == 0 {
                                expectationsCard
                            }
                        }
                    }
                }
                .padding(20)
            }
            Divider().overlay(StrandPalette.hairline)
            footer
        }
        // A fixed 560×640 is right for the macOS sheet window, but on iPhone it's wider than the
        // screen, so the content (and the "Got it" button) ran off the right edge (#185). iOS fills
        // the presented sheet instead.
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A long changelog scroll → open full-height, with a grabber for swipe-to-dismiss.
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
        .overlay {
            if presentation.showsFirstInstallGlow {
                FirstInstallEdgeGlow()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WHAT'S NEW").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(headerTitle)
                    .font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Release notes").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            if !presentation.isWelcome {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .padding(20)
    }

    private var headerTitle: String {
        if presentation.isWelcome {
            return String(
                format: String(localized: "whats_new.welcome_version"),
                AppChangelog.currentVersion
            )
        }
        return "NOOP \(AppChangelog.currentVersion)"
    }

    private var expectationsCard: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 14) {
                Text("WHAT TO EXPECT").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                ForEach(AppChangelog.expectations) { e in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: e.icon)
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 22)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(CustomerFacingBrand.text(e.title)).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(CustomerFacingBrand.text(e.body)).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func releaseCard(_ release: AppChangelog.Release, isLatest: Bool = false) -> some View {
        NoopCard(tint: isLatest ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SourceBadge("v\(release.version)")
                    Spacer()
                    Text(release.date).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text(CustomerFacingBrand.text(release.title)).font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(StrandPalette.accent).frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(releaseNote(item)).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func releaseNote(_ source: String) -> AttributedString {
        let rendered = CustomerFacingBrand.text(source)
        return (try? AttributedString(
            markdown: rendered,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(rendered)
    }

    private var footer: some View {
        HStack {
            if presentation.isWelcome {
                Button("Skip", action: onSkip)
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(minWidth: 88, minHeight: 44)
                    .accessibilityIdentifier("noop.whatsNew.skip")
                Spacer()
                Button(action: onClose) {
                    Text("OK")
                        .frame(minWidth: 120)
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("noop.whatsNew.ok")
            } else {
                Spacer()
                Button(action: onClose) {
                    Text("Got it")
                        .frame(minWidth: 120)
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

private struct FirstInstallEdgeGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var renderStill: Bool {
        reduceMotion || lowPowerMode
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        StrandPalette.chargeBright,
                        StrandPalette.effortBright,
                        StrandPalette.restBright,
                        StrandPalette.chargeBright,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 2
            )
            .shadow(color: StrandPalette.chargeGlow.opacity(0.45), radius: 8)
            .padding(4)
            .opacity(renderStill ? 0.72 : (pulsing ? 0.95 : 0.48))
            .animation(
                renderStill
                    ? nil
                    : .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .NSProcessInfoPowerStateDidChange
                )
            ) { _ in
                lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
