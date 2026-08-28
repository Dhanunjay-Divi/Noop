package com.noop.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.StringRes
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import com.noop.R
import com.noop.widget.WidgetSnapshotStore

// MARK: - PaletteTokens — the per-scheme colour set behind `object Palette`
//
// Compose has no OS-dynamic colour (unlike iOS UIColor(light:dark:)), so the light theme is built
// the same way conceptually: ONE set of colour tokens, swapped wholesale per scheme. `Palette.active`
// is snapshot state, so every `Palette.X` read (in a composable OR a Canvas DrawScope) re-resolves
// automatically when the theme flips — ZERO call-site changes across the ~1,740 references.
//
// Chrome values mirror StrandPalette.swift's Pearl/Graphite/Black finishes. Names/order match the
// Swift palette; physiological data colours stay platform-consistent and do not change with chrome.

data class PaletteTokens(
    val surfaceBase: Color,
    val surfaceRaised: Color,
    val surfaceOverlay: Color,
    val surfaceInset: Color,
    val hairline: Color,
    val hairlineStrong: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val glowAmbient: Color,
    val accent: Color,
    val accentHover: Color,
    val accentMuted: Color,
    val focusRing: Color,
    /** Ink placed on [accent]: white on light-mode black, near-black on dark-mode pearl. */
    val accentInk: Color,
    val recovery000: Color,
    val recovery030: Color,
    val recovery055: Color,
    val recovery078: Color,
    val recovery100: Color,
    val strain000: Color,
    val strain033: Color,
    val strain066: Color,
    val strain100: Color,
    val sleepAwake: Color,
    val sleepLight: Color,
    val sleepDeep: Color,
    val sleepREM: Color,
    val zone1: Color,
    val zone2: Color,
    val zone3: Color,
    val zone4: Color,
    val zone5: Color,
    val statusPositive: Color,
    val statusWarning: Color,
    val statusCritical: Color,
    val statusPositiveText: Color,
    val statusWarningText: Color,
    val statusCriticalText: Color,
    val metricCyan: Color,
    val metricPurple: Color,
    val metricAmber: Color,
    val metricRose: Color,
    val chargeColor: Color,
    val chargeDeep: Color,
    val chargeBright: Color,
    val chargeGlow: Color,
    val effortColor: Color,
    val effortDeep: Color,
    val effortBright: Color,
    val effortGlow: Color,
    val restColor: Color,
    val restDeep: Color,
    val restBright: Color,
    val restGlow: Color,
    val stressColor: Color,
    val stressDeep: Color,
    val stressBright: Color,
    val stressGlow: Color,
    val scenicCenter: Color,
    val scenicEdge: Color,
    val scenicStar: Color,
    val cardFillTop: Color,
    val cardFillBottom: Color,
    val gold: Color,
    val goldLight: Color,
    val goldDeep: Color,
    val goldDeepText: Color,
    val signalYellow: Color,
    val titaniumTop: Color,
    val titaniumMid: Color,
    val titaniumLow: Color,
    val titaniumDeep: Color,
    // The bright gauge-tip / sparkline-head core: white reads as a highlight on dark; on light it
    // would vanish into the white card, so it flips to a deep ink (crisp centre on the coloured bead).
    val tipCore: Color,
)

