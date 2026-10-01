package com.noop.ui

import androidx.compose.runtime.Composable
import java.io.File
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingInstrumentationHarnessTest {
    private object FakeHarness : OnboardingInstrumentationHarness {
        @Composable
        override fun AccountStep(
            accountReady: Boolean,
            onSyntheticSuccess: () -> Unit,
        ) = Unit

        @Composable
        override fun SupportedBandPicker(
            onSelectSimulatedBand: () -> Unit,
            onClose: () -> Unit,
        ) = Unit

        @Composable
        override fun OwnershipStep(
            claimed: Boolean,
            onSyntheticClaim: () -> Unit,
        ) = Unit

        @Composable
        override fun OperationalShellBoundary() = Unit
    }

    @After
    fun clearHarness() {
        OnboardingInstrumentationHarnessRegistry.clearForInstrumentation()
    }

    @Test
    fun registryIsEmptyUntilInstrumentationExplicitlyInstallsHarness() {
        OnboardingInstrumentationHarnessRegistry.clearForInstrumentation()
        assertNull(OnboardingInstrumentationHarnessRegistry.current())

        val registration =
            OnboardingInstrumentationHarnessRegistry.installForInstrumentation(
                FakeHarness,
            )
        assertSame(
            FakeHarness,
            OnboardingInstrumentationHarnessRegistry.current(),
        )

        registration.close()
        assertNull(OnboardingInstrumentationHarnessRegistry.current())
    }

    @Test
    fun registryRejectsASecondConcurrentHarness() {
        OnboardingInstrumentationHarnessRegistry.installForInstrumentation(
            FakeHarness,
        )

        assertThrows(IllegalStateException::class.java) {
            OnboardingInstrumentationHarnessRegistry
                .installForInstrumentation(FakeHarness)
        }
    }

    @Test
    fun createModeRequiresSyntheticDomainMatchingPasswordsAndConsent() {
        assertTrue(
            hermeticOwnershipSubmissionReady(
                createMode = true,
                email = "configured-ui-test@example.invalid",
                password = "synthetic-passphrase",
                confirmation = "synthetic-passphrase",
                acceptedTerms = true,
            ),
        )
        assertFalse(
            hermeticOwnershipSubmissionReady(
                createMode = true,
                email = "person@example.com",
                password = "synthetic-passphrase",
                confirmation = "synthetic-passphrase",
                acceptedTerms = true,
            ),
        )
        assertFalse(
            hermeticOwnershipSubmissionReady(
                createMode = true,
                email = "configured-ui-test@example.invalid",
                password = "synthetic-passphrase",
                confirmation = "different",
                acceptedTerms = true,
            ),
        )
        assertFalse(
            hermeticOwnershipSubmissionReady(
                createMode = true,
                email = "configured-ui-test@example.invalid",
                password = "synthetic-passphrase",
                confirmation = "synthetic-passphrase",
                acceptedTerms = false,
            ),
        )
    }

    @Test
    fun signInModeRetainsRealFieldSemanticsWithoutCreateOnlyInputs() {
        assertTrue(
            hermeticOwnershipSubmissionReady(
                createMode = false,
                email = "configured-ui-test@example.invalid",
                password = "synthetic-passphrase",
                confirmation = "",
                acceptedTerms = false,
            ),
        )
        assertFalse(
            hermeticOwnershipSubmissionReady(
                createMode = false,
                email = "configured-ui-test@example.invalid",
                password = "",
                confirmation = "",
                acceptedTerms = false,
            ),
        )
    }

    @Test
    fun androidTestHarnessHasNoProviderNetworkBleOrRegistryMutationCalls() {
        val source = source(
            "src/androidTest/java/com/noop/ui/OnboardingFlowInstrumentedTest.kt",
        )
        val harness = source.substringAfter(
            "private object HermeticConfiguredProviderOnboardingHarness",
        ).substringBefore("@RunWith(AndroidJUnit4::class)")

        listOf(
            "OwnershipService",
            "Firebase",
            "OkHttp",
            "pairedDevices(",
            "addPairedDevice(",
            "beginSupplierBandPairing(",
            "selectSupplierBandCandidate(",
        ).forEach { forbidden ->
            assertFalse(
                "Hermetic harness must not call $forbidden",
                harness.contains(forbidden),
            )
        }
        assertTrue(harness.contains("OwnershipAuthenticationCard("))
        assertTrue(harness.contains("onSyntheticSuccess()"))
        assertTrue(harness.contains("onSelectSimulatedBand"))
        assertTrue(harness.contains("onClick = onSyntheticClaim"))
        assertTrue(harness.contains("noop.ui-test.operational-shell-boundary"))
    }

    @Test
    fun hermeticScreenDoesNotConstructTheProviderOwnershipService() {
        val source = source(
            "src/main/java/com/noop/ui/OnboardingScreen.kt",
        )
        val ownershipSetup = source.substringAfter(
            "val ownership = remember(context, hermeticInstrumentation)",
        ).substringBefore("val ownershipStateFlow")

        assertTrue(ownershipSetup.contains("if (hermeticInstrumentation)"))
        assertTrue(ownershipSetup.contains("null"))
        assertTrue(ownershipSetup.contains("OwnershipService.get(context)"))
        assertTrue(
            ownershipSetup.indexOf("null") <
                ownershipSetup.indexOf("OwnershipService.get(context)"),
        )
    }

    @Test
    fun hermeticBluetoothStepDoesNotRequestOrMutateRuntimePermission() {
        val source = source(
            "src/main/java/com/noop/ui/OnboardingScreen.kt",
        )
        val bluetoothAdvance = source.substringAfter(
            "OnboardingPage.Bluetooth -> {",
        ).substringBefore("OnboardingPage.Connect ->")

        assertTrue(bluetoothAdvance.contains("if (!hermeticInstrumentation)"))
        assertTrue(bluetoothAdvance.contains("bleAdvanceLauncher.launch(blePerms)"))

        val testSource = source(
            "src/androidTest/java/com/noop/ui/OnboardingFlowInstrumentedTest.kt",
        )
        val configuredTest = testSource.substringAfter(
            "class ConfiguredProviderFullOnboardingInstrumentedTest",
        )
        assertFalse(configuredTest.contains("grantRuntimePermission"))
        assertFalse(configuredTest.contains("revokeRuntimePermission"))
    }

    private fun source(relative: String): String {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val file = sequenceOf(
            File(root, relative),
            File(root, "app/$relative"),
            File(root, "android/app/$relative"),
        ).firstOrNull(File::isFile)
        return requireNotNull(file) { "Missing source file: $relative" }
            .readText()
    }
}
