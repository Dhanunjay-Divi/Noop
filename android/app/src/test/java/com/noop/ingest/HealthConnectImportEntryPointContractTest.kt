package com.noop.ingest

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectImportEntryPointContractTest {
    private fun source(relativePath: String): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/$relativePath"),
            File(root, "app/src/main/java/$relativePath"),
            File(root, "android/app/src/main/java/$relativePath"),
        ).firstOrNull(File::isFile)?.readText()
            ?: error("Missing source file $relativePath from ${root.absolutePath}")
    }

    @Test
    fun uiHealthConnectImportsUseTheSerializedCurrentHeightEntryPoint() {
        val dataSources = source("com/noop/ui/DataSourcesScreen.kt")
        val onboarding = source("com/noop/ui/OnboardingScreen.kt")
        val reconciler = source("com/noop/ingest/HealthConnectReconciler.kt")

        assertFalse(dataSources.contains("HealthConnectImporter.import("))
        assertFalse(onboarding.contains("HealthConnectImporter.import("))
        assertTrue(dataSources.contains("HealthConnectReconciler.importNow("))
        assertTrue(onboarding.contains("HealthConnectReconciler.importNow("))
        assertTrue(reconciler.contains("suspend fun importNow("))
        assertTrue(reconciler.contains("reconciliationGate.run(currentHeightCm)"))
    }
}