// Graphite palette. Values match StrandPalette.swift's DARK Titanium column byte-for-byte:
// neutral chrome, WHOOP red→yellow→green recovery, green Charge, blue Effort, slate Rest,
// amber Stress. The legacy `gold*` API remains blue for data-viz compatibility; chrome is monochrome.
val DarkTokens = PaletteTokens(
    surfaceBase = Color(0xFF0C0D0F), surfaceRaised = Color(0xFF17191C), surfaceOverlay = Color(0xFF1D2024),
    surfaceInset = Color(0xFF101215), hairline = Color(0xFF2A2E33), hairlineStrong = Color(0xFF434951),
    textPrimary = Color(0xFFF7F7F5), textSecondary = Color(0xFFC7C7C2), textTertiary = Color(0xFF989893),
    glowAmbient = Color(0xFFFFFFFF),
    accent = Color(0xFFF7F7F5), accentHover = Color(0xFFFFFFFF), accentMuted = Color(0xFF24262B), focusRing = Color(0xFFE7E7E2),
    accentInk = Color(0xFF070707),
    recovery000 = Color(0xFFE0463C), recovery030 = Color(0xFFE8743C), recovery055 = Color(0xFFF9DF4A),
    recovery078 = Color(0xFF8FD86A), recovery100 = Color(0xFF03E095),
    strain000 = Color(0xFF9C5A14), strain033 = Color(0xFFC2762A), strain066 = Color(0xFFD98A3D), strain100 = Color(0xFFF0A85A),
    sleepAwake = Color(0xFFCAC8CB), sleepLight = Color(0xFFA7A4F4), sleepDeep = Color(0xFFFD96FD), sleepREM = Color(0xFFAE5BEF),
    zone1 = Color(0xFF4A90E2), zone2 = Color(0xFF3FA9C9), zone3 = Color(0xFFE8B84B), zone4 = Color(0xFFD98A3D), zone5 = Color(0xFFE0662F),
    statusPositive = Color(0xFF03E095), statusWarning = Color(0xFFF0A020), statusCritical = Color(0xFFE0662F),
    statusPositiveText = Color(0xFF03E095), statusWarningText = Color(0xFFF0A020), statusCriticalText = Color(0xFFE0662F),
    metricCyan = Color(0xFF3FA9C9), metricPurple = Color(0xFF4A90E2), metricAmber = Color(0xFFD98A3D), metricRose = Color(0xFFE0662F),
    chargeColor = Color(0xFF03E095), chargeDeep = Color(0xFF0B9D62), chargeBright = Color(0xFF6BF0B4), chargeGlow = Color(0xFF03E095),
    effortColor = Color(0xFF4090E0), effortDeep = Color(0xFF2A6FB0), effortBright = Color(0xFF74B6F0), effortGlow = Color(0xFF4090E0),
    restColor = Color(0xFF83A0B8), restDeep = Color(0xFF2F6FCB), restBright = Color(0xFF6FA8E8), restGlow = Color(0xFF4A90E2),
    stressColor = Color(0xFFF0A020), stressDeep = Color(0xFF4A90E2), stressBright = Color(0xFFE0662F), stressGlow = Color(0xFFF0A020),
    scenicCenter = Color(0xFF1C2128), scenicEdge = Color(0xFF121518), scenicStar = Color(0xFFC8CFD8),
    cardFillTop = Color(0xFF15243C), cardFillBottom = Color(0xFF0B1424),
    gold = Color(0xFF60A0E0), goldLight = Color(0xFF9FC8F0), goldDeep = Color(0xFF3A78C8),
    goldDeepText = Color(0xFFFFFFFF), signalYellow = Color(0xFFFFD63D),
    titaniumTop = Color(0xFFF1F3F5), titaniumMid = Color(0xFFC9CFD4), titaniumLow = Color(0xFF969DA4), titaniumDeep = Color(0xFF6B737B),
    tipCore = Color(0xFFFFFFFF),
)

// OLED Black keeps every physiological/data colour identical to Dark and changes only the chrome.
// The canvas is true black, while cards and dividers retain a small luminance step so hierarchy does
// not collapse into a flat sheet. This is a real fourth appearance, not a renamed dark mode.
val BlackTokens = DarkTokens.copy(
    surfaceBase = Color(0xFF000000),
    surfaceRaised = Color(0xFF0A0A0B),
    surfaceOverlay = Color(0xFF111113),
    surfaceInset = Color(0xFF050506),
    hairline = Color(0xFF242427),
    hairlineStrong = Color(0xFF414147),
    accentMuted = Color(0xFF171719),
    scenicCenter = Color(0xFF0A0A0B),
    scenicEdge = Color(0xFF000000),
    cardFillTop = Color(0xFF111113),
    cardFillBottom = Color(0xFF050506),
)

