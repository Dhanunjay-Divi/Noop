package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Prevents regressions in the core surfaces covered by the cross-platform UI audit. */
class UiAuditPresentationContractTest {
    @Test
    fun healthBodyCompositionRequiresConfirmedWeightBeforePresentingBmi() {
        val health = source("src/main/java/com/noop/ui/HealthScreen.kt")
        val bmiGate = health
            .substringAfter("val currentBmi = if (")
            .substringBefore("val targetAvailability")

        assertTrue(bmiGate.contains("BodyProfilePolicy.canPresentAdultBmi("))
        assertTrue(
            bmiGate.contains(
                "currentWeightConfirmed = profile.weightInputConfirmed",
            ),
        )
    }

    @Test
    fun healthBodyCompositionRequiresConfirmedWeightBeforeTargetGuidance() {
        val health = source("src/main/java/com/noop/ui/HealthScreen.kt")
        val targetGate = health
            .substringAfter("val targetAvailability")
            .substringBefore("val latestDay")

        assertTrue(
            targetGate.contains(
                "currentWeightConfirmed = profile.weightInputConfirmed",
            ),
        )
        assertFalse(targetGate.contains("currentWeightConfirmed = true"))
    }

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

    private fun appWideResource(folder: String, name: String): String {
        val xml = source("src/main/res/$folder/appwide.xml")
        val match = Regex(
            """<string\s+name="${Regex.escape(name)}"[^>]*>(.*?)</string>""",
            RegexOption.DOT_MATCHES_ALL,
        ).find(xml)
        requireNotNull(match) { "Missing $name in $folder/appwide.xml" }
        return match.groupValues[1].trim()
    }

    private fun pluralQuantities(folder: String, name: String): Map<String, String> {
        val xml = source("src/main/res/$folder/appwide.xml")
        val block = Regex(
            """<plurals\s+name="${Regex.escape(name)}"[^>]*>(.*?)</plurals>""",
            RegexOption.DOT_MATCHES_ALL,
        ).find(xml)?.groupValues?.get(1)
        requireNotNull(block) { "Missing $name in $folder/appwide.xml" }
        return Regex(
            """<item\s+quantity="([^"]+)"[^>]*>(.*?)</item>""",
            RegexOption.DOT_MATCHES_ALL,
        ).findAll(block).associate { it.groupValues[1] to it.groupValues[2].trim() }
    }

