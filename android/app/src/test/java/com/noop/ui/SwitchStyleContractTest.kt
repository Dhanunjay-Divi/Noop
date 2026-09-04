package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SwitchStyleContractTest {
    @Test
    fun everyBinarySwitchUsesTheSharedSemanticGreenControl() {
        val uiDirectory = uiDirectory()
        val components = File(uiDirectory, "Components.kt").readText()

        assertTrue(components.contains("checkedTrackColor = Palette.statusPositive"))
        assertTrue(
            components.contains(
                "disabledCheckedTrackColor = Palette.statusPositive.copy",
            ),
        )

        val directMaterialSwitch = Regex("""(?<![A-Za-z0-9_])Switch\(""")
        uiDirectory.listFiles()
            .orEmpty()
            .filter { it.extension == "kt" && it.name != "Components.kt" }
            .forEach { file ->
                val source = file.readText()
                assertFalse(
                    "${file.name} bypasses NoopToggleSwitch",
                    directMaterialSwitch.containsMatchIn(source),
                )
                assertFalse(
                    "${file.name} uses the monochrome accent for an ON track",
                    source.contains("checkedTrackColor = Palette.accent"),
                )
            }
    }

    private fun uiDirectory(): File {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui"),
            File(root, "app/src/main/java/com/noop/ui"),
            File(root, "android/app/src/main/java/com/noop/ui"),
        ).firstOrNull(File::isDirectory)
            ?: error("Could not locate the Android UI source directory from $root")
    }
}
