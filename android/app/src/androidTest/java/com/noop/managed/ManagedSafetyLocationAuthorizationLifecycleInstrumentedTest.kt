package com.noop.managed

import android.Manifest
import android.app.AppOpsManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ManagedSafetyLocationAuthorizationLifecycleInstrumentedTest {
    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Before
    fun clearLease() {
        ManagedSafetyLiveLocationSession.stop(context)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        instrumentation.uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.ACCESS_FINE_LOCATION,
        )
        setLocationAppOps("allow")
    }

    @After
    fun cleanupLease() {
        ManagedSafetyLiveLocationSession.stop(context)
        setLocationAppOps("allow")
    }

    @Test
    fun revokeReconcileAndExplicitRegrantDriveOnePersistentLease() {
        val nowUnix = 1_789_632_000L
        val incidentId = UUID.randomUUID()
        val expiresAtUnix = nowUnix + 8L * 60L * 60L

        assertTrue(
            ManagedSafetyLiveLocationSession.start(
                context = context,
                incidentId = incidentId,
                expiresAtUnix = expiresAtUnix,
                nowUnix = nowUnix,
            ),
        )
        assertTrue(
            ManagedSafetyLiveLocationSession.state.value.isActiveAt(nowUnix),
        )

        val revoke = ManagedSafetyLocationRuntimePolicy.decide(
            locationAuthorized = false,
            enrolled = true,
            activeCloudIncident = true,
            activeLocalSession = true,
        )
        assertEquals(ManagedSafetyLocationRuntimeAction.STOP, revoke)
        assertTrue(ManagedSafetyLiveLocationSession.stop(context, incidentId))
        assertFalse(
            ManagedSafetyLiveLocationSession.state.value.isActiveAt(nowUnix),
        )

        val deniedReconcile = ManagedSafetyLocationRuntimePolicy.decide(
            locationAuthorized = false,
            enrolled = true,
            activeCloudIncident = true,
            activeLocalSession = false,
        )
        assertEquals(ManagedSafetyLocationRuntimeAction.NONE, deniedReconcile)
        assertFalse(
            ManagedSafetyLiveLocationSession.state.value.isActiveAt(nowUnix),
        )

        val regrant = ManagedSafetyLocationRuntimePolicy.decide(
            locationAuthorized = true,
            enrolled = true,
            activeCloudIncident = true,
            activeLocalSession = false,
        )
        assertEquals(ManagedSafetyLocationRuntimeAction.START, regrant)
        assertTrue(
            ManagedSafetyLiveLocationSession.start(
                context = context,
                incidentId = incidentId,
                expiresAtUnix = expiresAtUnix,
                nowUnix = nowUnix,
            ),
        )
        assertTrue(
            ManagedSafetyLiveLocationSession.state.value.isActiveAt(nowUnix),
        )
    }

    @Test
    fun locationAppOpsDenialFailsClosedAndExplicitRegrantRecovers() {
        try {
            assertTrue(
                authorizationEvidence(),
                ManagedSafetyLocationAuthorization.isAuthorized(
                    context,
                    shareLocation = true,
                ),
            )

            setLocationAppOps("ignore")
            waitForAuthorization(expected = false)

            setLocationAppOps("allow")
            waitForAuthorization(expected = true)
        } finally {
            setLocationAppOps("allow")
        }
    }

    private fun authorizationEvidence(): String {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        fun mode(operation: String): String =
            runCatching {
                (
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        appOps.unsafeCheckOpRawNoThrow(
                            operation,
                            context.applicationInfo.uid,
                            context.packageName,
                        )
                    } else {
                        appOps.checkOpNoThrow(
                            operation,
                            context.applicationInfo.uid,
                            context.packageName,
                        )
                    }
                ).toString()
            }.getOrElse { "error:${it::class.java.simpleName}" }
        return buildString {
            append("package=")
            append(context.packageName)
            append(" fineGranted=")
            append(
                context.packageManager.checkPermission(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    context.packageName,
                ) == PackageManager.PERMISSION_GRANTED,
            )
            append(" coarseGranted=")
            append(
                context.packageManager.checkPermission(
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                    context.packageName,
                ) == PackageManager.PERMISSION_GRANTED,
            )
            append(" fineMode=")
            append(mode(AppOpsManager.OPSTR_FINE_LOCATION))
            append(" coarseMode=")
            append(mode(AppOpsManager.OPSTR_COARSE_LOCATION))
        }
    }

    private fun waitForAuthorization(
        expected: Boolean,
        timeoutMillis: Long = 5_000L,
    ) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        while (SystemClock.elapsedRealtime() < deadline) {
            if (
                ManagedSafetyLocationAuthorization.isAuthorized(
                    context,
                    shareLocation = true,
                ) == expected
            ) {
                return
            }
            Thread.sleep(50L)
        }
        assertEquals(
            expected,
            ManagedSafetyLocationAuthorization.isAuthorized(
                context,
                shareLocation = true,
            ),
        )
    }

    private fun setLocationAppOps(mode: String) {
        runShellCommand(
            "appops set --user 0 --uid ${context.packageName} " +
                "${AppOpsManager.OPSTR_FINE_LOCATION} $mode",
        )
        runShellCommand(
            "appops set --user 0 --uid ${context.packageName} " +
                "${AppOpsManager.OPSTR_COARSE_LOCATION} $mode",
        )
    }

    private fun runShellCommand(command: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        ParcelFileDescriptor.AutoCloseInputStream(
            instrumentation.uiAutomation.executeShellCommand(command),
        ).use { it.readBytes() }
    }
}
