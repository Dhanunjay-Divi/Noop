package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Source/resource contract for Safety Center localization and TalkBack semantics. */
class SafetyCenterLocalizationContractTest {
    private fun root(): File = File(System.getProperty("user.dir") ?: ".")

    private fun first(vararg candidates: String): File? =
        candidates.map { File(root(), it) }.firstOrNull(File::isFile)

    private fun safetyStrings(file: File): Map<String, String> {
        val pattern = Regex(
            """<string\s+name="(safety_[^"]+)"[^>]*>(.*?)</string>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        return pattern.findAll(file.readText()).associate {
            it.groupValues[1] to it.groupValues[2].trim()
        }
    }

    @Test
    fun safetyResourcesHaveExactNineLocaleParity() {
        val folders = listOf(
            "values", "values-de", "values-es", "values-fr", "values-it",
            "values-pt-rPT", "values-ru", "values-zh", "values-zh-rTW",
        )
        val files = folders.associateWith { folder ->
            first(
                "src/main/res/$folder/safety.xml",
                "app/src/main/res/$folder/safety.xml",
                "android/app/src/main/res/$folder/safety.xml",
            )
        }
        assumeTrue("Safety locale resources unavailable", files.values.all { it != null })
        val values = files.mapValues { safetyStrings(it.value!!) }
        val base = values.getValue("values")
        assertEquals(221, base.size)

        val placeholder = Regex("""%\d+\$[ds]""")
        for ((folder, localized) in values) {
            assertEquals("$folder Safety key parity", base.keys, localized.keys)
            for (key in base.keys) {
                assertTrue("$folder has blank $key", localized.getValue(key).isNotBlank())
                assertEquals(
                    "$folder placeholder parity for $key",
                    placeholder.findAll(base.getValue(key)).map { it.value }.sorted().toList(),
                    placeholder.findAll(localized.getValue(key)).map { it.value }.sorted().toList(),
                )
            }
        }
    }

    @Test
    fun safetyScreenUsesResourcesAndCompleteTalkBackLabels() {
        val screen = first(
            "src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "android/app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
        )
        val components = first(
            "src/main/java/com/noop/ui/Components.kt",
            "app/src/main/java/com/noop/ui/Components.kt",
            "android/app/src/main/java/com/noop/ui/Components.kt",
        )
        assumeTrue("Safety sources unavailable", screen != null && components != null)

        val safety = screen!!.readText()
        val shared = components!!.readText()
        assertTrue(safety.contains("copy = safetyShareCopy"))
        assertTrue(safety.contains("accessibilityLabel = {"))
        assertTrue(safety.contains("role = Role.Switch"))
        assertTrue(safety.contains("semantics(mergeDescendants = true)"))
        assertFalse(safety.contains("title = \"Safety\""))
        assertFalse(safety.contains("Text(\"If danger is immediate\")"))
        assertTrue(shared.contains("accessibilityLabel: (T) -> String = label"))
        assertTrue(shared.contains("contentDescription = accessibilityLabel(item)"))
    }

    @Test
    fun incidentReceiptAndTerminalFailureHaveAuthoritativeCopyAndDirectAction() {
        val screen = first(
            "src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "android/app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
        )
        val strings = first(
            "src/main/res/values/safety.xml",
            "app/src/main/res/values/safety.xml",
            "android/app/src/main/res/values/safety.xml",
        )
        assumeTrue("Safety screen/resources unavailable", screen != null && strings != null)

        val source = screen!!.readText()
        val resources = safetyStrings(strings!!)
        assertTrue(source.contains("dispatch.contactSummary"))
        assertTrue(source.contains("shouldShowAllContactsFailed"))
        assertTrue(source.contains("Intent.ACTION_DIAL"))
        assertTrue(source.contains("SafetyIncidentStatus.FAILED"))
        assertTrue(source.contains("SafetyIncidentStatus.FAILED,"))
        assertTrue(resources.containsKey("safety_page_contacts_reached_format"))
        assertTrue(resources.containsKey("safety_page_contact_responses"))
        assertTrue(resources.containsKey("safety_page_all_contacts_failed_title"))
        assertTrue(resources.containsKey("safety_page_call_contact_format"))
        assertTrue(resources.containsKey("safety_page_detail_failed"))
        assertEquals("Paging started", resources["safety_page_status_submitted"])
        assertTrue(
            resources.getValue("safety_page_detail_submitted")
                .contains("Delivery confirmation is pending"),
        )
        assertEquals(
            "Delivery or response confirmed for %1\$d of %2\$d contacts",
            resources["safety_page_contacts_reached_format"],
        )
        assertTrue(
            resources.getValue("safety_page_contacts_reached_format")
                .contains("Delivery or response confirmed"),
        )
        assertTrue(source.contains("R.string.safety_page_contact_responses"))
    }

    @Test
    fun postSubmitStatusUsesLocalizedSafetyResource() {
        val paging = first(
            "src/main/java/com/noop/safety/SafetyPaging.kt",
            "app/src/main/java/com/noop/safety/SafetyPaging.kt",
            "android/app/src/main/java/com/noop/safety/SafetyPaging.kt",
        )
        assumeTrue("Safety paging source unavailable", paging != null)

        val source = paging!!.readText()
        assertTrue(
            source.contains(
                "statusMessage = appContext.getString(" +
                    "R.string.safety_page_detail_submitted)",
            ),
        )
        assertFalse(source.contains("Safety page request accepted. SMS delivery is pending"))
    }

    @Test
    fun sosPermissionMonitoringAndFallBoundaryRemainExplicit() {
        val screen = first(
            "src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "android/app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
        )
        val gesture = first(
            "src/main/java/com/noop/safety/SafetySosGesture.kt",
            "app/src/main/java/com/noop/safety/SafetySosGesture.kt",
            "android/app/src/main/java/com/noop/safety/SafetySosGesture.kt",
        )
        val service = first(
            "src/main/java/com/noop/ble/WhoopConnectionService.kt",
            "app/src/main/java/com/noop/ble/WhoopConnectionService.kt",
            "android/app/src/main/java/com/noop/ble/WhoopConnectionService.kt",
        )
        val viewModel = first(
            "src/main/java/com/noop/ui/AppViewModel.kt",
            "app/src/main/java/com/noop/ui/AppViewModel.kt",
            "android/app/src/main/java/com/noop/ui/AppViewModel.kt",
        )
        assumeTrue(
            "Safety runtime sources unavailable",
            listOf(screen, gesture, service, viewModel).all { it != null },
        )

        val screenSource = screen!!.readText()
        val gestureSource = gesture!!.readText()
        assertTrue(screenSource.contains("sosNotificationPermissionLauncher.launch"))
        assertTrue(screenSource.contains("SafetyStatusNotifications.deliveryAvailable"))
        assertTrue(gestureSource.contains("SafetyIncidentStatusMonitor.start"))
        assertTrue(gestureSource.contains("WhoopConnectionService.start"))
        val serviceSource = service!!.readText()
        assertTrue(serviceSource.contains("SafetyIncidentStatusMonitor.reconcile(this)"))
        assertFalse(serviceSource.contains("FallResponseStateMachine("))
        assertFalse(viewModel!!.readText().contains("FallResponseStateMachine("))
    }
}
