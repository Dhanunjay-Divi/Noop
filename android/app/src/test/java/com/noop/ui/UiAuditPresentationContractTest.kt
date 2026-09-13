package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Prevents regressions in the core surfaces covered by the cross-platform UI audit. */
class UiAuditPresentationContractTest {
    private fun root(): File = File(System.getProperty("user.dir") ?: ".")

    private fun source(relativePath: String): String {
        val candidates = listOf(
            File(root(), relativePath),
            File(root(), "app/$relativePath"),
            File(root(), "android/app/$relativePath"),
        )
        val file = candidates.firstOrNull(File::isFile)
        requireNotNull(file) { "Missing audited source: $relativePath" }
        return file.readText()
    }

    @Test
    fun auditedCoreSurfacesUseSharedMissingValueToken() {
        val auditedPaths = listOf(
            "src/main/java/com/noop/ui/FriendsScreen.kt",
            "src/main/java/com/noop/ui/HealthScreen.kt",
            "src/main/java/com/noop/ui/LiveScreen.kt",
            "src/main/java/com/noop/ui/ManagedFriendsScreen.kt",
            "src/main/java/com/noop/ui/SleepFormatting.kt",
            "src/main/java/com/noop/ui/SleepModelLogic.kt",
            "src/main/java/com/noop/ui/SleepScreen.kt",
            "src/main/java/com/noop/ui/StressScreen.kt",
            "src/main/java/com/noop/ui/TodayScreen.kt",
            "src/main/java/com/noop/ui/TrendsScreen.kt",
            "src/main/java/com/noop/ui/WeeklyDigestCard.kt",
        )
        val forbidden = listOf(
            "?: \"-\"",
            "?: \"–\"",
            "return \"-\"",
            "return \"–\"",
            "== \"-\"",
            "== \"–\"",
            "SLEEP_MISSING_VALUE",
            "vs typical -",
        )

        auditedPaths.forEach { path ->
            val content = source(path)
            forbidden.forEach { fragment ->
                assertFalse(
                    "$path reintroduced a raw missing-value token: $fragment",
                    content.contains(fragment),
                )
            }
        }

        assertTrue(source("src/main/java/com/noop/ui/TodayScreen.kt").contains("NoopDisplayFormat.MISSING"))
        assertTrue(source("src/main/java/com/noop/ui/SleepScreen.kt").contains("NoopDisplayFormat.MISSING"))
        assertTrue(source("src/main/java/com/noop/ui/SleepFormatting.kt").contains("NoopDisplayFormat.MISSING"))
        assertTrue(source("src/main/java/com/noop/ui/SleepModelLogic.kt").contains("NoopDisplayFormat.MISSING"))
        assertTrue(
            source("src/main/java/com/noop/ui/LiveScreen.kt")
                .contains("live.lastSyncAt?.let { relativeAgo(it) } ?: NoopDisplayFormat.MISSING"),
        )
    }

    @Test
    fun recoveryAndDailySignalUseSeparateCentralizedPresentationContracts() {
        val today = source("src/main/java/com/noop/ui/TodayScreen.kt")
        val calendar = source("src/main/java/com/noop/ui/CalendarMonthScreen.kt")
        val digest = source("src/main/java/com/noop/ui/WeeklyDigestCard.kt")

        assertTrue(today.contains("return recoveryBandLabel(score)"))
        assertTrue(calendar.contains("RecoveryBandPresentation.color(value)"))
        assertTrue(digest.contains("RecoveryBandPresentation.color(value)"))
        assertTrue(digest.contains("WeeklyDigestChipTone.RECOVERY_BAND"))
        assertTrue(today.contains("dailySignalStatusLabelRes(status)"))
        assertFalse(today.contains("DailySignalStatus.WATCH -> uiString("))
    }

    @Test
    fun androidNavigationRetainsScaledLabelsAndTalkBackSelection() {
        val root = source("src/main/java/com/noop/ui/AppRoot.kt")
        val barSlot = root
            .substringAfter("private fun BarSlot(")
            .substringBefore("\n}\n\nprivate enum class QuickActionKind")

        assertTrue(root.contains("rememberBottomBarLabelLayout("))
        assertTrue(barSlot.contains("contentDescription = label"))
        assertTrue(barSlot.contains("selected = active"))
        assertTrue(barSlot.contains("maxLines = labelMaxLines"))
        assertTrue(barSlot.contains("overflow = TextOverflow.Ellipsis"))
        assertFalse(barSlot.contains("overflow = TextOverflow.Clip"))
    }

