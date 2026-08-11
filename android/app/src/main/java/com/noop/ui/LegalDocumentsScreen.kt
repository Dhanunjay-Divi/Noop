package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.noop.R

private data class BundledLegalDocument(@StringRes val titleRes: Int, val assetName: String)

private val bundledLegalDocuments = listOf(
    BundledLegalDocument(R.string.noop_legal_terms, "TERMS.md"),
    BundledLegalDocument(R.string.noop_legal_license, "LICENSE"),
    BundledLegalDocument(R.string.noop_legal_notices, "NOTICE"),
    BundledLegalDocument(R.string.noop_legal_attribution, "ATTRIBUTION.md"),
)

/** Complete, offline legal surface. The generated assets come from the repository-root source files. */
@Composable
fun LegalDocumentsScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    var selectedIndex by remember { mutableIntStateOf(0) }
    val selected = bundledLegalDocuments[selectedIndex]
    val document = remember(selected.assetName) {
        runCatching {
            context.assets.open(selected.assetName).bufferedReader(Charsets.UTF_8).use { it.readText() }
        }.getOrElse { uiString(R.string.noop_legal_document_error) }
    }

    ScreenScaffold(
        title = uiString(R.string.noop_legal_title),
        subtitle = uiString(R.string.noop_legal_subtitle),
        leading = {
            OutlinedButton(
                onClick = onClose,
                border = BorderStroke(1.dp, Palette.hairline),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textPrimary),
            ) {
                Text(uiString(R.string.l10n_devices_screen_close_bbfa773e), style = NoopType.captionNumber)
            }
        },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            bundledLegalDocuments.forEachIndexed { index, item ->
                OutlinedButton(
                    onClick = { selectedIndex = index },
                    border = BorderStroke(
                        1.dp,
                        if (selectedIndex == index) Palette.accent else Palette.hairline,
                    ),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = if (selectedIndex == index) Palette.accent else Palette.textSecondary,
                    ),
                ) {
                    Text(uiString(item.titleRes), style = NoopType.captionNumber)
                }
            }
        }

        NoopCard {
            SelectionContainer {
                Text(
                    document,
                    modifier = Modifier.fillMaxWidth().padding(2.dp),
                    style = NoopType.footnote.copy(fontFamily = FontFamily.Monospace),
                    color = Palette.textSecondary,
                )
            }
        }
    }
}
