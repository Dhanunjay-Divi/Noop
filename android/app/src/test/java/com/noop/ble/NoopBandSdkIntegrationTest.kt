package com.noop.ble

import com.noop.bandsdk.BandConformanceRunner
import com.noop.bandsdk.BandSessionState
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class NoopBandSdkIntegrationTest {
    @Test
    fun appBoundaryCreatesPinnedNeutralSession() {
        assertEquals(
            "0abd9a3ce4f808b51bdc93ad28504ac810914631",
            NoopBandSdkBoundary.PINNED_SOURCE_REVISION,
        )
        val session = NoopBandSdkBoundary.newSession()
        assertEquals(1L, session.beginScan())
        assertEquals(BandSessionState.SCANNING, session.snapshot().state)
    }

    @Test
    fun allExportedConformanceScenariosMatchContractInAppModule() {
        val contract = JSONObject(contractFile().readText())
        assertEquals(1, contract.getInt("schemaVersion"))
        val scenarios = contract.getJSONArray("scenarios")
        val automated = (0 until scenarios.length())
            .map { scenarios.getJSONObject(it) }
            .filter { it.getBoolean("automated") }

        assertEquals(
            automated.map { it.getString("id") },
            BandConformanceRunner.automatedScenarios,
        )

        automated.forEach { scenario ->
            val scenarioId = scenario.getString("id")
            val expected = scenario.getJSONObject("expected")
            val actual = BandConformanceRunner.run(scenarioId)
            assertEquals(scenarioId, actual.scenario)
            assertEquals(
                expected.getJSONArray("events").toStringList(),
                actual.events,
            )
            assertEquals(expected.getString("finalState"), actual.finalState)
            assertEquals(
                expected.nullableString("acknowledgedCursor"),
                actual.acknowledgedCursor,
            )
            assertEquals(
                expected.getInt("acceptedSamples"),
                actual.acceptedSamples,
            )
            assertEquals(expected.nullableString("failure"), actual.failure)
        }
    }

    private fun contractFile(): File {
        val workingDirectory = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(
                workingDirectory,
                "../Vendor/NoopBandSDK/contract/conformance/scenarios.json",
            ),
            File(
                workingDirectory,
                "Vendor/NoopBandSDK/contract/conformance/scenarios.json",
            ),
            File(
                workingDirectory,
                "../../Vendor/NoopBandSDK/contract/conformance/scenarios.json",
            ),
        ).firstOrNull(File::isFile) ?: error(
            "NOOP Band SDK conformance contract is unavailable",
        )
    }

    private fun org.json.JSONArray.toStringList(): List<String> =
        (0 until length()).map { getString(it) }

    private fun JSONObject.nullableString(key: String): String? =
        if (isNull(key)) null else getString(key)
}
