package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReviewSampleModeContractTest {
    @Test
    fun reviewSampleHasNoOperationalDependencies() {
        val source = source("com/noop/ui/ReviewSampleMode.kt")

        listOf(
            "noop.review.entry.explore",
            "noop.review.disclosure.enter",
            "noop.review.root",
            "noop.review.exit",
        ).forEach { assertTrue("Missing review contract marker $it", source.contains(it)) }

        listOf(
            "AppViewModel",
            "WhoopRepository",
            "WhoopDatabase",
            "WhoopBleClient",
            "ManagedCloudService",
            "SafetyPagingService",
            "NotificationManager",
            "WorkManager",
            "HealthConnectClient",
            "SharedPreferences",
            "LocalContext",
            "LaunchedEffect",
            "rememberSaveable",
        ).forEach { token ->
            assertFalse(
                "Review Sample must remain a pure in-memory Compose tree; found $token",
                source.contains(token),
            )
        }
    }

    @Test
    fun realSetupIsPrimaryAndReviewSampleIsSecondary() {
        val source = source("com/noop/ui/ReviewSampleMode.kt")
        val entry = source.substring(
            source.indexOf("internal fun ReviewSampleEntry("),
            source.indexOf("@Composable\ninternal fun ReviewSampleDisclosure("),
        )

        assertTrue(
            entry.indexOf("R.string.review_sample_continue_setup") <
                entry.indexOf("R.string.review_sample_explore"),
        )
        assertTrue(
            entry.substringAfter("R.string.review_sample_continue_setup")
                .substringBefore("R.string.review_sample_explore")
                .contains("modifier = Modifier.testTag(\"noop.review.entry.continue\")"),
        )
        assertTrue(
            entry.substringAfter("R.string.review_sample_explore")
                .contains("kind = NoopButtonKind.Secondary"),
        )
    }

    @Test
    fun reviewSampleBottomBarKeepsFullNamesWithoutLargeTextEllipses() {
        val source = source("com/noop/ui/ReviewSampleMode.kt")
        val block = source.substring(
            source.indexOf("bottomBar = {"),
            source.indexOf("\n        },\n    ) { inner ->"),
        )

        assertTrue(source.contains("rememberBottomBarLabelLayout("))
        assertTrue(source.contains("availableWidth = maxWidth"))
        assertTrue(block.contains("label = {"))
        assertTrue(block.contains("contentDescription = tabLabel"))
        assertTrue(block.contains("maxLines = labelLayout.maxLines"))
        assertTrue(block.contains("alwaysShowLabel = true"))
        assertTrue(block.contains(".semantics { contentDescription = tabLabel }"))
        assertTrue(block.contains(".fillMaxWidth()\n                    .navigationBarsPadding()"))
        assertTrue(block.contains("windowInsets = WindowInsets(0, 0, 0, 0)"))
        assertFalse(
            block.contains(
                ".height(maxOf(80, labelLayout.barHeightDp).dp)\n" +
                    "                        .navigationBarsPadding()",
            ),
        )
        assertFalse(block.contains("TextOverflow.Ellipsis"))
        assertFalse(block.contains("showVisualLabels"))
    }

    @Test
    fun applicationStartupDefersOperationalRuntimeUntilCurrentTerms() {
        val application = source("com/noop/NoopApplication.kt")
        val onCreate = application.substring(
            application.indexOf("override fun onCreate()"),
            application.indexOf("fun startOperationalRuntime()"),
        )
        val operational = application.substring(
            application.indexOf("fun startOperationalRuntime()"),
            application.indexOf("override fun onTrimMemory"),
        )

        assertTrue(onCreate.contains("if (hasAcceptedCurrentTerms())"))
        assertTrue(onCreate.contains("startOperationalRuntime()"))
        assertFalse(onCreate.contains("resolveActiveDeviceId()"))
        assertFalse(onCreate.contains("deferProcessMaintenance()"))
        assertTrue(operational.contains("resolveActiveDeviceId()"))
        assertTrue(operational.contains("deferProcessMaintenance()"))
        assertTrue(application.contains("AtomicBoolean(false)"))
    }

    @Test
    fun reviewGatePrecedesTermsAndViewModelConstruction() {
        val main = source("com/noop/ui/MainActivity.kt")
        val root = main.substring(main.indexOf("fun NoopRoot("))

        val reviewGate = root.indexOf("if (reviewSampleOffered")
        val termsGate = root.indexOf("TermsGateScreen(")
        val model = root.indexOf("val appViewModel: AppViewModel = viewModel()")
        assertTrue(reviewGate >= 0)
        assertTrue(termsGate > reviewGate)
        assertTrue(model > termsGate)
        assertTrue(root.contains("application.startOperationalRuntime()"))
        assertTrue(root.contains("context.mainActivityOrNull()?.resumeAfterOperationalRuntimeStarted()"))
        assertFalse(root.contains("LaunchedEffect(operationalRuntimeReady)"))
        assertFalse(main.contains("deferLaunchMaintenance()"))
    }

    private fun source(relative: String): String {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val file = listOf(
            File(userDir, "src/main/java/$relative"),
            File(userDir, "app/src/main/java/$relative"),
            File(userDir, "android/app/src/main/java/$relative"),
        ).firstOrNull(File::isFile) ?: error("Could not locate $relative from $userDir")
        return file.readText()
    }
}
