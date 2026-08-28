import SwiftUI
import StrandDesign
#if os(iOS)
import UIKit
#endif

/// Standard scrollable screen container: title + dark surface + content column.
struct ScreenScaffold<Content: View, Trailing: View>: View {
    /// Optional — when nil (and no subtitle) the header is omitted entirely, so a screen can supply its
    /// own custom header in `content` (iOS Today's compact top bar).
    let title: LocalizedStringKey?
    var subtitle: LocalizedStringKey? = nil
    /// Optional pull-to-refresh hook. When set, the scroll view becomes `.refreshable`
    /// (the standard iPhone gesture for a data dashboard). Defaults to nil so callers that
    /// don't opt in are unaffected — and on macOS `.refreshable` surfaces no affordance.
    var onRefresh: (() async -> Void)? = nil
    /// Lazily materialise the content column. When `true` the inner stack is a `LazyVStack`,
    /// so a screen whose content ends in a long `ForEach` only builds the cards on screen
    /// rather than all of them up-front - the fix for Intelligence "ALL" freezing on an
    /// 800+ day imported history (#345). Defaults to `false` so every existing caller keeps
    /// the eager `VStack` and its identical layout/scroll behaviour.
    var lazy: Bool = false
    /// Optional full-bleed view drawn behind the scroll content at the TOP of the screen (e.g. Today's
    /// day-cycle scene). Defaults to nil so other screens stay on the flat canvas; nil renders nothing.
    var topBackground: AnyView? = nil
    /// Override whether the header needs scheme-independent light text. The default is dynamic ink:
    /// `liquidScaffoldSky()` is dark obsidian in Dark mode but a pearl relief in Light mode. Only a
    /// genuinely fixed-dark backdrop (for example Live's console field) should pass `true`.
    var topBackgroundUsesDarkHeader: Bool? = nil
    /// Optional element pinned to the header's trailing edge (e.g. the strap-battery badge on Today).
    /// Defaults to `EmptyView` via the convenience init below, so other screens are unaffected.
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    // iPad runs the shared screens full-screen, where an uncapped column gives 120+ character lines
    // in landscape. On iOS regular width (iPad) the readable column is capped + centred; compact
    // (iPhone) and macOS are unchanged. macOS also reports a horizontalSizeClass, so the cap is gated
    // by `#if os(iOS)` — a runtime size-class check alone would also narrow the Mac detail pane.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// Bumped (via the environment) when the iOS tab shell wants THIS screen scrolled to the top — an
    /// at-root re-tap of the active tab (#198 follow-up). Default 0 never changes, so macOS and every
    /// non-tab screen keep their exact prior scroll behaviour.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    /// The iPhone shell supplies this at each tab root. It receives the real top-marker position from
    /// this ScrollView (including inertial deceleration); the default no-op keeps macOS, sheets and
    /// stand-alone previews behaviorally identical.
    @Environment(\.scrollPositionReporter) private var reportScrollPosition
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // Keep the anchors and visible column in one explicit stack. The offset probe is attached to
            // this full-height container below: iOS 26 collapses a zero-height GeometryReader's frame to
            // zero, while the content container's top edge remains measurable throughout the scroll.
            VStack(spacing: 0) {
                // Scroll-to-top anchor (#198 follow-up): a zero-height marker pinned above the content so an
                // at-root tab re-tap can bring the screen back to the very top. Layout-neutral.
                Color.clear.frame(height: 0).id(screenScaffoldTopAnchorID)
                column
                #if os(iOS)
                // Unified side margins matching the liquid home (16pt) so every page's cards + header line up
                // to the same edges (2026-07-02); macOS keeps the classic 28 in the #else branch.
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, 24)
                .padding(.bottom, NoopMetrics.space4)
                // A vertical ScrollView accepts a child's ideal horizontal size. Several full-width cards
                // can therefore claim the whole viewport BEFORE this 16pt padding is added, making the
                // padded column viewport+32pt wide; SwiftUI centres that overflow and crops the page's
                // title/cards by 16pt on both sides. Size the complete padded column from the scroll
                // container instead, so the gutter is included in (not added beyond) the viewport.
                // Regular-width iPad keeps the existing 700pt readable-column cap.
                .containerRelativeFrame(.horizontal, alignment: .center) { width, _ in
                    hSizeClass == .regular ? min(width, 700) : width
                }
                .frame(maxWidth: .infinity, alignment: .center)
                #else
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                // A deterministic end marker is useful both to scroll-to-end accessibility actions and to
                // DEBUG layout captures. It has no visual height; the tab shell's measured bottom reservation
                // determines where this endpoint can settle relative to the floating bar.
                Color.clear.frame(height: 0).id(screenScaffoldBottomAnchorID)
            }
            #if os(iOS)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ScreenScrollOffsetPreferenceKey.self,
                        value: geometry.frame(in: .global).minY
                    )
                }
            }
            #endif
        }
        #if os(iOS)
        .modifier(DemoBottomScrollAnchor())
        .modifier(ScreenScrollPositionReporter(report: reportScrollPosition))
        // #697: stop a vertical scroll from drifting/bouncing the screen left-right. `.basedOnSize` only
        // permits horizontal bounce when content genuinely overflows the width (it does not here, the column
        // is width-capped), so the spurious horizontal rubber-band that caused the sideways drift is gone.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        // The flat canvas, plus an optional full-bleed TOP backdrop (Today's day-cycle scene) drawn behind
        // the scroll content — edge-to-edge under the status bar. The scene is CONFINED to the header+hero
        // band (see SceneScreenBackground.height) so it fades out ABOVE the dashboard cards, which then sit
        // on the opaque canvas and stay fully legible (2026-06-23: cards were "losing the data").
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                StrandPalette.surfaceBase
                topBackground
            }
            .ignoresSafeArea()
        }
        #if os(iOS)
        .overlay(alignment: .top) {
            if topBackground == nil {
                FlatStatusBarScrim()
            }
        }
        #endif
        .modifier(RefreshableIfNeeded(onRefresh: onRefresh))
        #if DEBUG
        // Screenshot/layout QA only. Launching with `--demo-scroll-bottom` proves the REAL final item can
        // settle above the custom tab bar; unlike a source-level spacer assertion this exercises the
        // TabView → NavigationStack → ScrollView layout chain on the simulator. Absent from Release.
        .task {
            if CommandLine.arguments.contains("--demo-scroll-bottom") {
                // Some pushed destinations derive cards from repository state after their first
                // appearance. Re-assert the real end anchor after those late updates so the visual
                // harness proves footer clearance instead of capturing an obsolete early content size.
                for delay in [650_000_000, 900_000_000, 900_000_000] as [UInt64] {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(screenScaffoldBottomAnchorID, anchor: .bottom)
                }
            }
        }
        #endif
        #if os(macOS)
        // The mac window toolbar's default vibrant material washed the top of the liquid day-of-sky WHITE
        // (the scroll-under-titlebar blend). Hide it so the sky reads edge-to-edge and dark, like iOS.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        #if os(iOS)
        // Scroll-to-top on an at-root tab re-tap (#198 follow-up). iOS-only: the tab shell is the only
        // driver, and gating here keeps the two-param onChange off macOS 13. Inert until the signal moves.
        .onChange(of: scrollToTopSignal) { _, _ in
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(screenScaffoldTopAnchorID, anchor: .top) }
        }
        #endif
        }
    }

    /// The header + content column. `lazy` swaps the eager `VStack` for a `LazyVStack` so a long
    /// trailing `ForEach` (Intelligence "ALL") builds cards on demand instead of all at once. The
    /// alignment/spacing/header are identical in both branches, so the non-lazy path is byte-for-byte
    /// the previous layout. `@ViewBuilder` lets the two stack types resolve to one opaque return.
    @ViewBuilder private var column: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 20) {
                if title != nil || subtitle != nil { header }
                content()
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if title != nil || subtitle != nil { header }
                content()
            }
        }
    }

    private var header: some View {
        // A backdrop's PRESENCE says nothing about its luminance. ObsidianFlowBackground intentionally
        // becomes a light pearl relief in Light mode, so the default must remain the dynamic text tokens.
        // Fixed-dark scenes opt in explicitly; requiring a non-nil background prevents a stale override
        // from forcing white text over the flat Light-mode canvas when that scene is disabled.
        let overFixedDarkBackdrop = topBackground != nil && (topBackgroundUsesDarkHeader ?? false)
        let titleColor = overFixedDarkBackdrop ? StrandPalette.onDarkPrimary : StrandPalette.textPrimary
        let subtitleColor = overFixedDarkBackdrop ? StrandPalette.onDarkSecondary : StrandPalette.textSecondary
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(StrandFont.title1).foregroundStyle(titleColor)
                }
                if let subtitle {
                    Text(subtitle).font(StrandFont.subhead).foregroundStyle(subtitleColor)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

#if os(iOS)
/// Flat screens scroll beneath hidden navigation chrome in the custom iPhone shell. Keep text and
/// controls from competing with the system clock and battery while preserving immersive sky-backed
/// screens. The extra 6pt below the unsafe inset gives moving glyphs a clean hand-off to the canvas.
private struct FlatStatusBarScrim: View {
    var body: some View {
        GeometryReader { geometry in
            let measuredInset = max(geometry.safeAreaInsets.top, windowTopInset)
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        StrandPalette.surfaceBase.opacity(0.78),
                        StrandPalette.surfaceBase.opacity(0.46),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: (measuredInset > 0 ? measuredInset : 44) + 12)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }
}
#endif

extension ScreenScaffold where Trailing == EmptyView {
    /// Convenience init for the common case with no header trailing element — keeps every existing
    /// call site (which never passed `trailing`) source-compatible.
    init(title: LocalizedStringKey?, subtitle: LocalizedStringKey? = nil,
         onRefresh: (() async -> Void)? = nil, lazy: Bool = false, topBackground: AnyView? = nil,
         topBackgroundUsesDarkHeader: Bool? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, onRefresh: onRefresh, lazy: lazy,
                  topBackground: topBackground,
                  topBackgroundUsesDarkHeader: topBackgroundUsesDarkHeader,
                  trailing: { EmptyView() }, content: content)
    }
}

