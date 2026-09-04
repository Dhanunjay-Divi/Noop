package com.noop.ui

import android.app.DatePickerDialog
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.noop.R
import com.noop.data.MedicationEntry
import com.noop.data.MedicationStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

@Composable
fun MedicationSettingsDialog(
    onDismiss: () -> Unit,
    onChanged: (Int) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var entries by remember {
        mutableStateOf(
            MedicationStore.active(context)
                .sortedBy { it.name.lowercase(Locale.getDefault()) }
        )
    }
    var editingId by remember { mutableStateOf<String?>(null) }
    var name by remember { mutableStateOf("") }
    var details by remember { mutableStateOf("") }
    var hasChangeDate by remember { mutableStateOf(false) }
    var changeDate by remember { mutableStateOf(LocalDate.now()) }
    var pendingRemoval by remember { mutableStateOf<MedicationEntry?>(null) }
    var operationInFlight by remember { mutableStateOf(false) }
    var operationFailed by remember { mutableStateOf(false) }
    val closeDescription = uiString(R.string.medication_context_close)

    fun clearDraft() {
        editingId = null
        name = ""
        details = ""
        hasChangeDate = false
        changeDate = LocalDate.now()
    }

    fun applyMutation(block: () -> Boolean) {
        if (operationInFlight) return
        operationInFlight = true
        scope.launch {
            val ok = withContext(Dispatchers.IO) { block() }
            operationInFlight = false
            if (!ok) {
                operationFailed = true
                return@launch
            }
            entries = withContext(Dispatchers.IO) {
                MedicationStore.active(context)
                    .sortedBy { it.name.lowercase(Locale.getDefault()) }
            }
            clearDraft()
            onChanged(entries.size)
        }
    }

    if (operationFailed) {
        AlertDialog(
            onDismissRequest = { operationFailed = false },
            title = { Text(uiString(R.string.medication_context_update_failed)) },
            text = { Text(uiString(R.string.medication_context_update_failed_body)) },
            confirmButton = {
                TextButton(onClick = { operationFailed = false }) {
                    Text(uiString(android.R.string.ok))
                }
            },
        )
    }

    pendingRemoval?.let { entry ->
        AlertDialog(
            onDismissRequest = { pendingRemoval = null },
            title = { Text(uiString(R.string.medication_context_remove_confirm)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingRemoval = null
                        applyMutation { MedicationStore.remove(context, entry.id) }
                    },
                ) {
                    Text(
                        uiString(R.string.medication_context_remove_action),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRemoval = null }) {
                    Text(uiString(R.string.medication_context_cancel_action))
                }
            },
        )
    }

    Dialog(
        onDismissRequest = { if (!operationInFlight) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.94f)
                .heightIn(max = 760.dp),
            shape = RoundedCornerShape(8.dp),
            color = Palette.surfaceOverlay,
        ) {
            Column(
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            uiString(R.string.medication_context_title),
                            style = NoopType.title1,
                            color = Palette.textPrimary,
                        )
                        Text(
                            uiString(R.string.medication_context_summary),
                            style = NoopType.subhead,
                            color = Palette.textSecondary,
                        )
                    }
                    IconButton(
                        enabled = !operationInFlight,
                        onClick = onDismiss,
                        modifier = Modifier.semantics {
                            contentDescription = closeDescription
                        },
                    ) {
                        Icon(
                            Icons.Filled.Close,
                            contentDescription = null,
                            tint = Palette.textSecondary,
                        )
                    }
                }

                NoopCard(tint = Palette.accent) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Overline(
                            uiString(
                                if (editingId == null) R.string.medication_context_add
                                else R.string.medication_context_edit
                            )
                        )
                        OutlinedTextField(
                            value = name,
                            onValueChange = { name = it },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            label = { Text(uiString(R.string.medication_context_name)) },
                        )
                        OutlinedTextField(
                            value = details,
                            onValueChange = { details = it },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            label = { Text(uiString(R.string.medication_context_details)) },
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Text(
                                uiString(R.string.medication_context_recent_change),
                                modifier = Modifier.weight(1f),
                                style = NoopType.subhead,
                                color = Palette.textPrimary,
                            )
                            NoopToggleSwitch(
                                checked = hasChangeDate,
                                onCheckedChange = { hasChangeDate = it },
                            )
                        }
                        if (hasChangeDate) {
                            OutlinedButton(
                                modifier = Modifier.fillMaxWidth(),
                                onClick = {
                                    DatePickerDialog(
                                        context,
                                        { _, year, month, day ->
                                            changeDate = LocalDate.of(year, month + 1, day)
                                        },
                                        changeDate.year,
                                        changeDate.monthValue - 1,
                                        changeDate.dayOfMonth,
                                    ).apply {
                                        datePicker.maxDate = System.currentTimeMillis()
                                    }.show()
                                },
                            ) {
                                Icon(
                                    Icons.Filled.CalendarMonth,
                                    contentDescription = null,
                                    modifier = Modifier.size(17.dp),
                                )
                                Spacer(Modifier.size(8.dp))
                                Text(
                                    uiString(
                                        R.string.medication_context_change_on,
                                        medicationDisplayDate(changeDate),
                                    )
                                )
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Button(
                                enabled = !operationInFlight && name.isNotBlank(),
                                onClick = {
                                    val entry = MedicationEntry(
                                        id = editingId ?: java.util.UUID.randomUUID().toString(),
                                        name = name,
                                        details = details,
                                        changeDay = changeDate.toString().takeIf { hasChangeDate },
                                    )
                                    applyMutation { MedicationStore.upsert(context, entry) }
                                },
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = Palette.accent,
                                    contentColor = Palette.surfaceBase,
                                ),
                            ) {
                                Text(
                                    uiString(
                                        if (editingId == null) {
                                            R.string.medication_context_add_action
                                        } else {
                                            R.string.medication_context_save_action
                                        }
                                    )
                                )
                            }
                            if (editingId != null) {
                                OutlinedButton(
                                    enabled = !operationInFlight,
                                    onClick = ::clearDraft,
                                ) {
                                    Text(uiString(R.string.medication_context_cancel_action))
                                }
                            }
                        }
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Overline(uiString(R.string.medication_context_active))
                    Spacer(Modifier.weight(1f))
                    Text(
                        uiString(R.string.medication_context_active_count, entries.size),
                        style = NoopType.bodyNumber,
                        color = Palette.textSecondary,
                    )
                }

                if (entries.isEmpty()) {
                    Text(
                        uiString(R.string.medication_context_none),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                } else {
                    entries.forEachIndexed { index, entry ->
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(
                                entry.name,
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                            if (entry.details.isNotEmpty()) {
                                Text(
                                    entry.details,
                                    style = NoopType.footnote,
                                    color = Palette.textSecondary,
                                )
                            }
                            Text(
                                entry.changeDay?.let { raw ->
                                    runCatching { LocalDate.parse(raw) }.getOrNull()?.let { day ->
                                        uiString(
                                            R.string.medication_context_change_on,
                                            medicationDisplayDate(day),
                                        )
                                    }
                                } ?: uiString(R.string.medication_context_no_recent_change),
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TextButton(
                                    enabled = !operationInFlight,
                                    onClick = {
                                        editingId = entry.id
                                        name = entry.name
                                        details = entry.details
                                        val parsed = entry.changeDay?.let {
                                            runCatching { LocalDate.parse(it) }.getOrNull()
                                        }
                                        hasChangeDate = parsed != null
                                        changeDate = parsed ?: LocalDate.now()
                                    },
                                ) {
                                    Text(uiString(R.string.medication_context_edit_action))
                                }
                                TextButton(
                                    enabled = !operationInFlight,
                                    onClick = { pendingRemoval = entry },
                                ) {
                                    Text(
                                        uiString(R.string.medication_context_remove_action),
                                        color = Palette.statusCritical,
                                    )
                                }
                            }
                        }
                        if (index != entries.lastIndex) {
                            HorizontalDivider(color = Palette.hairline)
                        }
                    }
                }

                NoopCard {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(
                                Icons.Filled.Lock,
                                contentDescription = null,
                                tint = Palette.accent,
                                modifier = Modifier.size(17.dp),
                            )
                            Text(
                                uiString(R.string.medication_context_privacy_title),
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                        }
                        Text(
                            uiString(R.string.medication_context_privacy_body),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                }
            }
        }
    }
}

private fun medicationDisplayDate(day: LocalDate): String =
    DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
        .withLocale(Locale.getDefault())
        .format(day)
