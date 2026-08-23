import SwiftUI

/// The data-visualisation colour style: the brand "Titanium & Gold" data ramps, or a "Classic"
/// throwback — the recognizable red → amber → green readiness scale (cool→hot zones, green→red stress,
/// purple REM) that health apps have always used. Works in BOTH light and dark. It only re-colours the
/// DATA encodings (gauge rings, charts, sparklines, scales, stage bands) — never the chrome/surfaces.
///
/// Read globally via `StrandPalette.chartStyle` (set from `@AppStorage(ChartStyle.storageKey)` at the
/// app root); the data-ramp accessors in `StrandPalette` branch on it. The app root keys its content on
/// the raw value so a flip re-renders the visible charts live.
public enum ChartStyle: String, CaseIterable, Identifiable, Sendable {
    case titanium   // brand: gold recovery, amber strain, blue rest
    case classic    // throwback: red→green recovery, cool→hot zones, green→red stress

    public var id: String { rawValue }
    public static let storageKey = "chart.style"

    public var label: String {
        switch self {
        case .titanium: return String(localized: "Default", bundle: .module)
        case .classic:  return String(localized: "Classic", bundle: .module)
        }
    }

    public static func resolve(_ raw: String) -> ChartStyle { ChartStyle(rawValue: raw) ?? .titanium }
}

/// Applies the chart style: sets the global `StrandPalette.chartStyle` (read by the data-ramp
/// accessors) AND keys the content on the raw value so a flip re-renders the visible charts. The
/// global is set during body evaluation, before the keyed content renders, so the new ramps are live
/// on the rebuild. Apply at each app root: `.chartStyle(chartStyleRaw)`.
public extension View {
    func chartStyle(_ raw: String) -> some View {
        StrandPalette.chartStyle = ChartStyle.resolve(raw)
        return self.id("noop.chartStyle.\(raw)")
    }
}

/// The user's appearance preference for the whole app. Persisted via
/// `@AppStorage(AppearanceMode.storageKey)`. `.black` is the first-run default and uses a true-black
/// OLED canvas with quieter relief. `.system` follows the OS, `.light` uses NOOP's pearl finish, and
/// `.dark` uses dimensional graphite.
///
/// Apply it once at each app root with `.noopAppearance(rawValue)`. Dark and Black both request
/// the system dark colour scheme, while the full mode is also carried through the environment so
/// shared surfaces can distinguish graphite from true black without resetting navigation state.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark
    case black

    public var id: String { rawValue }

    /// The @AppStorage key shared by the app roots and the Settings picker.
    public static let storageKey = "theme.appearance"
    /// New installs start in NOOP's signature OLED finish. A stored user choice always wins.
    public static let defaultMode = AppearanceMode.black

    /// Human label for the Settings control.
    public var label: String {
        switch self {
        case .system: return String(localized: "System", bundle: .module)
        case .light:  return String(localized: "Light", bundle: .module)
        case .dark:   return String(localized: "Dark", bundle: .module)
        case .black:  return String(localized: "Black", bundle: .module)
        }
    }

    /// Short material name shown beneath the theme label in the visual selector.
    public var detail: String {
        switch self {
        case .system: return String(localized: "Follows device", bundle: .module)
        case .light:  return String(localized: "Soft pearl", bundle: .module)
        case .dark:   return String(localized: "Graphite", bundle: .module)
        case .black:  return String(localized: "True black", bundle: .module)
        }
    }

    /// SF Symbol for the Settings control.
    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon.stars"
        case .black:  return "circle.inset.filled"
        }
    }

    /// The `ColorScheme` to force, or `nil` to follow the system (the `.system` case).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark, .black: return .dark
        }
    }

    /// Resolve a stored raw value (tolerant of an unknown/missing value → the first-run default).
    public static func resolve(_ raw: String) -> AppearanceMode {
        AppearanceMode(rawValue: raw) ?? defaultMode
    }
}

