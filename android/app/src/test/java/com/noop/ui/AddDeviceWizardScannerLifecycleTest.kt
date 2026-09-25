package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AddDeviceWizardScannerLifecycleTest {
    @Test
    fun deferredScannerDoesNotConstructOrStopBeforeFirstScan() {
        var constructions = 0
        var stops = 0
        val expected = Any()
        val scanner = DeferredScanner {
            constructions += 1
            expected
        }

        scanner.ifInitialized { stops += 1 }

        assertEquals(0, constructions)
        assertEquals(0, stops)
        assertSame(expected, scanner.get())
        assertSame(expected, scanner.get())
        assertEquals(1, constructions)

        scanner.ifInitialized {
            assertSame(expected, it)
            stops += 1
        }
        assertEquals(1, stops)
    }

    @Test
    fun wizardDefersEveryOptionalScannerFactoryAndDisposalDoesNotAcquireOne() {
        val source = source().readText()
        val scannerSetup = source
            .substringAfter("// Discovery-only scanners are acquired")
            .substringBefore("fun startScan(t: DeviceType)")
        val stopAll = source
            .substringAfter("fun stopAllScans()")
            .substringBefore("fun launchDurableRegistration(")

        listOf(
            "makeStrapScanner",
            "makeFtmsScanner",
            "makeHuamiScanner",
            "makeOuraScanner",
        ).forEach { factory ->
            assertTrue(
                "$factory must be behind DeferredScanner",
                Regex(
                    """DeferredScanner\s*\{\s*viewModel\.${Regex.escape(factory)}\(\)\s*}""",
                ).containsMatchIn(scannerSetup),
            )
            assertFalse(
                "$factory must not be constructed by an eager remember",
                scannerSetup.contains("remember { viewModel.$factory() }"),
            )
        }
        assertEquals(4, Regex("""\.ifInitialized\s*\{""").findAll(stopAll).count())
        assertFalse(stopAll.contains(".get()"))
    }

    private fun source(): File {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/com/noop/ui/AddDeviceWizard.kt"),
            File(userDir, "app/src/main/java/com/noop/ui/AddDeviceWizard.kt"),
            File(userDir, "android/app/src/main/java/com/noop/ui/AddDeviceWizard.kt"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate AddDeviceWizard.kt from $userDir")
    }
}
