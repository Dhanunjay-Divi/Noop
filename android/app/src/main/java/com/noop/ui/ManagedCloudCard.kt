package com.noop.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import java.time.Instant
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.automirrored.filled.Message
import androidx.compose.material.icons.filled.CancelScheduleSend
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.NoopApplication
import com.noop.R
import com.noop.managed.ManagedCloudPhase
import com.noop.managed.ManagedCloudService
import com.noop.managed.ManagedInstallation
import com.noop.managed.ManagedLocalRetentionPolicy
import java.text.SimpleDateFormat
import kotlinx.coroutines.launch
import java.util.Date
import java.util.Locale

@Composable
internal fun ManagedCloudBackupCard() {
    val context = LocalContext.current
    val service = remember {
        (context.applicationContext as? NoopApplication)?.managedCloud
            ?: ManagedCloudService.get(context)
    }
    val state by service.state.collectAsStateWithLifecycle()
    var showSetup by remember { mutableStateOf(false) }

    LaunchedEffect(service) {
        service.bootstrap()
        if (service.state.value.phase == ManagedCloudPhase.DELETION_SCHEDULED) {
            service.refreshDeletionStatus()
        }
    }

    NoopCard(
        padding = 20.dp,
        tint = if (state.phase == ManagedCloudPhase.ENROLLED) Palette.accent else null,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    imageVector = if (state.phase == ManagedCloudPhase.ENROLLED) {
                        Icons.Filled.CloudDone
                    } else {
                        Icons.Filled.Cloud
                    },
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(22.dp),
                )
                Text(
                    text = stringResource(R.string.managed_cloud_title),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                ManagedCloudStatePill(state.phase)
            }
            Text(
                text = stringResource(R.string.managed_cloud_summary),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
            if (state.status.isNotBlank()) {
                Text(
                    text = state.status,
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
            if (state.lastSuccessMs > 0L) {
                Text(
                    text = stringResource(
                        R.string.managed_cloud_last_sync,
                        DateUtils.getRelativeTimeSpanString(state.lastSuccessMs).toString(),
                    ),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
            NoopButton(
                text = if (state.phase == ManagedCloudPhase.ENROLLED) {
                    stringResource(R.string.managed_cloud_manage)
                } else {
                    stringResource(R.string.managed_cloud_set_up)
                },
                leadingIcon = if (state.phase == ManagedCloudPhase.ENROLLED) {
                    Icons.Filled.CloudDone
                } else {
                    Icons.Filled.Cloud
                },
                kind = if (state.phase == ManagedCloudPhase.ENROLLED) {
                    NoopButtonKind.Secondary
                } else {
                    NoopButtonKind.Primary
                },
                fullWidth = true,
                onClick = { showSetup = true },
            )
        }
    }

    if (showSetup) {
        ManagedCloudSetupSheet(
            service = service,
            onDismiss = { if (!state.busy) showSetup = false },
        )
    }
}

@Composable
private fun ManagedCloudStatePill(phase: ManagedCloudPhase) {
    val presentation = when (phase) {
        ManagedCloudPhase.ENROLLED ->
            stringResource(R.string.managed_cloud_state_on) to StrandTone.Positive
        ManagedCloudPhase.DELETION_SCHEDULED ->
            stringResource(R.string.managed_cloud_state_deleting) to StrandTone.Warning
        ManagedCloudPhase.CONSENT_REQUIRED,
        ManagedCloudPhase.CODE_SENT,
        -> stringResource(R.string.managed_cloud_state_setup) to StrandTone.Warning
        ManagedCloudPhase.SIGNED_OUT,
        ManagedCloudPhase.UNAVAILABLE,
        -> stringResource(R.string.managed_cloud_state_off) to StrandTone.Neutral
    }
    StatePill(
        title = presentation.first,
        tone = presentation.second,
        showsDot = true,
    )
}

@Composable
private fun ManagedCloudSetupSheet(
    service: ManagedCloudService,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val activity = remember(context) { context.findActivity() }
    val state by service.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var phone by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var consent by remember { mutableStateOf(false) }
    var deletionCode by remember { mutableStateOf("") }
    var deletionCodeRequested by remember { mutableStateOf(false) }
    var confirmDeletion by remember { mutableStateOf(false) }
    var confirmHistoryExport by remember { mutableStateOf(false) }
    var pendingRevoke by remember { mutableStateOf<ManagedInstallation?>(null) }
    val historyExportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip"),
    ) { uri ->
        if (uri != null) {
            scope.launch { service.exportCompleteCloudHistory(uri) }
        }
    }

    LaunchedEffect(state.phase) {
        if (state.phase == ManagedCloudPhase.ENROLLED) service.refreshOverview()
    }

    NoopBottomSheet(onDismiss = onDismiss) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap)) {
            Text(
                stringResource(R.string.managed_cloud_brand),
                style = NoopType.title2,
                color = Palette.textPrimary,
            )
            when (state.phase) {
                ManagedCloudPhase.UNAVAILABLE -> ManagedCloudHeader(
                    icon = Icons.Filled.CloudOff,
                    title = stringResource(R.string.managed_cloud_unavailable_title),
                    detail = stringResource(R.string.managed_cloud_unavailable_detail),
                )
                ManagedCloudPhase.SIGNED_OUT,
                ManagedCloudPhase.CODE_SENT,
                -> {
                    ManagedCloudHeader(
                        icon = Icons.Filled.Security,
                        title = stringResource(R.string.managed_cloud_auth_title),
                        detail = stringResource(R.string.managed_cloud_auth_detail),
                    )
                    OutlinedTextField(
                        value = phone,
                        onValueChange = { phone = it },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !state.busy && state.phase != ManagedCloudPhase.CODE_SENT,
                        singleLine = true,
                        label = { Text(stringResource(R.string.managed_cloud_phone_label)) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
                        textStyle = NoopType.body,
                        colors = remoteSyncFieldColors(),
                    )
                    if (state.phase == ManagedCloudPhase.CODE_SENT) {
                        OutlinedTextField(
                            value = code,
                            onValueChange = { code = it },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !state.busy,
                            singleLine = true,
                            label = {
                                Text(stringResource(R.string.managed_cloud_code_label))
                            },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                            textStyle = NoopType.body,
                            colors = remoteSyncFieldColors(),
                        )
                        NoopButton(
                            text = if (state.busy) {
                                stringResource(R.string.managed_cloud_verifying)
                            } else {
                                stringResource(R.string.managed_cloud_verify_code)
                            },
                            leadingIcon = Icons.Filled.CheckCircle,
                            fullWidth = true,
                            enabled = !state.busy && code.isNotBlank(),
                            onClick = { scope.launch { service.verifyCode(code) } },
                        )
                        NoopButton(
                            text = stringResource(R.string.managed_cloud_use_different_number),
                            kind = NoopButtonKind.Tertiary,
                            fullWidth = true,
                            enabled = !state.busy,
                            onClick = {
                                code = ""
                                service.disconnect()
                            },
                        )
                    } else {
                        NoopButton(
                            text = if (state.busy) {
                                stringResource(R.string.managed_cloud_sending)
                            } else {
                                stringResource(R.string.managed_cloud_send_code)
                            },
                            leadingIcon = Icons.AutoMirrored.Filled.Message,
                            fullWidth = true,
                            enabled = !state.busy && phone.isNotBlank() && activity != null,
                            onClick = {
                                val host = activity ?: return@NoopButton
                                scope.launch { service.sendCode(host, phone) }
                            },
                        )
                    }
                    ManagedCloudStatus(state.status)
                    ManagedCloudBoundary()
                }
                ManagedCloudPhase.CONSENT_REQUIRED -> {
                    ManagedCloudHeader(
                        icon = Icons.Filled.Lock,
                        title = stringResource(R.string.managed_cloud_consent_title),
                        detail = stringResource(R.string.managed_cloud_consent_detail),
                    )
                    ManagedCloudEvidenceRow(
                        icon = Icons.Filled.Watch,
                        title = stringResource(R.string.managed_cloud_backed_up_title),
                        detail = stringResource(R.string.managed_cloud_backed_up_detail),
                    )
                    ManagedCloudEvidenceRow(
                        icon = Icons.Filled.Devices,
                        title = stringResource(R.string.managed_cloud_used_for_title),
                        detail = stringResource(R.string.managed_cloud_used_for_detail),
                    )
                    ManagedCloudEvidenceRow(
                        icon = Icons.Filled.CloudOff,
                        title = stringResource(R.string.managed_cloud_local_first_title),
                        detail = stringResource(R.string.managed_cloud_local_first_detail_android),
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = stringResource(R.string.managed_cloud_consent_toggle),
                            style = NoopType.body,
                            color = Palette.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(16.dp))
                        NoopToggleSwitch(
                            checked = consent,
                            enabled = !state.busy,
                            onCheckedChange = { consent = it },
                        )
                    }
                    NoopButton(
                        text = if (state.busy) {
                            stringResource(R.string.managed_cloud_enabling)
                        } else {
                            stringResource(R.string.managed_cloud_allow_backup)
                        },
                        leadingIcon = Icons.Filled.CloudDone,
                        fullWidth = true,
                        enabled = !state.busy && consent,
                        onClick = { scope.launch { service.enroll() } },
                    )
                    NoopButton(
                        text = stringResource(R.string.managed_cloud_sign_out_without_enabling),
                        kind = NoopButtonKind.Tertiary,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = service::disconnect,
                    )
                    ManagedCloudStatus(state.status)
                    ManagedCloudBoundary()
                }
                ManagedCloudPhase.ENROLLED -> {
                    ManagedCloudHeader(
                        icon = Icons.Filled.CloudDone,
                        title = stringResource(R.string.managed_cloud_enrolled_title),
                        detail = stringResource(
                            R.string.managed_cloud_enrolled_detail,
                            service.maskedPhoneNumber,
                        ),
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Text(
                                stringResource(R.string.managed_cloud_automatic_title),
                                style = NoopType.body,
                                color = Palette.textPrimary,
                            )
                            Text(
                                stringResource(R.string.managed_cloud_automatic_detail_android),
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        NoopToggleSwitch(
                            checked = service.automatic,
                            enabled = !state.busy,
                            onCheckedChange = service::setAutomatic,
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Text(
                                stringResource(R.string.managed_cloud_reduce_storage_title),
                                style = NoopType.body,
                                color = Palette.textPrimary,
                            )
                            Text(
                                stringResource(
                                    R.string.managed_cloud_reduce_storage_detail_android,
                                    ManagedLocalRetentionPolicy.DETAILED_HISTORY_DAYS,
                                ),
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        NoopToggleSwitch(
                            checked = service.optimizePhoneStorage,
                            enabled = !state.busy,
                            onCheckedChange = service::setOptimizePhoneStorage,
                        )
                    }
                    state.overview?.let { overview ->
                        val used = overview.committedBytes + overview.reservedBytes
                        val usedText = Formatter.formatShortFileSize(context, used)
                        val storageSummary = overview.maximumBytes?.let { maximum ->
                            stringResource(
                                R.string.managed_cloud_storage_summary_limited,
                                usedText,
                                Formatter.formatShortFileSize(context, maximum),
                                overview.installationCount,
                                overview.maximumInstallations,
                            )
                        } ?: stringResource(
                            R.string.managed_cloud_storage_summary,
                            usedText,
                            overview.installationCount,
                            overview.maximumInstallations,
                        )
                        Text(
                            text = storageSummary,
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    if (state.installations.isNotEmpty()) {
                        Text(
                            stringResource(R.string.managed_cloud_devices),
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        state.installations
                            .filter { it.status != "revoked" }
                            .forEach { installation ->
                                ManagedInstallationRow(
                                    installation = installation,
                                    busy = state.busy,
                                    onRevoke = { pendingRevoke = installation },
                                )
                            }
                    }
                    if (state.lastSuccessMs > 0L) {
                        Text(
                            stringResource(
                                R.string.managed_cloud_last_successful_sync,
                                DateUtils.getRelativeTimeSpanString(
                                    state.lastSuccessMs,
                                ).toString(),
                            ),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                    ManagedCloudStatus(state.status)
                    NoopButton(
                        text = if (state.busy) {
                            stringResource(R.string.managed_cloud_syncing)
                        } else {
                            stringResource(R.string.managed_cloud_sync_now)
                        },
                        leadingIcon = Icons.Filled.Sync,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = { scope.launch { service.syncNow() } },
                    )
                    NoopButton(
                        text = if (state.busy) {
                            stringResource(R.string.managed_cloud_preparing_export)
                        } else {
                            stringResource(R.string.managed_cloud_export_history)
                        },
                        leadingIcon = Icons.Filled.Download,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = { confirmHistoryExport = true },
                    )
                    NoopButton(
                        text = stringResource(R.string.managed_cloud_disconnect_phone),
                        leadingIcon = Icons.AutoMirrored.Filled.Logout,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = service::disconnect,
                    )
                    NoopButton(
                        text = stringResource(R.string.managed_cloud_delete_account),
                        leadingIcon = Icons.Filled.Delete,
                        kind = NoopButtonKind.Destructive,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = { confirmDeletion = true },
                    )
                    if (deletionCodeRequested) {
                        OutlinedTextField(
                            value = deletionCode,
                            onValueChange = { deletionCode = it },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !state.busy,
                            singleLine = true,
                            label = {
                                Text(stringResource(R.string.managed_cloud_fresh_code))
                            },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                            textStyle = NoopType.body,
                            colors = remoteSyncFieldColors(),
                        )
                        NoopButton(
                            text = if (state.busy) {
                                stringResource(R.string.managed_cloud_verifying)
                            } else {
                                stringResource(R.string.managed_cloud_schedule_deletion)
                            },
                            leadingIcon = Icons.Filled.Delete,
                            kind = NoopButtonKind.Destructive,
                            fullWidth = true,
                            enabled = !state.busy && deletionCode.isNotBlank(),
                            onClick = {
                                scope.launch {
                                    service.requestAccountDeletion(deletionCode)
                                }
                            },
                        )
                    }
                    ManagedCloudBoundary()
                }
                ManagedCloudPhase.DELETION_SCHEDULED -> {
                    ManagedCloudHeader(
                        icon = Icons.Filled.Timer,
                        title = stringResource(R.string.managed_cloud_deletion_scheduled_title),
                        detail = stringResource(R.string.managed_cloud_deletion_scheduled_detail),
                    )
                    state.deletionNotBefore?.let {
                        Text(
                            stringResource(R.string.managed_cloud_deletion_after, it),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    ManagedCloudStatus(state.status)
                    NoopButton(
                        text = if (state.busy) {
                            stringResource(R.string.managed_cloud_working)
                        } else {
                            stringResource(R.string.managed_cloud_cancel_deletion)
                        },
                        leadingIcon = Icons.Filled.CancelScheduleSend,
                        kind = NoopButtonKind.Primary,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = { scope.launch { service.cancelAccountDeletion() } },
                    )
                    NoopButton(
                        text = if (state.busy) {
                            stringResource(R.string.managed_cloud_checking)
                        } else {
                            stringResource(R.string.managed_cloud_check_deletion)
                        },
                        leadingIcon = Icons.Filled.Refresh,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = { scope.launch { service.refreshDeletionStatus() } },
                    )
                    Text(
                        stringResource(R.string.managed_cloud_local_data_remains),
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                }
            }
        }
    }

    if (confirmDeletion) {
        AlertDialog(
            onDismissRequest = { confirmDeletion = false },
            title = { Text(stringResource(R.string.managed_cloud_delete_alert_title)) },
            text = {
                Text(stringResource(R.string.managed_cloud_delete_alert_detail_android))
            },
            confirmButton = {
                TextButton(
                    enabled = !state.busy && activity != null,
                    onClick = {
                        confirmDeletion = false
                        deletionCodeRequested = true
                        val host = activity ?: return@TextButton
                        scope.launch { service.sendDeletionCode(host) }
                    },
                ) {
                    Text(
                        stringResource(R.string.managed_cloud_send_code),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDeletion = false }) {
                    Text(stringResource(R.string.managed_cloud_cancel))
                }
            },
        )
    }
    if (confirmHistoryExport) {
        AlertDialog(
            onDismissRequest = { confirmHistoryExport = false },
            title = { Text(stringResource(R.string.managed_cloud_export_alert_title)) },
            text = {
                Text(stringResource(R.string.managed_cloud_export_alert_detail_android))
            },
            confirmButton = {
                TextButton(
                    enabled = !state.busy,
                    onClick = {
                        confirmHistoryExport = false
                        historyExportLauncher.launch(managedHistoryExportName())
                    },
                ) {
                    Text(stringResource(R.string.managed_cloud_choose_file))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmHistoryExport = false }) {
                    Text(stringResource(R.string.managed_cloud_cancel))
                }
            },
        )
    }
    pendingRevoke?.let { installation ->
        AlertDialog(
            onDismissRequest = { pendingRevoke = null },
            title = { Text(stringResource(R.string.managed_cloud_revoke_alert_title)) },
            text = {
                Text(stringResource(R.string.managed_cloud_revoke_alert_detail_android))
            },
            confirmButton = {
                TextButton(
                    enabled = !state.busy,
                    onClick = {
                        pendingRevoke = null
                        scope.launch {
                            service.revokeInstallation(installation.installationId)
                        }
                    },
                ) {
                    Text(
                        stringResource(R.string.managed_cloud_revoke),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRevoke = null }) {
                    Text(stringResource(R.string.managed_cloud_cancel))
                }
            },
        )
    }
}

private fun managedHistoryExportName(now: Date = Date()): String {
    val formatter = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
    return "noop-managed-history-${formatter.format(now)}.zip"
}

@Composable
private fun ManagedCloudHeader(
    icon: ImageVector,
    title: String,
    detail: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(8.dp))
                .frostedCardSurface(cornerRadius = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = Palette.accent)
        }
        Text(title, style = NoopType.title2, color = Palette.textPrimary)
        Text(detail, style = NoopType.body, color = Palette.textSecondary)
    }
}

@Composable
private fun ManagedCloudEvidenceRow(
    icon: ImageVector,
    title: String,
    detail: String,
) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = Palette.accent,
            modifier = Modifier.size(24.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = NoopType.body, color = Palette.textPrimary)
            Text(detail, style = NoopType.caption, color = Palette.textTertiary)
        }
    }
}

@Composable
private fun ManagedCloudStatus(status: String) {
    if (status.isNotBlank()) {
        Text(status, style = NoopType.caption, color = Palette.textTertiary)
    }
}

@Composable
private fun ManagedCloudBoundary() {
    Text(
        stringResource(R.string.managed_cloud_boundary),
        style = NoopType.caption,
        color = Palette.textTertiary,
    )
}

@Composable
private fun ManagedInstallationRow(
    installation: ManagedInstallation,
    busy: Boolean,
    onRevoke: () -> Unit,
) {
    val platform = managedPlatformName(installation.platform)
    val relativeLastSeen = managedRelativeTime(installation.lastSeenAt)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        val icon = when (installation.platform) {
            "ios" -> Icons.Filled.PhoneIphone
            "android" -> Icons.Filled.PhoneAndroid
            else -> Icons.Filled.Computer
        }
        Icon(
            icon,
            contentDescription = null,
            tint = if (installation.current) Palette.statusPositive else Palette.textSecondary,
            modifier = Modifier.size(22.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                if (installation.current) {
                    stringResource(R.string.managed_cloud_this_device, platform)
                } else {
                    platform
                },
                style = NoopType.body,
                color = Palette.textPrimary,
            )
            Text(
                stringResource(R.string.managed_cloud_last_seen, relativeLastSeen),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
        if (!installation.current) {
            TextButton(enabled = !busy, onClick = onRevoke) {
                Text(
                    stringResource(R.string.managed_cloud_revoke),
                    color = Palette.statusCritical,
                )
            }
        }
    }
}

@Composable
private fun managedPlatformName(platform: String): String = when (platform) {
    "ios" -> stringResource(R.string.managed_cloud_platform_iphone)
    "android" -> stringResource(R.string.managed_cloud_platform_android)
    "macos" -> stringResource(R.string.managed_cloud_platform_mac)
    else -> stringResource(R.string.managed_cloud_platform_device)
}

@Composable
private fun managedRelativeTime(value: String): String {
    val fallback = stringResource(R.string.managed_cloud_recently)
    return runCatching {
        DateUtils.getRelativeTimeSpanString(Instant.parse(value).toEpochMilli()).toString()
    }.getOrDefault(fallback)
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