/// Applies `.refreshable` only when a refresh hook is provided. A ViewModifier (rather than an
/// inline `if`) keeps the two branches the same opaque type, and means nil callers — every macOS
/// screen — never attach the modifier at all.
private struct RefreshableIfNeeded: ViewModifier {
    let onRefresh: (() async -> Void)?
    func body(content: Content) -> some View {
        if let onRefresh {
            content.refreshable { await onRefresh() }
        } else {
            content
        }
    }
}

/// The production screen-state vocabulary. Keeping these states explicit prevents an empty result,
/// a still-loading query, and a failed query from collapsing into the same vague placeholder.
enum ScreenStateKind: String, CaseIterable, Sendable {
    case loading
    case empty
    case partial
    case stale
    case error

    fileprivate var symbol: String {
        switch self {
        case .loading: return "arrow.triangle.2.circlepath"
        case .empty:   return "tray"
        case .partial: return "chart.line.uptrend.xyaxis"
        case .stale:   return "clock.badge.exclamationmark"
        case .error:   return "exclamationmark.triangle.fill"
        }
    }

    fileprivate var tone: Color {
        switch self {
        case .loading: return StrandPalette.accent
        case .empty:   return StrandPalette.textSecondary
        case .partial: return StrandPalette.statusWarning
        case .stale:   return StrandPalette.statusWarning
        case .error:   return StrandPalette.statusCritical
        }
    }
}