val LightTokens = PaletteTokens(
    surfaceBase = Color(0xFFF4F5F7), surfaceRaised = Color(0xFFFFFFFF), surfaceOverlay = Color(0xFFFAFBFC),
    surfaceInset = Color(0xFFECEFF2), hairline = Color(0xFFDEE2E7), hairlineStrong = Color(0xFFC5CBD3),
    textPrimary = Color(0xFF111317), textSecondary = Color(0xFF4A4E54), textTertiary = Color(0xFF686D75),
    glowAmbient = Color(0xFFE8E8E4),
    accent = Color(0xFF111111), accentHover = Color(0xFF2C2C2A), accentMuted = Color(0xFFE1E4E8), focusRing = Color(0xFF333330),
    accentInk = Color(0xFFFFFFFF),
    recovery000 = Color(0xFFC0392B), recovery030 = Color(0xFFD9682A), recovery055 = Color(0xFFC99A00),
    recovery078 = Color(0xFF6FB23A), recovery100 = Color(0xFF0F9D62),
    strain000 = Color(0xFF7E460E), strain033 = Color(0xFFA4621B), strain066 = Color(0xFFC2792E), strain100 = Color(0xFFD89240),
    sleepAwake = Color(0xFF8E949E), sleepLight = Color(0xFF7B78E0), sleepDeep = Color(0xFFC13EC1), sleepREM = Color(0xFF8E3BD6),
    zone1 = Color(0xFF3A80D6), zone2 = Color(0xFF2E92B4), zone3 = Color(0xFFC28E26), zone4 = Color(0xFFC2792E), zone5 = Color(0xFFC84E1E),
    statusPositive = Color(0xFF1F8A5B), statusWarning = Color(0xFFC2792E), statusCritical = Color(0xFFC84E1E),
    statusPositiveText = Color(0xFF19734A), statusWarningText = Color(0xFF895900), statusCriticalText = Color(0xFFA83D21),
    metricCyan = Color(0xFF2E92B4), metricPurple = Color(0xFF3A80D6), metricAmber = Color(0xFFC2792E), metricRose = Color(0xFFC84E1E),
    chargeColor = Color(0xFF0F9D62), chargeDeep = Color(0xFF0B7A4A), chargeBright = Color(0xFF5FD89A), chargeGlow = Color(0xFF0F9D62),
    effortColor = Color(0xFF2A78C8), effortDeep = Color(0xFF1E5B96), effortBright = Color(0xFF5AA0E0), effortGlow = Color(0xFF2A78C8),
    restColor = Color(0xFF5E7896), restDeep = Color(0xFF234F9E), restBright = Color(0xFF5790DA), restGlow = Color(0xFF3A80D6),
    stressColor = Color(0xFFC7891A), stressDeep = Color(0xFF3A80D6), stressBright = Color(0xFFC84E1E), stressGlow = Color(0xFFC7891A),
    scenicCenter = Color(0xFFF5F7F9), scenicEdge = Color(0xFFE4E8ED), scenicStar = Color(0xFFBAC3CF),
    cardFillTop = Color(0xFFFFFFFF), cardFillBottom = Color(0xFFF2F5F8),
    gold = Color(0xFF3A78C8), goldLight = Color(0xFF6FA8E0), goldDeep = Color(0xFF2A5C9E),
    goldDeepText = Color(0xFFFFFFFF), signalYellow = Color(0xFFE8A800),
    titaniumTop = Color(0xFFDDE1E6), titaniumMid = Color(0xFFBBC2C9), titaniumLow = Color(0xFF98A0A8), titaniumDeep = Color(0xFF6B737B),
    tipCore = Color(0xFF241B06),
)

// MARK: - Chart style (data-viz colour mode) + the Classic throwback ramps

enum class ChartStyle(val storageValue: String, val label: String) {
    TITANIUM("titanium", "Titanium"),
    CLASSIC("classic", "Classic");

    companion object {
        fun fromStorage(raw: String?): ChartStyle = entries.firstOrNull { it.storageValue == raw } ?: TITANIUM
    }
}

/** Chart-colour preference, persisted in `noop_prefs` and mirrored in snapshot state so a flip
 *  re-colours every gauge/chart live (the Palette ramp accessors read [ChartStylePrefs.style]). */