    @Test
    fun auditedSocialAndBandCopyUsesCurrentVocabulary() {
        val strings = source("src/main/res/values/strings.xml")
        val appWide = source("src/main/res/values/appwide.xml")
        val appViewModel = source("src/main/java/com/noop/ui/AppViewModel.kt")

        assertFalse(strings.contains("Sync your strap"))
        assertFalse(strings.contains("your strap hands over its stored history"))
        assertFalse(strings.contains("strap battery"))
        assertTrue(
            strings.contains(
                """<string name="managed_friends_rest">Sleep Score</string>""",
            ),
        )
        assertFalse(appWide.contains("Only Recovery, Effort, Rest"))
        assertTrue(
            appWide.contains(
                "Only Recovery, Effort, Sleep Score, sleep duration",
            ),
        )
        assertFalse(appViewModel.contains("after your strap synced"))
        assertTrue(appViewModel.contains("after your band synced"))
    }

    @Test
    fun liveCoachUsesOnlyCurrentDayRecoveryCopy() {
        val today = source("src/main/java/com/noop/ui/TodayScreen.kt")
        val liveSessionCall = today.substringAfter(
            "TodaySection.LIVE_SESSION -> LiveSessionEntryCard(",
        ).substringBefore("TodaySection.WHY")

        assertFalse(liveSessionCall.contains("lastScoredCharge"))
        assertTrue(liveSessionCall.contains("hasCurrentRecovery = displayMetric?.recovery != null"))
        assertTrue(today.contains("appwide_live_session_start_detail_unavailable"))
    }

    @Test
    fun auditedP2PresentationFixesRemainMounted() {
        val devices = source("src/main/java/com/noop/ui/DevicesScreen.kt")
        assertTrue(devices.contains("shouldShowDeviceModel(customerName, profile.displayModel)"))
        assertTrue(devices.contains("if (profile.footnote.isNotEmpty())"))

        val settings = source("src/main/java/com/noop/ui/SettingsScreen.kt")
        val ageRow = settings.substringAfter(
            "FormRow(label = uiString(R.string.l10n_settings_screen_age_ff9f1ff3))",
        ).substringBefore("RowDivider()")
        assertTrue(ageRow.contains("value = profile.age.toString()"))
        assertTrue(ageRow.contains("""accessibility = "Age, ${'$'}{profile.age} years""""))

        val stress = source("src/main/java/com/noop/ui/StressScreen.kt")
        assertTrue(stress.contains("appwide_stress_band_light_load"))
        assertTrue(stress.contains("appwide_common_vs_baseline"))
        assertTrue(stress.contains("""caption = "of 3 · ${'$'}{model.band.title}""""))

        val today = source("src/main/java/com/noop/ui/TodayScreen.kt")
        assertTrue(today.contains("appwide_charge_confidence_reliable"))
        assertTrue(today.contains("appwide_charge_confidence_estimate"))
        assertTrue(today.contains("appwide_charge_confidence_calibrating"))
        assertTrue(today.contains("chargeDriverPointLabel(driver.deltaPoints)"))

        assertTrue(
            source("src/main/java/com/noop/ui/JournalLog.kt")
                .contains("contentPadding = PaddingValues(horizontal = Metrics.space16)"),
        )
        val health = source("src/main/java/com/noop/ui/HealthScreen.kt")
        assertTrue(health.contains("appwide_health_live_hr_disconnected"))
        assertTrue(health.contains("NoopDisplayFormat.MISSING"))
        val sleep = source("src/main/java/com/noop/ui/SleepScreen.kt")
        assertTrue(sleep.contains("""SectionHeader("Sleep Score", overline = overline)"""))
        assertTrue(sleep.contains("appwide_sleep_imported_confidence_note"))
        assertTrue(sleep.contains("tint = Palette.textTertiary"))
        assertTrue(
            source("src/main/java/com/noop/ui/ManagedCloudCard.kt")
                .contains("ManagedCloudEvidenceRow("),
        )
    }
}