/// One accessible, action-capable card for loading, empty, partial, stale, and error states.
/// The descriptive block is announced once; any recovery action remains a separate control.
struct ScreenStateCard: View {
    let kind: ScreenStateKind
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var symbol: String?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(kind: ScreenStateKind,
         title: LocalizedStringKey,
         message: LocalizedStringKey,
         symbol: String? = nil,
         actionTitle: LocalizedStringKey? = nil,
         action: (() -> Void)? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.symbol = symbol
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    stateMark
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text(title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(message)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(message))

                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                }
            }
        }
    }

    @ViewBuilder private var stateMark: some View {
        if kind == .loading && !reduceMotion {
            ProgressView()
                .controlSize(.small)
                .tint(kind.tone)
        } else {
            Image(systemName: symbol ?? kind.symbol)
                .font(StrandFont.headline)
                .foregroundStyle(kind.tone)
        }
    }
}

/// Compatibility wrapper for older call sites. New work should choose a precise `ScreenStateKind`.
struct ComingSoon: View {
    let what: LocalizedStringKey
    var symbol: String = "sparkles"
    var body: some View {
        ScreenStateCard(
            kind: .empty,
            title: "Coming together",
            message: what,
            symbol: symbol
        )
    }
}

/// A reusable "what shows now vs what needs an import" note. Bold title line plus a
/// body line, with an info/sparkles SF Symbol. Used for empty/pending data states so
/// every screen explains the live-now path and the import path with timing.
/// Pulsing "history sync in progress" line (#77). Shown above a screen's empty state while the
/// strap's historical offload runs, so a half-loaded screen ("No nights here yet") reads as
/// in-progress rather than final. Shows batches received, durable rows saved, and the newest timestamp
/// reached — never a percent (total pending is unknowable from the protocol).
struct SyncingHistoryNote: View {
    let chunks: Int
    let rows: Int
    let newestDataUnix: Int?
    let startedAt: TimeInterval?
    let lastDurableProgressAt: TimeInterval?