object ChartStylePrefs {
    private const val FILE = "noop_prefs"
    private const val KEY = "chart.style"
    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    var style by mutableStateOf(ChartStyle.TITANIUM)
        private set

    fun load(ctx: Context) {
        style = ChartStyle.fromStorage(prefs(ctx).getString(KEY, ChartStyle.TITANIUM.storageValue))
    }

    fun set(ctx: Context, value: ChartStyle) {
        style = value
        prefs(ctx).edit().putString(KEY, value.storageValue).apply()
    }
}

/** The Classic (throwback) data ramps — light/dark tuned. Picked by the Palette accessors when
 *  ChartStylePrefs.style == CLASSIC. Surfaces/text/accent are never classic — only data encodings. */
data class ClassicRamp(
    val recovery: List<Pair<Float, Color>>,
    val strain: List<Pair<Float, Color>>,
    val stress: List<Pair<Float, Color>>,
    val sleepAwake: Color, val sleepLight: Color, val sleepDeep: Color, val sleepREM: Color,
    val zone1: Color, val zone2: Color, val zone3: Color, val zone4: Color, val zone5: Color,
    val statusPositive: Color, val statusWarning: Color, val statusCritical: Color,
    val statusPositiveText: Color, val statusWarningText: Color, val statusCriticalText: Color,
    val metricCyan: Color, val metricPurple: Color, val metricAmber: Color, val metricRose: Color,
    val chargeColor: Color, val chargeDeep: Color, val chargeBright: Color,
    val effortColor: Color, val effortDeep: Color, val effortBright: Color,
    val restColor: Color, val restDeep: Color, val restBright: Color,
    val stressColor: Color, val stressDeep: Color, val stressBright: Color,
)

val ClassicDark = ClassicRamp(
    recovery = listOf(0.0f to Color(0xFFE5483B), 0.30f to Color(0xFFEE8B3C), 0.55f to Color(0xFFF2C53D), 0.78f to Color(0xFFA6D04E), 1.0f to Color(0xFF46B45A)),
    strain = listOf(0.0f to Color(0xFF7FB2E8), 0.33f to Color(0xFF4A90E2), 0.66f to Color(0xFF2F6FCB), 1.0f to Color(0xFF1E4FA0)),
    stress = listOf(0.0f to Color(0xFF46B45A), 0.5f to Color(0xFFF2C53D), 1.0f to Color(0xFFE5483B)),
    sleepAwake = Color(0xFFC9CCD6), sleepLight = Color(0xFF6FA8E8), sleepDeep = Color(0xFF2A4C8F), sleepREM = Color(0xFF8E6FD6),
    zone1 = Color(0xFF9AA7B5), zone2 = Color(0xFF46B45A), zone3 = Color(0xFFF2C53D), zone4 = Color(0xFFEE8B3C), zone5 = Color(0xFFE5483B),
    statusPositive = Color(0xFF46B45A), statusWarning = Color(0xFFF2C53D), statusCritical = Color(0xFFE5483B),
    statusPositiveText = Color(0xFF46B45A), statusWarningText = Color(0xFFF2C53D), statusCriticalText = Color(0xFFE5483B),
    metricCyan = Color(0xFF3FA9C9), metricPurple = Color(0xFF8E6FD6), metricAmber = Color(0xFFF2C53D), metricRose = Color(0xFFE5483B),
    chargeColor = Color(0xFF46B45A), chargeDeep = Color(0xFF2E9E4F), chargeBright = Color(0xFF86D98E),
    effortColor = Color(0xFF4A90E2), effortDeep = Color(0xFF2F6FCB), effortBright = Color(0xFF7FB2E8),
    restColor = Color(0xFF6FA8E8), restDeep = Color(0xFF2A4C8F), restBright = Color(0xFF8E6FD6),
    stressColor = Color(0xFFF2C53D), stressDeep = Color(0xFF46B45A), stressBright = Color(0xFFE5483B),
)

