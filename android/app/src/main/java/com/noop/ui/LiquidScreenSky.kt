package com.noop.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// MARK: - LiquidScreenSky — the reusable primary-screen backdrop
//
// Android equivalent of iOS `LiquidScaffoldSky`: one shared satin-obsidian canvas behind Today, Trends,
// Workouts, Sleep, More, Journal, and the rest of the primary screen scaffolds. Keeping this compatibility
// entry point means every existing caller receives the visual update together.
//
// HOW IT PLUGS IN: pass this as the scaffold's `topBackground` slot:
//
//   LazyScreenScaffold(
//       ...
//       topBackground = if (showDayCycleBackground) { { LiquidScreenSky() } } else null,
//   ) { ... }
//
// The existing ScreenScaffold / LazyScreenScaffold `topBackground` machinery (Components.kt) already does
// the screen-level plumbing this backdrop needs — it anchors the slot to the TOP, bleeds it full-width UP
// behind the status bar (offset by the status-bar inset), and promotes it to its OWN compositing layer (an
// empty `graphicsLayer {}`) so a static backdrop rasterises ONCE and replays as a texture on every scroll
// frame. So this composable only has to paint the two layers, top-aligned, at a header height.
//
// The bundled image is static by design. It provides dimensional material without spending frame budget
// behind long chart-heavy lists, and it matches the current iOS product background rather than the retired
// purple/blue time-of-day gradient.
//
// WHY the surfaceBase fill under it: the sky band is only [height] tall; the canvas fill guarantees the
// region ABOVE the fold and any sub-pixel gap reads as the theme canvas, exactly like the iOS backdrop's
// `ZStack { surfaceBase; sky }`.
//
// Non-interactive + accessibility-hidden — it is pure decoration (the scaffold slot never receives taps).

/** Reusable primary-screen backdrop. [height] is the compact header band; [fillHeight] keeps the
 * material behind the full scroll viewport so translucent cards reveal it. */
@Composable
fun LiquidScreenSky(height: Dp = 240.dp, fillHeight: Boolean = false) {
    val sizeMod = if (fillHeight) Modifier.fillMaxSize() else Modifier.fillMaxWidth().height(height)
    ObsidianFlowBackground(
        compact = !fillHeight,
        intensity = if (fillHeight) 0.90f else 0.84f,
        modifier = sizeMod.clearAndSetSemantics {},
    )
}
