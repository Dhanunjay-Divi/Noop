package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Keeps Android's complete and intentionally feature-scoped locale sets honest. */
class AndroidLocalizationPolicyTest {
    private fun root(): File = File(System.getProperty("user.dir") ?: ".")

    private fun resourceFile(folder: String, name: String = "strings.xml"): File? = listOf(
        File(root(), "src/main/res/$folder/$name"),
        File(root(), "app/src/main/res/$folder/$name"),
        File(root(), "android/app/src/main/res/$folder/$name"),
    ).firstOrNull(File::isFile)

    private fun appWideResourceFile(folder: String): File? = listOf(
        File(root(), "src/main/res/$folder/appwide.xml"),
        File(root(), "app/src/main/res/$folder/appwide.xml"),
        File(root(), "android/app/src/main/res/$folder/appwide.xml"),
    ).firstOrNull(File::isFile)

    private fun resourceRoot(): File? = listOf(
        File(root(), "src/main/res"),
        File(root(), "app/src/main/res"),
        File(root(), "android/app/src/main/res"),
    ).firstOrNull(File::isDirectory)

    private data class ResourceValue(
        val value: String,
        val placeholders: List<String>,
    )

    private fun resources(file: File): Map<String, ResourceValue> {
        val pattern = Regex(
            """<(string|plurals)\s+name="([^"]+)"[^>]*>(.*?)</\1>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        val placeholder = Regex("""%(?:\d+\$)?[a-zA-Z]""")
        return pattern.findAll(file.readText()).associate { match ->
            val key = "${match.groupValues[1]}:${match.groupValues[2]}"
            val value = match.groupValues[3].trim()
            key to ResourceValue(
                value = value,
                placeholders = placeholder.findAll(value).map { it.value }.sorted().toList(),
            )
        }
    }

    @Test
    fun completeLocalesContainEveryDefaultResource() {
        val baseFile = resourceFile("values")
        val localizedFiles = listOf(
            "values-de",
            "values-es",
            "values-fr",
            "values-pt-rPT",
            "values-zh",
        ).associateWith(::resourceFile)
        assumeTrue(
            "Complete locale resources unavailable",
            baseFile != null && localizedFiles.values.all { it != null },
        )

        val base = resources(baseFile!!)
        val translatableKeys = base.keys.filterNot { it == "string:app_name" }.toSet()
        for ((folder, file) in localizedFiles) {
            val localized = resources(file!!)
            val missing = translatableKeys - localized.keys
            assertTrue("$folder is missing complete-locale resources: $missing", missing.isEmpty())
            assertTrue(
                "$folder has blank values: ${localized.filterValues { it.value.isBlank() }.keys}",
                localized.values.none { it.value.isBlank() },
            )
        }
    }

    @Test
    fun partialLocalesHaveExactFeatureAndPlaceholderParity() {
        val baseFile = resourceFile("values")
        val partialFiles = listOf(
            "values-it",
            "values-ru",
            "values-zh-rTW",
        ).associateWith(::resourceFile)
        assumeTrue(
            "Partial locale resources unavailable",
            baseFile != null && partialFiles.values.all { it != null },
        )

        val base = resources(baseFile!!)
        val partial = partialFiles.mapValues { resources(it.value!!) }
        val expectedKeys = partial.getValue("values-it").keys
        val allowed = Regex(
                """string:(wind_down_|sleep_planner_|strength_|key_metrics_(selection_|show_)|hydration_(adaptive_timing_|base_interval_label)).*|""" +
                """string:(profile_(bmi_|target_weight_)|vital_range_summary_).*|""" +
                """string:ownership_(delete_|deletion_).*|""" +
                """string:(widget_hrv|trends_effort|l10n_today_screen_(recovery_ea924f72|sleep_3cac34e6|resting_hr_26677094|blood_oxygen_a8ad9ff5|respiratory_1cd8c175|steps_cdde4f20|weight_69c0b815|calories_3e62ecfe))|""" +
                """string:(l10n_devices_screen_(the_whoop_4_0_reboot_frame_690a8ff2|waiting_for_the_straps_reply_5a06e7ac)|l10n_hrv_snapshot_screen_an_hrv_reading_needs_the_live_11b70bff|l10n_test_centre_screen_(heads_up_this_test_mode_is_8b82ed69|share_strap_log_for_bug_reports_b9802500)|l10n_settings_screen_share_strap_log_for_bug_reports_b9802500|l10n_workouts_screen_hrr_explanation_516)|""" +
                """string:(nav_alarms|today_calibration_valid_hrv_progress|sleep_stage_detail_withheld|stale_sync_.*|health_live_hr_.*|changelog_.*|whats_new_.*|app_report_.*|managed_friends_(account_.*|status_account_ready|delete_account_.*|deletion_scheduled_detail|delete_body)|managed_cloud_error_forbidden|managed_cloud_(import_history|cancel_import|import_alert_.*|status_import_canceled|delete_account|fresh_code|schedule_deletion|deletion_scheduled_.*|deletion_after|deletion_time_unavailable|working|cancel_deletion|checking|check_deletion|local_data_remains|delete_alert_.*|cancel|status_deletion_.*|erasure_.*))""",
        )
        val unscopedKeys = expectedKeys.filterNot(allowed::matches)

        assertTrue(
            "Partial strings.xml contains unscoped keys: $unscopedKeys",
            unscopedKeys.isEmpty(),
        )
        for ((folder, localized) in partial) {
            assertEquals("$folder feature key parity", expectedKeys, localized.keys)
            for (key in expectedKeys) {
                assertTrue("$folder key $key is absent from default resources", key in base)
                assertTrue("$folder has blank $key", localized.getValue(key).value.isNotBlank())
                assertEquals(
                    "$folder placeholder parity for $key",
                    base.getValue(key).placeholders,
                    localized.getValue(key).placeholders,
                )
            }
        }
    }

    @Test
    fun friendsSplitResourcesContainCommunicationContractInEveryLocale() {
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
        val files = folders.associateWith { resourceFile(it, "friends.xml") }
        assumeTrue(
            "Friends locale resources unavailable",
            files.values.all { it != null },
        )
        val required = setOf(
            "string:managed_friends_allow_messages",
            "string:managed_friends_allow_photos",
            "string:managed_friends_allow_audio_calls",
            "string:managed_friends_allow_video_calls",
            "string:managed_friends_communication_permissions",
            "string:managed_friends_communication_detail",
        )
        val localized = files.mapValues { resources(it.value!!) }
        val base = localized.getValue("values")
        assertTrue(
            "Default friends.xml is missing communication resources",
            base.keys.containsAll(required),
        )
        for ((folder, values) in localized) {
            assertTrue(
                "$folder friends.xml is missing communication resources",
                values.keys.containsAll(required),
            )
            for (key in required) {
                assertTrue("$folder has blank $key", values.getValue(key).value.isNotBlank())
                assertEquals(
                    "$folder placeholder parity for $key",
                    base.getValue(key).placeholders,
                    values.getValue(key).placeholders,
                )
            }
        }
    }

    @Test
    fun retiredSelfHostedFriendsPresentationResourcesAreAbsent() {
        val resources = resourceRoot()
        assumeTrue("Android resources unavailable", resources != null)
        val retiredKeys = setOf(
            "appwide_friends_invite_instructions",
            "managed_friends_source_self_hosted",
            "managed_friends_two_options_title",
            "managed_friends_two_options_body",
        )
        val offenders = resources!!
            .walkTopDown()
            .filter { file ->
                file.isFile &&
                    file.extension == "xml" &&
                    file.parentFile?.name?.startsWith("values") == true
            }
            .filter { file ->
                val source = file.readText()
                retiredKeys.any(source::contains)
            }
            .map { it.relativeTo(resources).path }
            .toList()

        assertTrue(
            "Retired self-hosted Friends presentation resource remains: $offenders",
            offenders.isEmpty(),
        )
    }

    @Test
    fun userVisibleResourcesContainNoEmDash() {
        val resources = resourceRoot()
        assumeTrue("Android resources unavailable", resources != null)
        val forbidden = '\u2014'
        val offenders = resources!!
            .walkTopDown()
            .filter { file ->
                file.isFile &&
                    file.extension == "xml" &&
                    file.parentFile?.name?.startsWith("values") == true
            }
            .flatMap { file ->
                file.readLines().mapIndexedNotNull { index, line ->
                    if (forbidden in line) {
                        "${file.relativeTo(resources).path}:${index + 1}"
                    } else {
                        null
                    }
                }
            }
            .toList()

        assertTrue(
            "User-visible Android resources contain em dashes: $offenders",
            offenders.isEmpty(),
        )
    }

    @Test
    fun uiAuditAppWideResourcesHaveExactLocaleAndPlaceholderParity() {
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
        val files = folders.associateWith(::appWideResourceFile)
        assumeTrue(
            "App-wide locale resources unavailable",
            files.values.all { it != null },
        )
        val localized = files.mapValues { resources(it.value!!) }
        val base = localized.getValue("values")
        val auditKeys = base.keys.filter {
            it.startsWith("string:appwide_ui_audit_")
        }.toSet()
        assertEquals(50, auditKeys.size)

        val forbidden = listOf(
            "whoop",
            "5/mg",
            "safe to leave on",
            "newer band only",
        )
        for ((folder, values) in localized) {
            assertEquals(
                "$folder UI-audit key parity",
                auditKeys,
                values.keys.filter { it.startsWith("string:appwide_ui_audit_") }.toSet(),
            )
            for (key in auditKeys) {
                val english = base.getValue(key)
                val translated = values.getValue(key)
                assertTrue("$folder has blank $key", translated.value.isNotBlank())
                assertEquals(
                    "$folder placeholder parity for $key",
                    english.placeholders,
                    translated.placeholders,
                )
                if (folder != "values") {
                    assertTrue(
                        "$folder retained English for $key",
                        translated.value != english.value,
                    )
                }
                val normalized = translated.value.lowercase()
                forbidden.forEach { term ->
                    assertTrue(
                        "$folder $key contains prohibited copy: $term",
                        term !in normalized,
                    )
                }
            }
        }

        assertTrue(
            base.getValue("string:appwide_ui_audit_settings_raw_capture_help")
                .value.contains("raw biometric data"),
        )
        assertTrue(
            base.getValue("string:appwide_ui_audit_test_centre_ppg_description")
                .value.contains("compatible v26 firmware"),
        )
    }
}
