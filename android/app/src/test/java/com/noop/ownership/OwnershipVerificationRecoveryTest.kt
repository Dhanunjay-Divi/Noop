package com.noop.ownership

import com.noop.R
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OwnershipVerificationRecoveryTest {
    @Test
    fun resendCooldownIsMonotonicCeilingRoundedAndBoundedToSixtySeconds() {
        val second = 1_000_000_000L
        val deadline = 60L * second

        assertEquals(
            OWNERSHIP_VERIFICATION_RESEND_COOLDOWN_SECONDS,
            ownershipVerificationResendSecondsRemaining(deadline, 0L),
        )
        assertEquals(
            60,
            ownershipVerificationResendSecondsRemaining(deadline, 1L),
        )
        assertEquals(
            59,
            ownershipVerificationResendSecondsRemaining(deadline, second),
        )
        assertEquals(
            1,
            ownershipVerificationResendSecondsRemaining(deadline, deadline - 1L),
        )
        assertEquals(
            0,
            ownershipVerificationResendSecondsRemaining(deadline, deadline),
        )
        assertEquals(
            0,
            ownershipVerificationResendSecondsRemaining(deadline, deadline + 1L),
        )
        assertEquals(
            60,
            ownershipVerificationResendSecondsRemaining(120L * second, 0L),
        )
        assertEquals(
            0,
            ownershipVerificationResendSecondsRemaining(0L, -second),
        )
    }

    @Test
    fun providerFailuresMapToPreciseUserSafeCategoriesAndStableDiagnostics() {
        val expected = mapOf(
            "ERROR_NETWORK_REQUEST_FAILED" to
                OwnershipVerificationFailureCategory.OFFLINE,
            "ERROR_INVALID_VERIFICATION_CODE" to
                OwnershipVerificationFailureCategory.INVALID_CODE,
            "ERROR_MISSING_VERIFICATION_CODE" to
                OwnershipVerificationFailureCategory.INVALID_CODE,
            "ERROR_SESSION_EXPIRED" to
                OwnershipVerificationFailureCategory.EXPIRED_SESSION,
            "ERROR_INVALID_VERIFICATION_ID" to
                OwnershipVerificationFailureCategory.EXPIRED_SESSION,
            "ERROR_MISSING_VERIFICATION_ID" to
                OwnershipVerificationFailureCategory.EXPIRED_SESSION,
            "ERROR_TOO_MANY_REQUESTS" to
                OwnershipVerificationFailureCategory.RATE_LIMITED,
            "ERROR_QUOTA_EXCEEDED" to
                OwnershipVerificationFailureCategory.RATE_LIMITED,
        )

        expected.forEach { (code, category) ->
            assertEquals(
                category,
                ownershipVerificationFailureForProviderCode(code),
            )
        }
        assertNull(ownershipVerificationFailureForProviderCode(null))
        assertNull(
            ownershipVerificationFailureForProviderCode(
                "ERROR_PRIVATE_PROVIDER_DETAIL",
            ),
        )
        assertEquals(
            setOf(
                "network",
                "verification_code_invalid",
                "verification_expired",
                "rate_limit",
                "resend_cooldown",
            ),
            OwnershipVerificationFailureCategory.entries
                .mapTo(mutableSetOf()) { it.diagnosticKind },
        )
    }

    @Test
    fun providerSignalsMapWithoutAcceptingPrivateMessagesOrPayloads() {
        assertEquals(
            OwnershipVerificationFailureCategory.OFFLINE,
            ownershipVerificationFailureForProviderSignals(
                networkFailure = true,
                rateLimitedFailure = false,
                authErrorCode = null,
            ),
        )
        assertEquals(
            OwnershipVerificationFailureCategory.RATE_LIMITED,
            ownershipVerificationFailureForProviderSignals(
                networkFailure = false,
                rateLimitedFailure = true,
                authErrorCode = null,
            ),
        )
        assertEquals(
            OwnershipVerificationFailureCategory.INVALID_CODE,
            ownershipVerificationFailureForProviderSignals(
                networkFailure = false,
                rateLimitedFailure = false,
                authErrorCode = "ERROR_INVALID_VERIFICATION_CODE",
            ),
        )
        assertEquals(
            OwnershipVerificationFailureCategory.EXPIRED_SESSION,
            ownershipVerificationFailureForProviderSignals(
                networkFailure = false,
                rateLimitedFailure = false,
                authErrorCode = "ERROR_SESSION_EXPIRED",
            ),
        )
        assertNull(
            ownershipVerificationFailureForProviderSignals(
                networkFailure = false,
                rateLimitedFailure = false,
                authErrorCode = "ERROR_PRIVATE_PROVIDER_DETAIL",
            ),
        )
    }

    @Test
    fun eachRecoveryCategoryHasOneFixedLocalizedMessageResource() {
        assertEquals(
            R.string.ownership_network_unavailable,
            ownershipVerificationMessageResource(
                OwnershipVerificationFailureCategory.OFFLINE,
            ),
        )
        assertEquals(
            R.string.ownership_verification_code_invalid,
            ownershipVerificationMessageResource(
                OwnershipVerificationFailureCategory.INVALID_CODE,
            ),
        )
        assertEquals(
            R.string.ownership_verification_session_expired,
            ownershipVerificationMessageResource(
                OwnershipVerificationFailureCategory.EXPIRED_SESSION,
            ),
        )
        assertEquals(
            R.string.ownership_verification_rate_limited,
            ownershipVerificationMessageResource(
                OwnershipVerificationFailureCategory.RATE_LIMITED,
            ),
        )
        assertEquals(
            R.string.ownership_verification_cooldown_active,
            ownershipVerificationMessageResource(
                OwnershipVerificationFailureCategory.LOCAL_COOLDOWN,
            ),
        )
    }

    @Test
    fun accountScreenDisablesBothRequestsWhileShowingCountdowns() {
        val source = source(
            "android/app/src/main/java/com/noop/ui/OwnershipAccountScreen.kt",
        )

        assertTrue(
            source.contains("R.string.ownership_resend_verification_countdown"),
        )
        assertTrue(source.contains("R.string.ownership_send_code_countdown"))
        assertTrue(
            source.contains(
                "enabled = !busy && resendSecondsRemaining == 0",
            ),
        )
        assertTrue(
            source.contains(
                "resendSecondsRemaining == 0 &&\n" +
                    "                        activityAvailable",
            ),
        )
        assertTrue(
            source.contains(
                "service.checkEmailVerification()\n" +
                    "                            emailVerificationResendSeconds =",
            ),
        )
        assertTrue(
            source.contains(
                "service.linkPhone(suppliedCode)\n" +
                    "                            phoneVerificationResendSeconds =",
            ),
        )
    }

    @Test
    fun everySupportedLocaleProvidesTheRecoveryStringsAndCountdownFormat() {
        val expectedKeys = setOf(
            "ownership_resend_verification_countdown",
            "ownership_send_code_countdown",
            "ownership_verification_code_invalid",
            "ownership_verification_session_expired",
            "ownership_verification_rate_limited",
            "ownership_verification_cooldown_active",
            "ownership_network_unavailable",
        )
        val resourceRoot = resourceRoot()
        val localeFiles = resourceRoot.listFiles()
            .orEmpty()
            .filter { directory ->
                directory.isDirectory &&
                    directory.name.startsWith("values") &&
                    File(directory, "strings.xml").isFile
            }

        assertTrue(localeFiles.isNotEmpty())
        localeFiles.forEach { directory ->
            val document = DocumentBuilderFactory.newInstance()
                .newDocumentBuilder()
                .parse(File(directory, "strings.xml"))
            val nodes = document.getElementsByTagName("string")
            val values = buildMap {
                repeat(nodes.length) { index ->
                    val node = nodes.item(index)
                    val name = node.attributes
                        ?.getNamedItem("name")
                        ?.nodeValue
                        .orEmpty()
                    if (name in expectedKeys) {
                        put(name, node.textContent)
                    }
                }
            }

            assertEquals(
                "${directory.name} recovery string keys",
                expectedKeys,
                values.keys,
            )
            assertTrue(
                "${directory.name} email countdown placeholder",
                values.getValue("ownership_resend_verification_countdown")
                    .contains("%1\$d"),
            )
            assertTrue(
                "${directory.name} phone countdown placeholder",
                values.getValue("ownership_send_code_countdown")
                    .contains("%1\$d"),
            )
        }
    }

    @Test
    fun verificationDiagnosticsNeverUseProviderMessagesOrPayloads() {
        val source = source(
            "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
        )

        assertFalse(source.contains("error.localizedMessage"))
        assertFalse(source.contains("error.message"))
        assertFalse(source.contains("\"provider_payload\""))
        assertFalse(source.contains("\"provider_error\""))
        assertTrue(source.contains("return it.diagnosticKind"))
        assertTrue(
            source.contains(
                "if (category != null) throw OwnershipVerificationFailure(category)",
            ),
        )
    }

    private fun source(relativePath: String): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, relativePath),
            File(root.parentFile ?: root, relativePath),
            File(root.parentFile?.parentFile ?: root, relativePath),
        ).first(File::isFile).readText()
    }

    private fun resourceRoot(): File {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "android/app/src/main/res"),
            File(root, "app/src/main/res"),
            File(root.parentFile ?: root, "app/src/main/res"),
        ).first(File::isDirectory)
    }
}