private struct NoopAppearanceEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppearanceMode.defaultMode
}

public extension EnvironmentValues {
    /// The complete NOOP appearance, including the Dark-vs-OLED distinction that `ColorScheme`
    /// cannot represent on its own.
    var noopAppearanceMode: AppearanceMode {
        get { self[NoopAppearanceEnvironmentKey.self] }
        set { self[NoopAppearanceEnvironmentKey.self] = newValue }
    }
}

private struct NoopAppearanceModifier: ViewModifier {
    let rawValue: String

    func body(content: Content) -> some View {
        let mode = AppearanceMode.resolve(rawValue)
        // Palette access is lock-protected. Set it while constructing the root so every computed
        // surface token created in this update uses the same graphite/OLED variant.
        StrandPalette.appearanceMode = mode
        return content
            .environment(\.noopAppearanceMode, mode)
            .preferredColorScheme(mode.colorScheme)
    }
}

public extension View {
    /// Apply NOOP's complete appearance at an app/scene root. Unlike keying the whole root, this keeps
    /// tab paths, sheets, and scroll positions alive when a person changes the finish in place.
    func noopAppearance(_ rawValue: String) -> some View {
        modifier(NoopAppearanceModifier(rawValue: rawValue))
    }
}

/// A tactile, accessible four-finish selector shared by onboarding and Settings. Each option previews
/// its actual base/elevated surface relationship; physiological colours intentionally do not change.
public struct AppearancePickerGrid: View {
    @Binding private var selection: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(selection: Binding<String>) {
        _selection = selection
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(AppearanceMode.allCases) { mode in
                option(mode)
            }
        }
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    private func option(_ mode: AppearanceMode) -> some View {
        let selected = AppearanceMode.resolve(selection) == mode
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                selection = mode.rawValue
            }
        } label: {
            HStack(spacing: 10) {
                AppearanceSwatch(mode: mode)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(mode.detail)
                        .font(.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 2)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 72 : 58,
                   alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? StrandPalette.accentMuted : StrandPalette.surfaceInset.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? StrandPalette.hairlineStrong : StrandPalette.hairline, lineWidth: selected ? 1.2 : 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityValue(selected ? String(localized: "Selected", bundle: .module) : mode.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AppearanceSwatch: View {
    let mode: AppearanceMode

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        ZStack {
            shape.fill(base)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(raised)
                .frame(width: 22, height: 15)
                .offset(x: 4, y: 5)
            Circle()
                .fill(ink)
                .frame(width: 7, height: 7)
                .offset(x: -8, y: -8)
        }
        .overlay(shape.strokeBorder(rim, lineWidth: 0.8))
        .shadow(color: .black.opacity(mode == .light ? 0.10 : 0.28), radius: 3, y: 2)
        .accessibilityHidden(true)
    }

    private var base: Color {
        switch mode {
        case .system:
            return Color(light: "#EEF0F2", dark: "#0A0B0D")
        case .light: return Color(hex: "#EEF0F2")
        case .dark:  return Color(hex: "#0A0B0D")
        case .black: return Color(hex: "#000000")
        }
    }

    private var raised: Color {
        switch mode {
        case .system:
            return Color(light: "#FAFBFC", dark: "#17191D")
        case .light: return Color(hex: "#FAFBFC")
        case .dark:  return Color(hex: "#17191D")
        case .black: return Color(hex: "#0A0A0B")
        }
    }

    private var ink: Color {
        switch mode {
        case .system: return Color(light: "#15171A", dark: "#F7F7F5")
        case .light:  return Color(hex: "#15171A")
        case .dark, .black: return Color(hex: "#F7F7F5")
        }
    }

    private var rim: Color {
        switch mode {
        case .light: return Color.black.opacity(0.16)
        default: return Color.white.opacity(0.20)
        }
    }
}

/// The day-cycle scene backdrop behind the Today screen (sunrise / day / dusk / night). Default ON —
/// the scene is the v7 atmosphere. Some people find it distracting and want a plain dark canvas (#698),
/// so this gates whether Today passes a `SceneScreenBackground` into its scaffold. When OFF, Today drops
/// the scene and falls back to the opaque `surfaceBase`; the cards already sit on an opaque canvas, so
/// they stay perfectly readable. Read in `TodayView` via `@AppStorage(SceneBackgroundPrefs.enabledKey)`
/// and toggled from Settings → Appearance. Mirror in Kotlin via `NoopPrefs.showDayCycleBackground`.
public enum SceneBackgroundPrefs {
    /// The @AppStorage key shared by TodayView and the Settings toggle. Default value is `true`.
    public static let enabledKey = "noop.showDayCycleBackground"
}

/// Card-surface opacity as a PERCENT (0 = fully see-through, 100 = solid; default 100). `FrostedCardSurface`
/// reads it via `@AppStorage(CardAppearancePrefs.opacityKey)` and fades the whole glass by it, so cards
/// (Heart Rate, Key Metrics, Recovery Vitals, …) can be made see-through from Settings → Appearance; the
/// card content stays fully readable. Mirror in Kotlin via `NoopPrefs.cardOpacityPercent`.
public enum CardAppearancePrefs {
    public static let opacityKey = "noop.cardOpacityPercent"
    public static let defaultPercent = 100
}

/// "Background behind cards" (default ON): extend the dimensional material behind the WHOLE scroll (not
/// just the top band) so the Card-transparency setting reveals it under every card. Read in `LiquidTodayView`
/// via `@AppStorage(SkyBehindCardsPrefs.enabledKey)` and toggled from Settings → Appearance. Mirror in
/// Kotlin via `NoopPrefs.skyBehindCards`.
public enum SkyBehindCardsPrefs {
    public static let enabledKey = "noop.skyBehindCards"
    public static let defaultEnabled = true
}

// MARK: - Light-idiom helpers

/// An additive glow (ring blooms, sparkline heads, hero halos) only reads on a DARK canvas —
/// `.plusLighter` blending on white produces no visible glow and just muddies edges. On dark this
/// applies the additive blend; on light it hides the layer. Self-contained (reads the scheme itself)
/// so every glow becomes a one-token swap from `.blendMode(.plusLighter)` → `.additiveBloom()`.
private struct AdditiveBloom: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        // Dialed back (0.55) — the full-strength additive bloom read as too much glow against the
        // crisper design language. Still present on dark for depth, just restrained.
        if scheme == .dark { content.blendMode(.plusLighter).opacity(0.55) }
        else { content.opacity(0) }
    }
}

/// Card / floating-surface elevation. Dark separates surfaces by a lighter FILL (no resting shadow);
/// light separates white-on-paper by a soft DROP SHADOW. Reads the scheme itself and deepens on hover.
private struct NoopElevation: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var hovering: Bool
    func body(content: Content) -> some View {
        let lightShadow = Color(hex: "#1A2230")
        return content.shadow(
            color: scheme == .light ? lightShadow.opacity(hovering ? 0.16 : 0.09)
                                    : Color.black.opacity(hovering ? 0.45 : 0.0),
            radius: scheme == .light ? (hovering ? 14 : 10) : (hovering ? 18 : 0),
            x: 0, y: scheme == .light ? (hovering ? 5 : 3) : (hovering ? 8 : 0)
        )
    }
}

public extension View {
    /// Apply the additive glow only on dark; hide it on light. See `AdditiveBloom`.
    func additiveBloom() -> some View { modifier(AdditiveBloom()) }

    /// Apply the per-scheme card/surface elevation (shadow on light, lighter-fill idiom on dark).
    func noopElevation(hovering: Bool = false) -> some View { modifier(NoopElevation(hovering: hovering)) }
}