    init(
        chunks: Int,
        rows: Int = 0,
        newestDataUnix: Int? = nil,
        startedAt: TimeInterval? = nil,
        lastDurableProgressAt: TimeInterval? = nil
    ) {
        self.chunks = chunks
        self.rows = rows
        self.newestDataUnix = newestDataUnix
        self.startedAt = startedAt
        self.lastDurableProgressAt = lastDurableProgressAt
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                StatePill("Syncing Noop Band history…", tone: .accent, pulsing: true)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(activityLabel(now: context.date.timeIntervalSince1970))
                        .foregroundStyle(activityTone(now: context.date.timeIntervalSince1970))
                    Spacer(minLength: 8)
                    Text(elapsedLabel(now: context.date.timeIntervalSince1970))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .font(StrandFont.footnote)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "appwide.today.band_sync.batches_format"),
                        Int64(chunks)
                    )
                )
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                Text(persistedDetail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activityLabel(now: TimeInterval) -> String {
        let key: String
        switch HistorySyncDurableProgressPolicy.activity(
            startedAt: startedAt,
            lastDurableProgressAt: lastDurableProgressAt,
            now: now
        ) {
        case .starting: key = "appwide.today.band_sync.activity_starting"
        case .advancing: key = "appwide.today.band_sync.activity_advancing"
        case .waiting: key = "appwide.today.band_sync.activity_waiting"
        case .stalled: key = "appwide.today.band_sync.activity_stalled"
        }
        return String(localized: String.LocalizationValue(key))
    }

    private func activityTone(now: TimeInterval) -> Color {
        switch HistorySyncDurableProgressPolicy.activity(
            startedAt: startedAt,
            lastDurableProgressAt: lastDurableProgressAt,
            now: now
        ) {
        case .starting, .advancing: return StrandPalette.statusPositive
        case .waiting: return StrandPalette.statusWarning
        case .stalled: return StrandPalette.statusCritical
        }
    }

    private func elapsedLabel(now: TimeInterval) -> String {
        String.localizedStringWithFormat(
            String(localized: "appwide.today.band_sync.elapsed_format"),
            historySyncElapsedClock(startedAt: startedAt, now: now)
        )
    }

    private var persistedDetail: String {
        guard let newestDataUnix else {
            return String.localizedStringWithFormat(
                String(localized: "appwide.today.band_sync.rows_format"),
                Int64(rows)
            )
        }
        let date = Date(timeIntervalSince1970: TimeInterval(newestDataUnix))
            .formatted(.dateTime.year().month(.abbreviated).day())
        return String.localizedStringWithFormat(
            String(localized: "appwide.today.band_sync.rows_ready_format"),
            Int64(rows),
            date
        )
    }
}