    @Test
    fun auditedCoreSurfacesUseSharedMissingValueToken() {
        val auditedPaths = listOf(
            "src/main/java/com/noop/ui/CoupledScreen.kt",
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
            "else \"-\"",
            "else \"–\"",
            "text = \"-\"",
            "text = \"–\"",
            "return \"-\"",
            "return \"–\"",
            "== \"-\"",
            "== \"–\"",
            "SLEEP_MISSING_VALUE",
            "vs typical -",
            "private const val NO_DATA = \"No Data\"",
            "private const val COUPLED_NO_DATA = \"No Data\"",
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
        assertTrue(source("src/main/java/com/noop/ui/HealthScreen.kt").contains("NoopDisplayFormat.MISSING"))
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
        assertTrue(today.contains("recovery != null -> recoveryBandLabel(recovery)"))
        assertTrue(
            today.contains(
                "TodayRecoveryHeroTone.RECOVERY ->\n" +
                    "        RecoveryBandPresentation.gaugeColors(requireNotNull(recovery))",
            ),
        )
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
    fun lighterWorkoutOptionsRemainScrollableAndUseDismissSemantics() {
        val root = source("src/main/java/com/noop/ui/AppRoot.kt")
        val sheet = root
            .substringAfter("private fun LighterWorkoutOptionsSheet(")
            .substringBefore("\n@Composable\nprivate fun LighterWorkoutOptionRow")

        assertTrue(sheet.contains(".verticalScroll(rememberScrollState())"))
        assertTrue(sheet.contains(".navigationBarsPadding()"))
        assertTrue(sheet.contains("R.string.appwide_action_dismiss"))
        assertFalse(sheet.contains("R.string.context_action_collapse"))
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

        val mountedBandSources = listOf(
            "src/main/java/com/noop/ble/Backfiller.kt",
            "src/main/java/com/noop/ble/WhoopBleClient.kt",
            "src/main/java/com/noop/ble/WhoopConnectionService.kt",
        ).joinToString("\n") { source(it) }
        listOf(
            "Strap ${'$'}{",
            "Syncing strap history",
            "the strap went quiet",
            "your strap's clock",
            "charge the strap",
            "near your strap",
            "pair your strap",
            "your strap will reboot",
            "strap's realtime stream",
            "your strap had no stored history",
        ).forEach { phrase ->
            assertFalse(
                "Mounted primary-band copy still contains $phrase",
                mountedBandSources.contains(phrase),
            )
        }

        val primaryBandKeys = listOf(
            "l10n_data_sources_screen_write_the_metrics_noop_computes_from_439940c2",
            "l10n_settings_screen_feel_the_current_time_as_a_8ca41db1",
            "l10n_settings_screen_keeps_the_detailed_beat_to_beat_87b78edd",
        )
        listOf("values", "values-de", "values-es", "values-fr", "values-pt-rPT")
            .forEach { folder ->
                primaryBandKeys.forEach { key ->
                    assertTrue(
                        "$folder/$key must name Noop Band explicitly",
                        stringResource(folder, key).contains("Noop Band"),
                    )
                }
            }
    }

    @Test
    fun sleepHeroUsesLocalizedScoreHeading() {
        val sleep = source("src/main/java/com/noop/ui/SleepScreen.kt")
        val coupled = source("src/main/java/com/noop/ui/CoupledScreen.kt")

        assertTrue(
            sleep.contains(
                "uiString(R.string.appwide_day_overview_sleep_score)",
            ),
        )
        assertFalse(sleep.contains("SectionHeader(\"Sleep Score\""))
        assertTrue(
            coupled.contains(
                "uiString(R.string.appwide_day_overview_sleep_score)",
            ),
        )
        assertFalse(
            coupled.contains(
                "uiString(R.string.l10n_coupled_screen_sleep_performance_4611539f)",
            ),
        )
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
        assertTrue(testCentre.contains("OnSharedPreferenceChangeListener"))
        assertTrue(testCentre.contains("testCentre.registerListener(listener)"))
        assertTrue(testCentre.contains("key(testCentreRevision)"))
        assertTrue(testCentre.contains("active = testCentre.active(mode.domain)"))
        assertTrue(testCentre.contains("capturedUnits = testCentre.capturedDays(mode.domain)"))
        assertTrue(testCentre.contains("checked = active"))
        assertFalse(testCentre.contains("var on by remember"))
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
        assertFalse(onboarding.contains("NOOP keeps Noop Band connected in the background"))
        assertTrue(
            onboarding.contains(
                "appwide_onboarding_notifications_background_status_subtitle",
            ),
        )
        assertTrue(
            onboarding.contains(
                "appwide_onboarding_notifications_background_status_body",
            ),
        )
        assertTrue(onboarding.contains("appwide_onboarding_notifications_wrist_alerts"))
        assertTrue(onboarding.contains("appwide_onboarding_notifications_permission_help"))

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
        assertTrue(stress.contains("ui_audit_stress_score_caption"))
        assertTrue(stress.contains("ui_audit_stress_delta_vs_baseline"))
        assertTrue(stress.contains("ui_audit_stress_at_baseline"))
        assertFalse(stress.contains("""caption = "of 3 · ${'$'}{model.band.title}""""))
        assertFalse(stress.contains("""BandLegend("1-2", "MEDIUM""""))
        assertFalse(stress.contains("""BandLegend("2-3", "HIGH""""))
        assertFalse(stress.contains("""deltaText = "at baseline""""))

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
        assertTrue(sleep.contains("uiString(R.string.appwide_day_overview_sleep_score)"))
        assertTrue(sleep.contains("appwide_sleep_imported_confidence_note"))
        assertTrue(sleep.contains("tint = Palette.textTertiary"))
        assertTrue(
            source("src/main/java/com/noop/ui/ManagedCloudCard.kt")
                .contains("ManagedCloudEvidenceRow("),
        )
    }

    @Test
    fun stressAndRecoveryDriverAccessibilityAreLocalizedAcrossAllNineLocales() {
        val folders = listOf(
            "values", "values-de", "values-es", "values-fr", "values-it",
            "values-pt-rPT", "values-ru", "values-zh", "values-zh-rTW",
        )
        val stringKeys = listOf(
            "ui_audit_stress_score_caption",
            "ui_audit_stress_delta_vs_baseline",
            "ui_audit_stress_at_baseline",
            "ui_audit_stress_totals_band_calm",
            "ui_audit_stress_totals_band_moderate",
            "ui_audit_stress_totals_band_high",
            "ui_audit_stress_methodology_title",
            "ui_audit_stress_methodology_stored_summary",
            "ui_audit_stress_methodology_stored_detail",
            "ui_audit_stress_methodology_derived_summary",
            "ui_audit_stress_methodology_derived_detail",
            "ui_audit_stress_explanation_stored_high",
            "ui_audit_stress_explanation_stored_medium",
            "ui_audit_stress_explanation_stored_low",
            "ui_audit_stress_explanation_derived_high_both",
            "ui_audit_stress_explanation_derived_high_hrv",
            "ui_audit_stress_explanation_derived_high_rhr",
            "ui_audit_stress_explanation_derived_high_other",
            "ui_audit_stress_explanation_derived_medium_rhr",
            "ui_audit_stress_explanation_derived_medium_hrv",
            "ui_audit_stress_explanation_derived_medium_other",
            "ui_audit_stress_explanation_derived_low_both",
            "ui_audit_stress_explanation_derived_low_hrv",
            "ui_audit_stress_explanation_derived_low_rhr",
            "ui_audit_stress_explanation_derived_low_other",
            "ui_audit_recovery_driver_baseline_format",
            "ui_audit_recovery_driver_verdict_above_supporting",
            "ui_audit_recovery_driver_verdict_at_baseline",
            "ui_audit_recovery_driver_verdict_below_limiting",
            "ui_audit_recovery_driver_verdict_below_supporting",
            "ui_audit_recovery_driver_verdict_above_limiting",
            "ui_audit_recovery_driver_verdict_typical_night",
            "ui_audit_recovery_driver_verdict_near_baseline",
            "ui_audit_recovery_driver_verdict_warmer_limiting",
            "ui_audit_recovery_driver_verdict_cooler_limiting",
        )
        val valueFormatKeys = listOf(
            "ui_audit_recovery_driver_value_milliseconds",
            "ui_audit_recovery_driver_value_beats_per_minute",
            "ui_audit_recovery_driver_value_percent",
            "ui_audit_recovery_driver_value_breaths_per_minute",
            "ui_audit_recovery_driver_value_celsius_deviation",
        )
        val labelKeys = listOf(
            "appwide_day_overview_hrv",
            "appwide_day_overview_resting_heart_rate",
            "appwide_day_overview_sleep",
            "appwide_day_overview_respiratory_rate",
            "appwide_day_overview_skin_temperature",
        )
        val pluralKeys = listOf(
            "ui_audit_recovery_driver_accessibility_with_baseline",
            "ui_audit_recovery_driver_accessibility_without_baseline",
        )
        val placeholder = Regex("""%\d+\${'$'}s""")
        val baseStrings = stringKeys.associateWith { appWideResource("values", it) }
        val baseStringPlaceholderCounts = baseStrings.mapValues {
            placeholder.findAll(it.value).count()
        }
        val baseValueFormats = valueFormatKeys.associateWith {
            appWideResource("values", it)
        }

        folders.forEach { folder ->
            stringKeys.forEach { key ->
                val value = appWideResource(folder, key)
                assertTrue("$folder/$key must not be blank", value.isNotBlank())
                if (folder != "values") {
                    assertFalse(
                        "$folder/$key must not use the English fallback",
                        value == baseStrings.getValue(key),
                    )
                }
                assertEquals(
                    "$folder/$key placeholder count",
                    baseStringPlaceholderCounts.getValue(key),
                    placeholder.findAll(value).count(),
                )
            }
            valueFormatKeys.forEach { key ->
                val value = appWideResource(folder, key)
                assertTrue("$folder/$key must not be blank", value.isNotBlank())
                assertEquals(
                    "$folder/$key placeholder count",
                    1,
                    placeholder.findAll(value).count(),
                )
                if (
                    folder != "values" &&
                    key == "ui_audit_recovery_driver_value_breaths_per_minute"
                ) {
                    assertFalse(
                        "$folder/$key must not use the English unit",
                        value == baseValueFormats.getValue(key),
                    )
                }
            }
            labelKeys.forEach { key ->
                assertTrue(
                    "$folder/$key driver label must not be blank",
                    appWideResource(folder, key).isNotBlank(),
                )
            }
            pluralKeys.forEach { key ->
                val quantities = pluralQuantities(folder, key)
                assertTrue("$folder/$key requires an other form", "other" in quantities)
                if (folder !in setOf("values-zh", "values-zh-rTW")) {
                    assertTrue("$folder/$key requires a one form", "one" in quantities)
                }
                val expectedPlaceholders = if (key.endsWith("_with_baseline")) 5 else 4
                quantities.forEach { (quantity, value) ->
                    assertEquals(
                        "$folder/$key/$quantity placeholder count",
                        expectedPlaceholders,
                        placeholder.findAll(value).count(),
                    )
                }
            }
        }

        pluralKeys.forEach { key ->
            assertEquals(
                "$key must cover Russian plural grammar",
                setOf("one", "few", "many", "other"),
                pluralQuantities("values-ru", key).keys,
            )
        }

        val today = source("src/main/java/com/noop/ui/TodayScreen.kt")
        assertTrue(today.contains("recoveryDriverLabelRes(driver.label)"))
        assertTrue(today.contains("recoveryDriverVerdictRes(driver.verdict)"))
        assertTrue(today.contains("recoveryDriverValueFormatRes(driver.valueFormat)"))
        assertTrue(today.contains("recoveryDriverNumberText(driver.value"))
        assertTrue(today.contains("uiPlural("))
        assertTrue(today.contains("ui_audit_recovery_driver_baseline_format"))
        assertTrue(today.contains("Text(localizedLabel"))
        assertTrue(today.contains("Text(localizedVerdict"))
        assertTrue(today.contains("Text(valueText"))
        assertTrue(today.contains("Text(localizedBaseline"))
        assertTrue(today.contains("Modifier.clearAndSetSemantics"))
        assertFalse(today.contains("""trailing = "vs your baseline""""))
        assertFalse(today.contains("""removeSuffix(" baseline")"""))
        assertFalse(today.contains("Text(driver.label"))
        assertFalse(today.contains("Text(driver.verdict"))
        assertFalse(today.contains("driver.valueText"))
        assertFalse(today.contains("driver.baselineText"))
        assertFalse(today.contains("""${'$'}signed points, ${'$'}{driver.verdict}"""))

        val drivers = source("src/main/java/com/noop/analytics/RecoveryDrivers.kt")
        assertTrue(drivers.contains("ChargeDriverValueFormat.BREATHS_PER_MINUTE"))
        assertTrue(drivers.contains("ChargeDriverValueFormat.CELSIUS_DEVIATION"))
        assertFalse(drivers.contains("Locale.US"))
        assertFalse(drivers.contains("vs baseline"))
    }

    @Test
    fun liveHeartRateCopyDoesNotFallBackToEnglishInPreviouslyMissingLocales() {
        val folders = listOf("values-it", "values-ru", "values-zh", "values-zh-rTW")
        val keys = listOf(
            "health_live_hr_on",
            "health_live_hr_off",
            "health_live_hr_on_detail",
            "health_live_hr_off_detail",
            "health_live_hr_battery_notice",
        )
        val base = keys.associateWith { stringResource("values", it) }

        folders.forEach { folder ->
            keys.forEach { key ->
                val localized = stringResource(folder, key)
                assertTrue("$folder/$key must not be blank", localized.isNotBlank())
                assertFalse(
                    "$folder/$key must not use the English fallback",
                    localized == base.getValue(key),
                )
            }
        }
    }
}
