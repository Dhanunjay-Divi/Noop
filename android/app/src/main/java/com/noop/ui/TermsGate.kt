package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.noop.R
import java.text.NumberFormat

/**
 * Current Terms of Use version. Bump on a MATERIAL change (risk / liability / medical / affiliation
 * wording) to re-prompt every user for a fresh acknowledgment; leave it for typo fixes. Mirrors macOS
 * `Terms.currentVersion`. The full text ships in TERMS.md.
 */
object Terms {
    const val CURRENT_VERSION = "2.5"

    /**
     * Plain-English summary of TERMS.md §1–§6 — kept identical to the macOS `Terms.points`. Each is
     * a (headline, body) pair of string-resource ids so the gate is localized like the rest of the
     * app (PR #984); the English source wording lives in values/strings.xml, byte-identical to what
     * used to be hardcoded here. The binding text stays TERMS.md — a translation is a courtesy, not
     * the agreement.
     */
    val points: List<Pair<Int, Int>> = listOf(
        R.string.appwide_terms_point_compatibility_head to R.string.appwide_terms_point_compatibility_body,
        R.string.appwide_terms_point_ownership_head to R.string.appwide_terms_point_ownership_body,
        R.string.appwide_terms_point_medical_head to R.string.appwide_terms_point_medical_body,
        R.string.appwide_terms_point_early_access_head to R.string.appwide_terms_point_early_access_body,
    )

    /**
     * The affirmative attestations the user must EACH tick before Accept enables (clickwrap). Kept as
     * separate, conspicuous consents rather than one blanket box so each is a distinct, knowing
     * acknowledgment — the load-bearing ones being the non-affiliation attestation and the liability
     * waiver. Mirrors macOS `Terms.attestations`; the English source lives in values/strings.xml.
     * NOTE: the exact legal phrasing should be reviewed by a solicitor before this ships publicly.
     */
    val attestations: List<Int> = listOf(
        R.string.appwide_terms_attest_band,
        R.string.appwide_terms_attest_early_access,
        R.string.appwide_terms_attest_full_terms,
    )
}

/**
 * First-run acknowledgment gate (clickwrap), shown over everything — before onboarding, pairing, or
 * any Bluetooth access — until [Terms.CURRENT_VERSION] is accepted, and again if the terms materially
 * change. The user must tick the (un-pre-checked) box and tap Accept; acceptance is persisted by the
 * caller. Mirrors macOS `TermsGateView`.
 */
@Composable
fun TermsGateScreen(onAccept: () -> Unit) {
    // One flag per Terms.attestations entry; every one must be ticked before Accept enables.
    val checks = remember { mutableStateListOf(*Array(Terms.attestations.size) { false }) }
    val allChecked = checks.all { it }
    val context = LocalContext.current
    val showingFullTerms = remember { mutableStateOf(false) }
    val fullTerms = remember {
        runCatching {
            context.assets.open("TERMS.md").bufferedReader(Charsets.UTF_8).use { it.readText() }
        }.getOrElse { context.getString(R.string.terms_load_failed) }
    }

    if (showingFullTerms.value) {
        Dialog(
            onDismissRequest = { showingFullTerms.value = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(
                modifier = Modifier.fillMaxWidth(0.94f).fillMaxHeight(0.92f),
                color = Palette.surfaceBase,
            ) {
                Column(modifier = Modifier.padding(20.dp)) {
                    Text(stringResource(R.string.terms_full_title), style = NoopType.title2,
                        color = Palette.textPrimary)
                    Spacer(Modifier.height(12.dp))
                    Text(
                        fullTerms,
                        style = NoopType.footnote,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = { showingFullTerms.value = false },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text(stringResource(R.string.terms_close)) }
                }
            }
        }
    }
    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding(),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = 560.dp)
                    .align(Alignment.CenterHorizontally)
                    .padding(horizontal = 24.dp, vertical = 22.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    stringResource(R.string.terms_title),
                    style = NoopType.title1,
                    color = Palette.textPrimary,
                    textAlign = TextAlign.Center,
                )
                Text(
                    stringResource(R.string.terms_subtitle),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }

            HorizontalDivider(color = Palette.hairline)

            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp, vertical = 20.dp)
                    .widthIn(max = 560.dp)
                    .align(Alignment.CenterHorizontally),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Terms.points.forEachIndexed { index, (head, body) ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Box(
                            modifier = Modifier
                                .width(26.dp)
                                .height(26.dp)
                                .clip(CircleShape)
                                .background(Palette.surfaceRaised),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = NumberFormat.getIntegerInstance().format(index + 1),
                                style = NoopType.captionNumber,
                                color = Palette.textSecondary,
                            )
                        }
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text(
                                stringResource(head),
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                            Text(
                                stringResource(body),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                    }
                }

                HorizontalDivider(color = Palette.hairline)

                Text(
                    stringResource(R.string.terms_attest_head),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Terms.attestations.forEachIndexed { idx, resId ->
                    Surface(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { checks[idx] = !checks[idx] },
                        shape = RoundedCornerShape(8.dp),
                        color = Palette.surfaceInset,
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Checkbox(
                                checked = checks[idx],
                                onCheckedChange = { checks[idx] = it },
                                colors = CheckboxDefaults.colors(
                                    checkedColor = Palette.accent,
                                    checkmarkColor = Palette.accentInk,
                                ),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                stringResource(resId),
                                style = NoopType.footnote,
                                color = Palette.textPrimary,
                                modifier = Modifier
                                    .weight(1f)
                                    .padding(top = 11.dp, end = 8.dp, bottom = 9.dp),
                            )
                        }
                    }
                }

                OutlinedButton(
                    onClick = { showingFullTerms.value = true },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.terms_read_full))
                }

                Text(
                    stringResource(R.string.terms_footer),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                Spacer(Modifier.height(4.dp))
            }

            Surface(color = Palette.surfaceBase) {
                Column {
                    HorizontalDivider(color = Palette.hairline)
                    Button(
                        onClick = onAccept,
                        enabled = allChecked,
                        modifier = Modifier
                            .fillMaxWidth()
                            .widthIn(max = 560.dp)
                            .align(Alignment.CenterHorizontally)
                            .padding(horizontal = 24.dp, vertical = 16.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.accentInk,
                        ),
                    ) {
                        Text(stringResource(R.string.terms_accept), style = NoopType.headline)
                    }
                }
            }
            Spacer(Modifier.navigationBarsPadding())
        }
    }
}