func historySyncElapsedClock(startedAt: TimeInterval?, now: TimeInterval) -> String {
    let total = max(0, Int(now - (startedAt ?? now)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}

/// Coarse relative-time label for the "History synced N ago" sync-status line. Pure - `now` is
/// injectable so the bucket edges are unit-testable (RelativeAgoTests) — and deliberately the same
/// buckets as the Android `relativeAgo` (LiveScreen.kt, ed6a31d) so the two apps read identically.
/// Clamps future timestamps (strap-clock skew) to "just now", never negative.
func relativeAgo(_ epochSeconds: TimeInterval,
                 now: TimeInterval = Date().timeIntervalSince1970) -> String {
    let d = max(0, Int(now - epochSeconds))
    switch d {
    case ..<60:     return String(localized: "just now")
    case ..<3600:   return String(localized: "\(d / 60) min ago")
    case ..<86_400: return String(localized: "\(d / 3600) h ago")
    default:        return String(localized: "\(d / 86_400) d ago")
    }
}

struct DataPendingNote: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var symbol: String = "sparkles"

    var body: some View {
        ScreenStateCard(kind: .partial, title: title, message: message, symbol: symbol)
    }
}

// MARK: - Scroll-to-top signal (#198 follow-up)

/// An incrementing token the iOS tab shell bumps when the user re-taps the ALREADY-at-root active tab,
/// to scroll that tab's root screen to the top (the other half of the iOS tab convention #197/#198 left
/// unserved — an at-root re-tap is otherwise a no-op). `ScreenScaffold` and `LiquidTodayView` observe it
/// and scroll to their top anchor when it changes. Default 0 is never bumped outside the tab shell, so
/// macOS (sidebar, no tab re-tap) and every non-tab screen are completely unaffected.
/// Zero-height scroll-to-top target id. File scope, not a `static` on `ScreenScaffold` — the latter is
/// generic (`<Content, Trailing>`) and Swift forbids stored static properties on generic types.
private let screenScaffoldTopAnchorID = "screenScaffold.top"
private let screenScaffoldBottomAnchorID = "screenScaffold.bottom"
#if os(iOS)
private let screenScaffoldScrollSpace = "screenScaffold.scroll"

private struct ScreenScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// iOS 18 exposes the actual scroll geometry, including programmatic jumps and inertial movement. Keep
/// the preference probe only as the iOS 17 compatibility path; newer SwiftUI versions can collapse or
/// virtualize its frame and report a constant zero even while content is visibly scrolled.
private struct ScreenScrollPositionReporter: ViewModifier {
    let report: (CGFloat) -> Void
    @State private var legacyTopOffset: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                // UIKit-style content offsets begin above zero by the adjusted top inset. Normalize that
                // inset away so every screen reports 0 at rest and negative distance as it advances,
                // independent of its safe area, header height, or whether it is a pushed destination.
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                report(offset)
            }
        } else {
            content
                .coordinateSpace(name: screenScaffoldScrollSpace)
                .onPreferenceChange(ScreenScrollOffsetPreferenceKey.self) { offset in
                    if legacyTopOffset == nil { legacyTopOffset = offset }
                    report(offset - (legacyTopOffset ?? offset))
                }
        }
    }
}

/// Runtime visual QA needs a deterministic initial endpoint. A proxy jump can race a pushed
/// NavigationStack destination before its scroll view has established content geometry; the native
/// default anchor is applied at layout time and remains entirely absent from Release builds.
private struct DemoBottomScrollAnchor: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if CommandLine.arguments.contains("--demo-scroll-bottom") {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
#endif

private struct ScrollToTopSignalKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var scrollToTopSignal: Int {
        get { self[ScrollToTopSignalKey.self] }
        set { self[ScrollToTopSignalKey.self] = newValue }
    }

    var scrollPositionReporter: (CGFloat) -> Void {
        get { self[ScrollPositionReporterKey.self] }
        set { self[ScrollPositionReporterKey.self] = newValue }
    }
}

private struct ScrollPositionReporterKey: EnvironmentKey {
    static let defaultValue: (CGFloat) -> Void = { _ in }
}
