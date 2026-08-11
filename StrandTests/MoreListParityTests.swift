import XCTest
@testable import Strand

/// Guards the #805/#811 regression: the v7.3.1 #766 alarm consolidation folded Smart Alarm under a
/// single "Alarms" entry in the macOS/iPad sidebar (`NavItem.smartAlarm`), but the iPhone `RootTabView`
/// More list dropped the row, leaving Alarms unreachable on iPhone.
///
/// The iPhone More list is a `@ViewBuilder` (not directly introspectable), so this pins the *contract*
/// it must mirror: the shared sidebar exposes the `smartAlarm` destination with the exact SF Symbol the
/// restored `MoreRow("Alarms", "alarm.fill")` row uses. A future icon rename then fails here so the two
/// shells get fixed in lockstep rather than silently drifting apart again.
///
/// Notifications (`NavItem.notifications`) is deliberately NOT mirrored on iPhone: its screen
/// (`NotificationSettingsView`) is macOS-only (NSWorkspace app picker, imports AppKit, excluded from the
/// iOS target in project.yml), so the iPhone More list correctly omits it. The enum case still exists for
/// the macOS sidebar; that's all this asserts about it.
final class MoreListParityTests: XCTestCase {

    private func sourceText(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Alarms is the destination the iPhone More list had been missing; it must exist in the shared
    /// sidebar enum (the iPhone `MoreRow("Alarms")` routes to the same `SmartAlarmView`).
    func testSidebarExposesAlarms() {
        XCTAssertTrue(NavItem.allCases.contains(.smartAlarm),
                      "Alarms (smartAlarm) must stay a sidebar destination the iPhone More list mirrors.")
    }

    /// The restored iPhone Alarms row pins this exact SF Symbol; keep it identical to the sidebar so the
    /// two shells read the same.
    func testAlarmsIconMatchesTheRestorediPhoneRow() {
        XCTAssertEqual(NavItem.smartAlarm.icon, "alarm.fill")
    }

    /// Notifications stays a (macOS-only) sidebar destination. It is intentionally absent from the iPhone
    /// More list, so this only documents that the enum case is still the macOS home for it.
    func testNotificationsRemainsAMacOSSidebarDestination() {
        XCTAssertTrue(NavItem.allCases.contains(.notifications))
    }

    // MARK: - M5 gate (S1 grouping): every destination stays reachable after grouping

    /// The S1 macOS sidebar grouping (#805) folds the flat `NavItem` cases into collapsible
    /// `NavGroup`s. The regression it guards against is a destination silently vanishing during a
    /// consolidation (the way the iPhone Smart-Alarm row did). This pins the contract: EVERY `NavItem`
    /// case must appear in exactly one group, so nothing is dropped and nothing is double-listed.
    func testEveryNavItemIsReachableInExactlyOneGroup() {
        let grouped = NavGroup.all.flatMap(\.items)

        // 1. No destination lost: every enum case is somewhere in the grouped layout.
        for item in NavItem.allCases {
            XCTAssertTrue(grouped.contains(item),
                          "NavItem.\(item.rawValue) is not reachable in any sidebar group after S1 grouping.")
        }

        // 2. No destination duplicated: a case must live in exactly one group (count == cases).
        XCTAssertEqual(grouped.count, NavItem.allCases.count,
                       "Sidebar groups list \(grouped.count) rows for \(NavItem.allCases.count) destinations; a case is duplicated or stray.")
        XCTAssertEqual(Set(grouped).count, NavItem.allCases.count,
                       "A NavItem appears in more than one sidebar group.")
    }

    /// Smart Alarm (the #805 casualty) must survive the S1 grouping too: it has to resolve to a group, so
    /// it is reachable in the collapsible sidebar, not just present as an orphaned enum case.
    func testSmartAlarmResolvesToAGroupAfterGrouping() {
        XCTAssertNotNil(NavGroup.group(containing: .smartAlarm),
                        "Alarms (smartAlarm) must belong to a sidebar group so it stays reachable post-S1.")
    }

    /// S6: the four overlapping insight surfaces (Intelligence / What Moves You / Insights / Insights Hub)
    /// collapse under one Insights group rather than scattering across the flat list. Pin that they share a
    /// single group so a future edit can't re-scatter them.
    func testInsightSurfacesShareOneGroup() {
        let insightItems: [NavItem] = [.intelligence, .insightsHub, .insights]
        let groups = Set(insightItems.compactMap { NavGroup.group(containing: $0)?.id })
        XCTAssertEqual(groups.count, 1,
                       "The overlapping insight surfaces must collapse under a single sidebar group (S6).")
    }

    /// The initial expanded set keeps the sidebar to "headers + the active group": every single-item group
    /// plus the group owning the launch selection, and nothing more (the heavy groups stay collapsed).
    func testInitialExpansionShowsActiveGroupPlusSingletons() {
        let open = RootView.initialExpandedGroups(for: .today)
        // Today's own group is expanded.
        XCTAssertTrue(open.contains("today"))
        // Single-item groups are expanded so their lone row is visible.
        XCTAssertTrue(open.contains("sleep"))
        // A heavy group the user hasn't entered stays collapsed at rest.
        XCTAssertFalse(open.contains("data_app"))
    }

    /// The iPhone shell owns one custom bar outside the native TabView. Its clearance must come from
    /// that bar's rendered height and constrain the whole TabView; relying on a safe-area inset through
    /// TabView + NavigationStack, or adding per-screen magic spacers, regresses the final-card reachability
    /// on custom roots such as LiquidToday.
    func testCustomiPhoneTabBarHasOneMeasuredFullScreenReservation() throws {
        let shell = try sourceText("StrandiOS/App/RootTabView.swift")
        let scaffold = try sourceText("Strand/Screens/ScreenScaffold.swift")
        let liquidToday = try sourceText("Strand/Liquid/LiquidTodayView.swift")

        XCTAssertTrue(shell.contains("FloatingTabBarHeightPreferenceKey"))
        XCTAssertTrue(shell.contains("value: geometry.size.height"))
        XCTAssertEqual(shell.components(separatedBy: ".padding(.bottom, visibleTabBarHeight)").count - 1, 1,
                       "The measured custom-bar clearance must be reserved exactly once at the TabView root.")
        XCTAssertTrue(shell.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"),
                      "The overlay alignment needs a full-screen shell or the bar can settle mid-layout.")
        XCTAssertFalse(shell.contains(".safeAreaInset(edge: .bottom"),
                       "A keyboard-following safe-area inset can lift the custom bar into mid-screen.")
        XCTAssertFalse(shell.contains("DragGesture(minimumDistance: 24)"),
                       "The tab shell must not steal horizontal drags from Trends or the system Back gesture.")

        XCTAssertTrue(shell.contains("if !keyboardVisible"))
        XCTAssertTrue(shell.contains("UIResponder.keyboardWillShowNotification"))
        XCTAssertTrue(shell.contains("UIResponder.keyboardDidHideNotification"),
                      "The bar must return only after UIKit restores the bottom safe area.")
        XCTAssertFalse(shell.contains("UIResponder.keyboardWillHideNotification"),
                       "Restoring during keyboard dismissal briefly lays the bar out in mid-screen.")

        XCTAssertFalse(scaffold.contains("tabBarClearance"),
                       "ScreenScaffold must not duplicate the shell's measured reservation.")
        XCTAssertFalse(liquidToday.contains("Color.clear.frame(height: 90)"),
                       "LiquidToday must inherit the tab-root reservation instead of a magic spacer.")
        XCTAssertTrue(liquidToday.contains(".padding(.bottom, NoopMetrics.space4)"),
                      "LiquidToday needs only the standard visual gap above the shell-owned bar clearance.")
        XCTAssertTrue(scaffold.contains("screenScaffoldBottomAnchorID"))
        XCTAssertTrue(liquidToday.contains("private static let bottomAnchorID"))
        XCTAssertTrue(scaffold.contains("--demo-scroll-bottom"))
        XCTAssertTrue(liquidToday.contains(".task(id: dataLoaded)"),
                      "Liquid Today's bottom proof must wait for async cards instead of racing a timer.")
        XCTAssertTrue(liquidToday.contains("--demo-scroll-bottom"),
                      "Both scroll implementations need the DEBUG runtime bottom-reachability proof.")
    }

    /// The reference interaction is an Instagram-style glass island: labelled at rest, compact while
    /// advancing through content, and expanded again when the finger moves back toward the top. Pin the
    /// direction and accessibility contracts because a visual-only refactor can otherwise reintroduce
    /// the opaque white plate or hide navigation names from assistive technology.
    func testiPhoneTabBarIsAdaptiveGlass() throws {
        let shell = try sourceText("StrandiOS/App/RootTabView.swift")

        XCTAssertTrue(shell.contains(".simultaneousGesture(adaptiveTabBarGesture)"))
        XCTAssertTrue(shell.contains("abs(dy) > abs(dx) * 1.15"),
                      "Horizontal charts and Back gestures must not collapse the bar.")
        XCTAssertTrue(shell.contains("tabBarDragAccumulator <= -14"))
        XCTAssertTrue(shell.contains("tabBarDragAccumulator >= 10"))
        XCTAssertTrue(shell.contains("height > measuredTabBarHeight + 0.5"),
                      "The shell must retain its largest reservation while the bar compacts.")
        XCTAssertTrue(shell.contains("--demo-compact-tab-bar"),
                      "The real compact state needs a deterministic visual-regression route.")
        XCTAssertTrue(shell.contains(".glassEffect(.clear.tint(tint)"))
        XCTAssertTrue(shell.contains(".white.opacity(0.08)"),
                      "Light mode must preserve a pearl-clear lens instead of a solid grey plate.")
        XCTAssertTrue(shell.contains(".black.opacity(0.035)"),
                      "Light mode may use only a restrained contrast scrim over the live page.")
        XCTAssertTrue(shell.contains("navigationInk(active: active)"),
                      "Navigation ink must adapt to light and dark glass.")
        XCTAssertTrue(shell.contains(".opacity(navigationGlassOpacity)"),
                      "Light mode must fade only the material layer, never the navigation ink.")
        XCTAssertTrue(shell.contains("accessibilityReduceTransparency"),
                      "The glass island needs an opaque accessibility fallback.")
        XCTAssertTrue(shell.contains("compact && !dynamicTypeSize.isAccessibilitySize"),
                      "Accessibility Dynamic Type must retain visible labels.")
        XCTAssertTrue(shell.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(shell.contains(".accessibilityLabel(item.title)"))
    }

    /// ObsidianFlow is intentionally adaptive: dark hardware in Dark mode, pearl relief in Light mode.
    /// Merely supplying it as `topBackground` must never force white/on-dark header ink. Fixed-dark
    /// scenes remain an explicit opt-in so their contrast contract is visible at the call site.
    func testAdaptiveScaffoldBackgroundUsesDynamicInk() throws {
        let scaffold = try sourceText("Strand/Screens/ScreenScaffold.swift")
        let shell = try sourceText("StrandiOS/App/RootTabView.swift")
        let live = try sourceText("Strand/Screens/LiveView.swift")
        let classicToday = try sourceText("Strand/Screens/TodayView.swift")
        let liquidToday = try sourceText("Strand/Liquid/LiquidTodayView.swift")

        XCTAssertTrue(scaffold.contains("topBackgroundUsesDarkHeader ?? false"))
        XCTAssertFalse(scaffold.contains("topBackgroundUsesDarkHeader ?? showDayCycleBackground"))
        XCTAssertFalse(shell.contains("headerIsOverSky"))
        XCTAssertFalse(shell.contains("let overSky = showDayCycleBackground"))
        XCTAssertTrue(live.contains("topBackgroundUsesDarkHeader: true"),
                      "Live's genuinely fixed-dark console backdrop must retain explicit on-dark ink.")
        XCTAssertTrue(classicToday.contains("topBackgroundUsesDarkHeader: true"),
                      "The photographic Today scene must retain its explicit dark-scrim contract.")
        XCTAssertFalse(liquidToday.contains("usesDarkSkyBehindCards"),
                       "Liquid Today cannot infer fixed-white ink from an adaptive scene preference.")
        XCTAssertTrue(liquidToday.contains(".font(StrandFont.rounded(34))\n                        .foregroundStyle(StrandPalette.textPrimary)"),
                      "Liquid Today's day title must use adaptive ink on pearl/obsidian backgrounds.")
        XCTAssertTrue(liquidToday.contains("compact ? StrandPalette.textSecondary : StrandPalette.textTertiary"),
                      "The NOOP wordmark must remain visible in both Light and Dark appearances.")
        XCTAssertTrue(liquidToday.contains("StrandPalette.surfaceRaised.opacity(0.82)"),
                      "Masthead controls need an adaptive raised surface instead of white-on-pearl glass.")
    }
}
