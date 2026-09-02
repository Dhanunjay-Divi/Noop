package com.noop.ui

import android.content.ContentValues
import android.graphics.Bitmap
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class StrengthBodyMapInstrumentedTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun frontAndBackRegionsRemainSelectedTogether() {
        compose.setContent {
            var selectedMuscles by remember { mutableStateOf(emptySet<String>()) }
            NoopTheme {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Palette.surfaceBase)
                        .padding(24.dp)
                        .testTag("noop.strength.body-map.test-surface"),
                ) {
                    StrengthNativeBodyMap(
                        statuses = emptyList(),
                        mode = StrengthBodyMapMode.LOAD,
                        selectedMuscles = selectedMuscles,
                        onSelect = { muscle ->
                            selectedMuscles = if (muscle in selectedMuscles) {
                                selectedMuscles - muscle
                            } else {
                                selectedMuscles + muscle
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(306.dp),
                    )
                    Text(
                        "Selected: " + selectedMuscles
                            .sorted()
                            .joinToString(" + ") { it.replaceFirstChar(Char::uppercase) },
                        color = Palette.textPrimary,
                        modifier = Modifier.testTag("noop.strength.body-map.selection"),
                    )
                }
            }
        }

        compose.onNodeWithTag("noop.strength.body-map").performTouchInput {
            click(Offset(width * 0.25f, height * 0.28f))
        }
        compose.onNodeWithTag("noop.strength.body-map").performTouchInput {
            click(Offset(width * 0.75f, height * 0.34f))
        }

        compose.onNodeWithTag("noop.strength.body-map.selection")
            .assertTextEquals("Selected: Back + Chest")
        Thread.sleep(1_000)
        keepScreenshot(
            "strength-body-map-multi-region",
            compose.onNodeWithTag("noop.strength.body-map.test-surface")
                .captureToImage()
                .asAndroidBitmap(),
        )
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