val ClassicLight = ClassicRamp(
    recovery = listOf(0.0f to Color(0xFFCB3A2F), 0.30f to Color(0xFFD87328), 0.55f to Color(0xFFCFA528), 0.78f to Color(0xFF74A53A), 1.0f to Color(0xFF2E9E4F)),
    strain = listOf(0.0f to Color(0xFF5E92D6), 0.33f to Color(0xFF3A74C4), 0.66f to Color(0xFF284F9C), 1.0f to Color(0xFF1C3E80)),
    stress = listOf(0.0f to Color(0xFF2E9E4F), 0.5f to Color(0xFFCFA528), 1.0f to Color(0xFFCB3A2F)),
    sleepAwake = Color(0xFF8C95A3), sleepLight = Color(0xFF3A80D6), sleepDeep = Color(0xFF203E73), sleepREM = Color(0xFF6A4FC0),
    zone1 = Color(0xFF828D9B), zone2 = Color(0xFF2E9E4F), zone3 = Color(0xFFCFA528), zone4 = Color(0xFFD87328), zone5 = Color(0xFFCB3A2F),
    statusPositive = Color(0xFF2E9E4F), statusWarning = Color(0xFFCFA528), statusCritical = Color(0xFFCB3A2F),
    statusPositiveText = Color(0xFF19734A), statusWarningText = Color(0xFF895900), statusCriticalText = Color(0xFFB33A2F),
    metricCyan = Color(0xFF2E92B4), metricPurple = Color(0xFF6A4FC0), metricAmber = Color(0xFFCFA528), metricRose = Color(0xFFCB3A2F),
    chargeColor = Color(0xFF2E9E4F), chargeDeep = Color(0xFF207A3C), chargeBright = Color(0xFF5FBE6E),
    effortColor = Color(0xFF3A74C4), effortDeep = Color(0xFF284F9C), effortBright = Color(0xFF5E92D6),
    restColor = Color(0xFF3A80D6), restDeep = Color(0xFF203E73), restBright = Color(0xFF6A4FC0),
    stressColor = Color(0xFFCFA528), stressDeep = Color(0xFF2E9E4F), stressBright = Color(0xFFCB3A2F),
)

// MARK: - Appearance preference (System / Light / Dark / OLED Black)

enum class AppearanceMode(
    val storageValue: String,
    @StringRes val labelRes: Int,
    @StringRes val detailRes: Int,
) {
    SYSTEM("system", R.string.appearance_system, R.string.appearance_detail_system),
    LIGHT("light", R.string.appearance_light, R.string.appearance_detail_light),
    DARK("dark", R.string.appearance_dark, R.string.appearance_detail_dark),
    BLACK("black", R.string.appearance_black, R.string.appearance_detail_black);

    companion object {
        fun fromStorage(raw: String?): AppearanceMode =
            entries.firstOrNull { it.storageValue == raw } ?: BLACK
    }
}

/** Theme preference, persisted in `noop_prefs` and mirrored in snapshot state so the toggle is live.
 *  [load] is called once from MainActivity before first composition (no flash); [set] writes + flips. */
object AppearancePrefs {
    private const val FILE = "noop_prefs"
    private const val KEY = "theme.appearance"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Live appearance mode read by NoopTheme; new installs match Apple's OLED Black default. */
    var mode by mutableStateOf(AppearanceMode.BLACK)
        private set

    internal fun persistedMode(ctx: Context): AppearanceMode =
        AppearanceMode.fromStorage(prefs(ctx).getString(KEY, AppearanceMode.BLACK.storageValue))

    fun load(ctx: Context) {
        mode = persistedMode(ctx)
    }

    fun set(ctx: Context, value: AppearanceMode) {
        mode = value
        prefs(ctx).edit().putString(KEY, value.storageValue).apply()
        // Widgets have no periodic update interval. Recompose them now so the selected finish lands
        // immediately instead of waiting for the next sensor snapshot.
        WidgetSnapshotStore.requestRefresh(ctx)
    }
}

/** System follows the device and therefore does not falsely double-select one explicit preview. */
internal fun isAppearancePreviewSelected(selection: AppearanceMode, preview: AppearanceMode): Boolean =
    selection != AppearanceMode.SYSTEM && selection == preview

/** A preview must render the candidate finish, never the currently-active app finish. */
internal fun themeSwatchAccent(tokens: PaletteTokens): Color = tokens.accent
