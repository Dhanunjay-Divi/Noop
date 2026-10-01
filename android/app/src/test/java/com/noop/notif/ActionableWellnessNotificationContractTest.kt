package com.noop.notif

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ActionableWellnessNotificationContractTest {
    @Test
    fun remindersCarryConcretePrivateActionsWithoutSilentLogging() {
        val root = sourceRoot()
        val hydration = File(root, "notif/HydrationReminders.kt").readText()
        val stress = File(root, "notif/StressBreathingNotifier.kt").readText()
        val inactivity = File(root, "notif/InactivityNotifier.kt").readText()

        assertTrue(
            hydration.contains(
                "NotificationRoutePresentation.LOG_HYDRATION",
            ),
        )
        assertTrue(
            hydration.contains(
                "R.string.appwide_wellness_action_log_water",
            ),
        )
        assertTrue(
            stress.contains(
                "NotificationRoutePresentation.START_BREATHING",
            ),
        )
        assertTrue(
            stress.contains(
                "R.string.appwide_wellness_action_start_breathing",
            ),
        )
        assertTrue(
            inactivity.contains(
                "NotificationRoutePresentation.MOVEMENT_BREAK",
            ),
        )
        assertTrue(
            inactivity.contains(
                "R.string.appwide_wellness_action_move_now",
            ),
        )
        assertTrue(inactivity.contains(".protectPrivateContent("))
        assertFalse(hydration.contains("HydrationStore.log("))
        assertFalse(inactivity.contains("saveWorkout"))
    }

    @Test
    fun notificationRoutesStartPurposeBuiltUiAndAreConsumedOnce() {
        val root = sourceRoot()
        val appRoot = File(root, "ui/AppRoot.kt").readText()
        val breathe = File(root, "ui/BreatheScreen.kt").readText()
        val movement = File(root, "ui/MovementBreakSheet.kt").readText()

        val movementBranch = appRoot.substring(
            appRoot.indexOf(
                "NotificationRoutePresentation.MOVEMENT_BREAK",
            ),
            appRoot.indexOf(
                "Box(modifier = Modifier.fillMaxSize())",
            ),
        )
        assertTrue(movementBranch.contains("showMovementBreak = true"))
        assertFalse(
            movementBranch.contains(
                "openTopLevel(Destination.Intervals.route)",
            ),
        )
        assertTrue(appRoot.contains("MovementBreakSheet("))
        assertTrue(
            appRoot.contains(
                "breathingNotificationStartRequest = 0L",
            ),
        )
        assertTrue(
            breathe.contains(
                "ActionableWellnessPolicy.shouldCompleteBreathingSession",
            ),
        )
        assertTrue(breathe.contains("onNotificationStartConsumed()"))
        assertTrue(
            movement.contains(
                "ActionableWellnessPolicy.movementRemainingSeconds",
            ),
        )
        assertTrue(
            movement.contains(
                "rememberSaveable(startedAtElapsedRealtimeMs)",
            ),
        )
        assertFalse(movement.contains("DisposableEffect(Unit)"))
        assertFalse(movement.contains("HydrationStore"))
        assertFalse(movement.contains("saveWorkout"))
    }

    @Test
    fun notificationActionsEnterThroughANonExportedActivity() {
        val root = sourceRoot()
        val bridge = File(root, "ui/NotificationRouteBridge.kt").readText()
        val main = File(root, "ui/MainActivity.kt").readText()
        val privateActivity =
            File(root, "ui/NotificationRouteActivity.kt").readText()
        val manifest = locateManifest().readText()

        assertTrue(
            bridge.contains(
                "Intent(context, NotificationRouteActivity::class.java)",
            ),
        )
        assertFalse(main.contains("recordFromTrustedIntent("))
        assertTrue(privateActivity.contains("recordFromTrustedIntent("))
        val activityEntry = manifest.substring(
            manifest.indexOf("com.noop.ui.NotificationRouteActivity"),
            manifest.indexOf(
                "/>",
                manifest.indexOf("com.noop.ui.NotificationRouteActivity"),
            ),
        )
        assertTrue(activityEntry.contains("android:exported=\"false\""))
    }

    @Test
    fun actionableCopyExistsInEverySupportedLocale() {
        val root = resourceRoot()
        val locales = listOf(
            "values",
            "values-de",
            "values-es",
            "values-fr",
            "values-it",
            "values-pt-rPT",
            "values-ru",
            "values-zh",
            "values-zh-rTW",
        )
        val required = listOf(
            "appwide_wellness_action_log_water",
            "appwide_wellness_action_move_now",
            "appwide_wellness_action_start_breathing",
            "appwide_wellness_inactivity_body",
            "appwide_wellness_inactivity_body_minutes",
            "appwide_wellness_inactivity_channel_description",
            "appwide_wellness_inactivity_channel_name",
            "appwide_wellness_inactivity_title",
            "appwide_wellness_movement_body",
            "appwide_wellness_movement_complete",
            "appwide_wellness_movement_remaining_accessibility",
            "appwide_wellness_movement_title",
        )
        locales.forEach { locale ->
            val text = File(root, "$locale/appwide.xml").readText()
            required.forEach { name ->
                assertTrue(
                    "$locale missing $name",
                    text.contains("name=\"$name\""),
                )
            }
        }
    }

    private fun sourceRoot(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/java/com/noop"),
            File(root, "app/src/main/java/com/noop"),
            File(root, "android/app/src/main/java/com/noop"),
        ).firstOrNull(File::isDirectory)
            ?: error("Could not locate Android NOOP source root from $root")
    }

    private fun resourceRoot(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/res"),
            File(root, "app/src/main/res"),
            File(root, "android/app/src/main/res"),
        ).firstOrNull(File::isDirectory)
            ?: error("Could not locate Android resource root from $root")
    }

    private fun locateManifest(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/AndroidManifest.xml"),
            File(root, "app/src/main/AndroidManifest.xml"),
            File(root, "android/app/src/main/AndroidManifest.xml"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate Android manifest from $root")
    }
}
