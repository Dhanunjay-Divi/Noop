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
        assertTrue(
            source("src/main/java/com/noop/ui/LiveScreen.kt")
                .contains("live.lastSyncAt?.let { relativeAgo(it) } ?: NoopDisplayFormat.MISSING"),
        )
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
        assertTrue(
            source("src/main/java/com/noop/ui/DevicesScreen.kt")
                .contains("if (profile.footnote.isNotEmpty())"),
        )
        assertTrue(
            source("src/main/java/com/noop/ui/SettingsScreen.kt")
                .contains("""accessibility = "Age, ${'$'}{profile.age} years""""),
        )
        val stress = source("src/main/java/com/noop/ui/StressScreen.kt")
        assertTrue(stress.contains("appwide_stress_band_light_load"))
        assertTrue(stress.contains("appwide_common_vs_baseline"))
        assertTrue(
            source("src/main/java/com/noop/ui/JournalLog.kt")
                .contains("contentPadding = PaddingValues(horizontal = Metrics.space16)"),
        )
        val health = source("src/main/java/com/noop/ui/HealthScreen.kt")
        assertTrue(health.contains("appwide_health_live_hr_disconnected"))
        assertTrue(health.contains("NoopDisplayFormat.MISSING"))
        val sleep = source("src/main/java/com/noop/ui/SleepScreen.kt")
        assertTrue(sleep.contains("appwide_sleep_imported_confidence_note"))
        assertTrue(
            source("src/main/java/com/noop/ui/ManagedCloudCard.kt")
                .contains("ManagedCloudEvidenceRow("),
        )
    }
}
