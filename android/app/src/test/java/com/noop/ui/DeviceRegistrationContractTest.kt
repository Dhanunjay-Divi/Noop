package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceRegistrationContractTest {
    @Test
    fun activeRegistrationUsesVerifiedAtomicRegistryOperation() {
        val viewModel = source("AppViewModel.kt").readText()
        val registration = viewModel
            .substringAfter("suspend fun registerDevice(")
            .substringBefore("/**\n     * Store the 16-byte Oura")

        assertTrue(registration.contains("): Boolean"))
        assertTrue(
            registration.contains(
                "if (!noopApp.deviceRegistry.addAndSetActive(device)) return false",
            ),
        )
        assertTrue(registration.contains("publishActiveDevice(device.id, changed)"))
        assertFalse(registration.contains("setActiveDevice(device.id)"))
        assertTrue(registration.contains("return addPairedDevice(device)"))
        assertFalse(
            registration.contains(
                "addPairedDevice(device)\n" +
                    "            return true",
            ),
        )
        assertTrue(
            registration.indexOf("addAndSetActive(device)") <
                registration.indexOf("publishActiveDevice(device.id, changed)"),
        )
    }

    @Test
    fun wizardReportsSuccessFromTheDurableRegistrationResult() {
        val wizard = source("AddDeviceWizard.kt").readText()
        val finishAdd = wizard
            .substringAfter("fun finishAdd(makeActive: Boolean)")
            .substringBefore("fun finishAddOura(closeAfter: Boolean)")

        assertTrue(
            finishAdd.contains(
                "viewModel.registerDevice(device, makeActive = makeActive)",
            ),
        )
        assertFalse(
            finishAdd.contains(
                "viewModel.registerDevice(device, makeActive = makeActive)\n" +
                    "                true",
            ),
        )
        val finishOura = wizard
            .substringAfter("fun finishAddOura(closeAfter: Boolean)")
            .substringBefore("// The live adopt-failure reason")
        assertTrue(
            finishOura.contains(
                "viewModel.registerDevice(device, makeActive = true)",
            ),
        )
        assertFalse(
            finishOura.contains(
                "viewModel.registerDevice(device, makeActive = true)\n" +
                    "                true",
            ),
        )
    }

    @Test
    fun compatibleBandRegistrationKeepsTheObservedFamilyLabel() {
        val wizard = source("AddDeviceWizard.kt").readText()

        assertTrue(
            wizard.contains(
                "pickedWhoop?.let { return@run it.model.registrationLabel() }",
            ),
        )
        assertTrue(wizard.contains("nameDraft = strap.model.registrationLabel()"))
        assertTrue(wizard.contains("nickname = confirmName"))
        assertTrue(
            wizard.contains(
                "WhoopModel.WHOOP4 ->\n" +
                    "        uiString(R.string.appwide_onboarding_device_wizard_compatible_4_title)",
            ),
        )
        assertTrue(
            wizard.contains(
                "WhoopModel.WHOOP5_MG ->\n" +
                    "        uiString(R.string.appwide_onboarding_device_wizard_compatible_5_title)",
            ),
        )
    }

    private fun source(name: String): File {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/com/noop/ui/$name"),
            File(userDir, "app/src/main/java/com/noop/ui/$name"),
            File(userDir, "android/app/src/main/java/com/noop/ui/$name"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate $name from $userDir")
    }
}
