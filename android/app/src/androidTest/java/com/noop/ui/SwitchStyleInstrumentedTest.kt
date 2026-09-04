package com.noop.ui

import android.content.ContentValues
import android.graphics.Bitmap
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SwitchStyleInstrumentedTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun sharedSwitchKeepsOnStatesGreenAndOffStateNeutral() {
        compose.setContent {
            NoopTheme {
                Column(
                    modifier = Modifier
                        .background(Palette.surfaceBase)
                        .padding(24.dp)
                        .testTag("noop.switch.visual-surface"),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    NoopToggleSwitch(
                        checked = true,
                        onCheckedChange = {},
                        modifier = Modifier.testTag("noop.switch.enabled-on"),
                    )
                    NoopToggleSwitch(
                        checked = false,
                        onCheckedChange = {},
                        modifier = Modifier.testTag("noop.switch.off"),
                    )
                    NoopToggleSwitch(
                        checked = true,
                        onCheckedChange = null,
                        enabled = false,
                        modifier = Modifier.testTag("noop.switch.disabled-on"),
                    )
                }
            }
        }

        val enabledOn = compose.onNodeWithTag("noop.switch.enabled-on")
            .captureToImage()
            .asAndroidBitmap()
        val off = compose.onNodeWithTag("noop.switch.off")
            .captureToImage()
            .asAndroidBitmap()
        val disabledOn = compose.onNodeWithTag("noop.switch.disabled-on")
            .captureToImage()
            .asAndroidBitmap()

        val enabledGreenPixels = semanticGreenPixelCount(enabledOn)
        val offGreenPixels = semanticGreenPixelCount(off)
        val disabledGreenPixels = semanticGreenPixelCount(disabledOn)
        assertTrue("Enabled ON track is not green", enabledGreenPixels > 200)
        assertTrue("OFF track must remain neutral", offGreenPixels < enabledGreenPixels / 8)
        assertTrue("Disabled ON track must remain visibly green", disabledGreenPixels > 60)
        assertTrue(
            "Disabled ON track must be more subdued than enabled ON",
            disabledGreenPixels < enabledGreenPixels,
        )

        keepScreenshot(
            "noop-switch-green-states",
            compose.onNodeWithTag("noop.switch.visual-surface")
                .captureToImage()
                .asAndroidBitmap(),
        )
    }

    private fun semanticGreenPixelCount(bitmap: Bitmap): Int {
        var count = 0
        for (y in 0 until bitmap.height) {
            for (x in 0 until bitmap.width) {
                val color = bitmap.getPixel(x, y)
                val red = android.graphics.Color.red(color)
                val green = android.graphics.Color.green(color)
                val blue = android.graphics.Color.blue(color)
                if (green >= 90 && green > red + 35 && green > blue + 20) {
                    count += 1
                }
            }
        }
        return count
    }

    private fun keepScreenshot(name: String, bitmap: Bitmap) {
        val resolver = InstrumentationRegistry.getInstrumentation()
            .targetContext
            .contentResolver
        val fileName = "$name.png"
        resolver.delete(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
            arrayOf(fileName),
        )
        val uri = checkNotNull(
            resolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, "image/png")
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS,
                    )
                },
            ),
        )
        resolver.openOutputStream(uri).use { output ->
            checkNotNull(output)
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
        }
    }
}
