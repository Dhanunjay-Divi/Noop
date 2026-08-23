package com.noop.protocol

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class EcgClinicalIsolationContractTest {
    private fun productionRoot(): File? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop"),
            File(root, "app/src/main/java/com/noop"),
            File(root, "android/app/src/main/java/com/noop"),
        ).firstOrNull(File::isDirectory)
    }

    @Test
    fun bandClassifierValuesStayInsideProtocolDecoder() {
        val sourceRoot = productionRoot()
        assumeTrue(
            "Android production sources unavailable from ${System.getProperty("user.dir")}",
            sourceRoot != null,
        )
        val root = sourceRoot!!
        val decoder = File(root, "protocol/Whoop5Ecg.kt").canonicalFile
        val bannedTypedTokens = listOf(
            "EcgArrhythmiaCheckResult",
            "EcgArrhythmiaCheckStatus",
            "heartKeyArrhythmiaCheckResult",
            "heartKeyArrhythmiaCheckStatus",
            "afibDetected",
            "AFIB_DETECTED",
            "normalSinusRhythm",
            "NORMAL_SINUS_RHYTHM",
        )

        val violations = buildList {
            root.walkTopDown()
                .filter { it.isFile && it.extension == "kt" && it.canonicalFile != decoder }
                .forEach { file ->
                    var text = file.readText()
                        .replace("heartKeyArrhythmiaCheckResultRaw", "")
                        .replace("heartKeyArrhythmiaCheckStatusRaw", "")
                    bannedTypedTokens
                        .filter(text::contains)
                        .forEach { token -> add("${file.relativeTo(root)}: $token") }
                    text = text.lowercase()
                    if ("afib" in text || "atrial fibrillation" in text) {
                        add("${file.relativeTo(root)}: clinical AFib wording")
                    }
                }
        }

        assertTrue(
            "Band classifier output must stay decode-only; escaped into:\n" +
                violations.sorted().joinToString("\n"),
            violations.isEmpty(),
        )
    }
}
