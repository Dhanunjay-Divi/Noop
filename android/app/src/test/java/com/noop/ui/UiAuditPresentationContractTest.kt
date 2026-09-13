package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
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

    private fun stringResource(folder: String, name: String): String {
        val xml = source("src/main/res/$folder/strings.xml")
        val match = Regex(
            """<string\s+name="${Regex.escape(name)}"[^>]*>(.*?)</string>""",
            RegexOption.DOT_MATCHES_ALL,
        ).find(xml)
        requireNotNull(match) { "Missing $name in $folder/strings.xml" }
        return match.groupValues[1].trim()
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
    fun auditedPrimaryBandInstructionsUseCurrentVocabulary() {
        val testCentre = source("src/main/java/com/noop/ui/TestCentreScreen.kt")
        assertFalse(testCentre.contains("wear the strap, then tap Report"))
        assertFalse(testCentre.contains("Your strap log"))
        assertTrue(testCentre.contains("appwide_ui_audit_test_centre_subtitle_phone"))
        assertTrue(testCentre.contains("appwide_ui_audit_test_centre_mode_blurb"))
        assertTrue(testCentre.contains("appwide_ui_audit_test_centre_diagnostic_blurb"))
        assertTrue(testCentre.contains("appwide_ui_audit_test_centre_ppg_description"))
        assertTrue(testCentre.contains("LogExport.shareStrapLog("))
        val reportWarningCall = testCentre
            .substringAfter(
                "uiString(R.string.l10n_test_centre_screen_heads_up_this_test_mode_is_8b82ed69)",
            )
            .substringBefore("style = NoopType.footnote")
        assertFalse(reportWarningCall.contains("+"))

        val settings = source("src/main/java/com/noop/ui/SettingsScreen.kt")
        assertFalse(settings.contains("Works on any strap"))
        assertFalse(settings.contains("Your strap log"))
        assertTrue(settings.contains("appwide_ui_audit_settings_diagnostics_read_only"))
        assertTrue(settings.contains("appwide_ui_audit_settings_test_centre"))

        val health = source("src/main/java/com/noop/ui/HealthScreen.kt")
        assertFalse(health.contains("if the strap or import"))
        assertTrue(health.contains("appwide_ui_audit_vitals_history_subtitle"))
        assertTrue(health.contains("appwide_ui_audit_vitals_missing_body"))

        val onboarding = source("src/main/java/com/noop/ui/OnboardingScreen.kt")
        assertFalse(onboarding.contains("If the strap is nearby"))
        assertTrue(onboarding.contains("appwide_ui_audit_onboarding_background_pairing"))

        val scoring = source("src/main/java/com/noop/ui/ScoringGuideScreen.kt")
        assertFalse(scoring.contains("your strap's raw signals"))
        assertTrue(scoring.contains("appwide_ui_audit_scoring_guide_overline"))
        assertTrue(scoring.contains("appwide_ui_audit_scoring_guide_intro"))

        val devices = source("src/main/java/com/noop/ui/DevicesScreen.kt")
        assertFalse(devices.contains("watch BOTH the strap log and the strap itself"))
        val rebootProbeCall = devices
            .substringAfter(
                "uiString(R.string.l10n_devices_screen_the_whoop_4_0_reboot_frame_690a8ff2)",
            )
            .substringBefore("style = NoopType.subhead")
        assertFalse(rebootProbeCall.contains("+"))
        assertTrue(devices.contains("""displayModel = "Heart-rate strap""""))
        assertTrue(devices.contains("Other heart-rate straps can stream live heart"))

        val logExport = source("src/main/java/com/noop/ui/LogExport.kt")
        assertFalse(logExport.contains("connect to your strap"))
        assertFalse(logExport.contains("Sharing the strap log"))
        assertTrue(logExport.contains("appwide_ui_audit_log_export_empty_scheduled"))
        assertTrue(logExport.contains("appwide_ui_audit_log_export_empty_interactive"))
        assertTrue(logExport.contains("appwide_ui_audit_log_export_raw_capture_privacy"))
        assertTrue(logExport.contains("appwide_ui_audit_log_export_raw_capture_unsupported"))
        assertTrue(logExport.contains("appwide_ui_audit_log_export_raw_capture_enable"))
        assertTrue(logExport.contains("appwide_ui_audit_log_export_raw_capture_wait"))
        assertTrue(logExport.contains("appwide_ui_audit_log_export_sharing_band_log"))
        assertFalse(logExport.lowercase().contains("safe to leave on"))
    }

    @Test
    fun auditedCompleteMessagesAreNativeFullSentencesInEverySupportedLocale() {
        val folders = listOf(
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
        val rebootKey = "l10n_devices_screen_the_whoop_4_0_reboot_frame_690a8ff2"
        val reportKey = "l10n_test_centre_screen_heads_up_this_test_mode_is_8b82ed69"
        val rebootEndings = mapOf(
            "values" to "correct frame.",
            "values-de" to "bestimmen können.",
            "values-es" to "instrucción correcta.",
            "values-fr" to "bonne commande.",
            "values-it" to "comando corretto.",
            "values-pt-rPT" to "comando correto.",
            "values-ru" to "правильную команду.",
            "values-zh" to "正确的指令。",
            "values-zh-rTW" to "正確的指令。",
        )
        val reportEndings = mapOf(
            "values" to "report again.",
            "values-de" to "neuen Bericht.",
            "values-es" to "el informe.",
            "values-fr" to "nouveau rapport.",
            "values-it" to "nuovo report.",
            "values-pt-rPT" to "o relatório.",
            "values-ru" to "ещё раз.",
            "values-zh" to "生成报告。",
            "values-zh-rTW" to "產生報告。",
        )

        folders.forEach { folder ->
            val reboot = stringResource(folder, rebootKey)
            val report = stringResource(folder, reportKey)
            assertTrue("$folder reboot guidance must retain its diagnostic issue", reboot.contains("#235"))
            assertTrue("$folder reboot guidance must retain its timeout check", reboot.contains("12"))
            assertTrue(
                "$folder reboot guidance is not complete: $reboot",
                reboot.endsWith(rebootEndings.getValue(folder)),
            )
            assertTrue(
                "$folder report guidance is not complete: $report",
                report.endsWith(reportEndings.getValue(folder)),
            )
            assertTrue("$folder report guidance must name Noop Band", report.contains("Noop Band"))

            if (folder != "values") {
                assertFalse("$folder retained the English reboot suffix", reboot.contains("Send each candidate"))
                assertFalse("$folder retained the English report prefix", report.contains("Heads up"))
                assertFalse("$folder retained the English report suffix", report.contains("useful report"))
            }
        }
    }

    @Test
    fun mountedPrimaryBandResourcesRejectStaleStrapCopy() {
        val folders = listOf(
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
        val shareKeys = listOf(
            "l10n_test_centre_screen_share_strap_log_for_bug_reports_b9802500",
            "l10n_settings_screen_share_strap_log_for_bug_reports_b9802500",
        )
        val waitingKey = "l10n_devices_screen_waiting_for_the_straps_reply_5a06e7ac"
        val hrvKey = "l10n_hrv_snapshot_screen_an_hrv_reading_needs_the_live_11b70bff"
        val hrrKey = "l10n_workouts_screen_hrr_explanation_516"
        val wearableTerms = mapOf(
            "values" to "wearable",
            "values-de" to "Wearable",
            "values-es" to "dispositivo wearable",
            "values-fr" to "appareil portable",
            "values-it" to "dispositivo indossabile",
            "values-pt-rPT" to "dispositivo wearable",
            "values-ru" to "носимое устройство",
            "values-zh" to "穿戴设备",
            "values-zh-rTW" to "穿戴式裝置",
        )
        val staleTerms = Regex(
            """\bstrap\b|Gurt|correa|sangle|cinturino|ремешок|錶帶""",
            RegexOption.IGNORE_CASE,
        )

        folders.forEach { folder ->
            val waiting = stringResource(folder, waitingKey)
            val hrv = stringResource(folder, hrvKey)
            val hrr = stringResource(folder, hrrKey)

            shareKeys.forEach { shareKey ->
                val share = stringResource(folder, shareKey)
                assertFalse(
                    "$folder $shareKey uses stale mounted terminology",
                    staleTerms.containsMatchIn(share),
                )
            }
            assertFalse("$folder waiting copy uses stale mounted terminology", staleTerms.containsMatchIn(waiting))
            assertFalse("$folder HRV instruction uses stale mounted terminology", staleTerms.containsMatchIn(hrv))
            assertTrue("$folder waiting copy must name Noop Band", waiting.contains("Noop Band"))
            assertTrue("$folder HRV instruction must name Noop Band", hrv.contains("Noop Band"))
            assertTrue(
                "$folder HRR explanation must be source-neutral",
                hrr.contains(wearableTerms.getValue(folder)),
            )
        }

        shareKeys.forEach { shareKey ->
            assertEquals(
                "Share band log (for bug reports)",
                stringResource("values", shareKey),
            )
        }
        assertEquals(
            "Waiting for Noop Band to reply…",
            stringResource("values", waitingKey),
        )
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
