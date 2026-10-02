@file:OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)

package com.noop.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
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
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.autofill.AutofillNode
import androidx.compose.ui.autofill.AutofillType
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.platform.LocalAutofill
import androidx.compose.ui.platform.LocalAutofillTree
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.password
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.NoopApplication
import com.noop.R
import com.noop.managed.ManagedCloudPhase
import com.noop.managed.ManagedCloudService
import com.noop.managed.ManagedInstallation
import com.noop.managed.ManagedLocalRetentionPolicy
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.sin

internal val ManagedVerificationCodeLengthRange = 4..8
internal const val ManagedVerificationSuccessDurationMillis = 3_000L
internal const val ManagedVerificationCodeMaximumLength = 8

internal fun CoroutineScope.launchManagedVerificationSuccessDismissal(
    durationMillis: Long = ManagedVerificationSuccessDurationMillis,
    onDismiss: () -> Unit,
): Job = launch {
    delay(durationMillis)
    onDismiss()
}

internal fun sanitizeManagedVerificationCode(
    rawValue: String,
    maximumLength: Int = ManagedVerificationCodeMaximumLength,
): String = buildString {
    rawValue.forEach { character ->
        val digit = Character.digit(character, 10)
        if (digit in 0..9 && length < maximumLength.coerceAtLeast(0)) {
            append(digit)
        }
    }
}

internal fun isManagedVerificationCodeComplete(code: String): Boolean =
    code.length in ManagedVerificationCodeLengthRange

@Composable
internal fun NoopPlusScreen() {
    LazyScreenScaffold(
        title = stringResource(R.string.managed_cloud_brand),
        subtitle = stringResource(R.string.managed_cloud_summary),
    ) {
        item { ManagedCloudBackupCard() }
    }
}

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
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
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
            }
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
            if (state.phase == ManagedCloudPhase.UNAVAILABLE) {
                Text(
                    text = stringResource(R.string.managed_cloud_unavailable_detail),
                    style = NoopType.caption,
                    color = Palette.statusWarning,
                )
            } else {
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
                    modifier = Modifier.testTag("noop.noop-plus.setup"),
                    onClick = { showSetup = true },
                )
            }
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
    var confirmHistoryImport by remember { mutableStateOf(false) }
    var pendingRevoke by remember { mutableStateOf<ManagedInstallation?>(null) }
    var historyImportJob by remember { mutableStateOf<Job?>(null) }
    var verificationFailureToken by remember { mutableIntStateOf(0) }
    var verificationSuccessVisible by remember { mutableStateOf(false) }
    var verificationSuccessJob by remember { mutableStateOf<Job?>(null) }
    val historyExportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip"),
    ) { uri ->
        if (uri != null) {
            scope.launch { service.exportCompleteCloudHistory(uri) }
        }
    }
    val historyImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
            val job = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    service.importCompleteCloudHistory(uri)
                } finally {
                    historyImportJob = null
                }
            }
            historyImportJob = job
            job.start()
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            historyImportJob?.cancel()
            verificationSuccessJob?.cancel()
        }
    }

    LaunchedEffect(state.phase) {
        val verificationConfirmed = (
            state.phase == ManagedCloudPhase.CONSENT_REQUIRED ||
                state.phase == ManagedCloudPhase.ENROLLED
            ) && code.isNotEmpty()
        if (verificationConfirmed) {
            code = ""
            verificationSuccessJob?.cancel()
            verificationSuccessVisible = true
            verificationSuccessJob =
                scope.launchManagedVerificationSuccessDismissal {
                verificationSuccessVisible = false
                verificationSuccessJob = null
            }
        } else if (
            state.phase == ManagedCloudPhase.SIGNED_OUT ||
            state.phase == ManagedCloudPhase.CODE_SENT
        ) {
            verificationSuccessJob?.cancel()
            verificationSuccessJob = null
            verificationSuccessVisible = false
        }
        if (state.phase == ManagedCloudPhase.ENROLLED) service.refreshOverview()
    }

    NoopBottomSheet(onDismiss = onDismiss) {
        Box(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier
                    .testTag("noop.noop-plus.sheet")
                    .then(
                        if (verificationSuccessVisible) {
                            Modifier.clearAndSetSemantics { }
                        } else {
                            Modifier
                        },
                    ),
                verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            ) {
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
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("noop.noop-plus.phone"),
                        enabled = !state.busy && state.phase != ManagedCloudPhase.CODE_SENT,
                        singleLine = true,
                        label = { Text(stringResource(R.string.managed_cloud_phone_label)) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
                        textStyle = NoopType.body,
                        colors = remoteSyncFieldColors(),
                    )
                    if (state.phase == ManagedCloudPhase.CODE_SENT) {
                        ManagedVerificationCodeField(
                            value = code,
                            onValueChange = { code = sanitizeManagedVerificationCode(it) },
                            enabled = !state.busy,
                            failureToken = verificationFailureToken,
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag("noop.noop-plus.code"),
                        )
                        NoopButton(
                            text = if (state.busy) {
                                stringResource(R.string.managed_cloud_verifying)
                            } else {
                                stringResource(R.string.managed_cloud_verify_code)
                            },
                            leadingIcon = Icons.Filled.CheckCircle,
                            fullWidth = true,
                            enabled = !state.busy &&
                                isManagedVerificationCodeComplete(code),
                            modifier = Modifier.testTag("noop.noop-plus.verify-code"),
                            onClick = {
                                scope.launch {
                                    service.verifyCode(code)
                                    if (
                                        service.state.value.phase ==
                                        ManagedCloudPhase.CODE_SENT
                                    ) {
                                        verificationFailureToken += 1
                                    }
                                }
                            },
                        )
                        NoopButton(
                            text = stringResource(R.string.managed_cloud_use_different_number),
                            kind = NoopButtonKind.Tertiary,
                            fullWidth = true,
                            enabled = !state.busy,
                            onClick = {
                                code = ""
                                scope.launch { service.disconnect() }
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
                            modifier = Modifier.testTag("noop.noop-plus.send-code"),
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
                            modifier = Modifier.testTag("noop.noop-plus.consent"),
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
                        modifier = Modifier.testTag("noop.noop-plus.enroll"),
                        onClick = { scope.launch { service.enroll() } },
                    )
                    NoopButton(
                        text = stringResource(R.string.managed_cloud_sign_out_without_enabling),
                        kind = NoopButtonKind.Tertiary,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = { scope.launch { service.disconnect() } },
                    )
                    ManagedCloudStatus(state.status)
                    ManagedCloudBoundary()
                }
                ManagedCloudPhase.ENROLLED -> {
                    Box(modifier = Modifier.testTag("noop.noop-plus.enrolled")) {
                        ManagedCloudHeader(
                            icon = Icons.Filled.CloudDone,
                            title = stringResource(R.string.managed_cloud_enrolled_title),
                            detail = stringResource(
                                R.string.managed_cloud_enrolled_detail,
                                service.maskedPhoneNumber,
                            ),
                        )
                    }
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
                                    ManagedLocalRetentionPolicy.RAW_HISTORY_DAYS,
                                    ManagedLocalRetentionPolicy.ESSENTIAL_HISTORY_DAYS,
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
                        modifier = Modifier.testTag("noop.noop-plus.sync"),
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
                        text = stringResource(
                            if (historyImportJob != null) {
                                R.string.managed_cloud_cancel_import
                            } else {
                                R.string.managed_cloud_import_history
                            },
                        ),
                        leadingIcon = if (historyImportJob != null) {
                            Icons.Filled.CancelScheduleSend
                        } else {
                            Icons.Filled.UploadFile
                        },
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = historyImportJob != null || !state.busy,
                        modifier = Modifier.testTag("noop.noop-plus.import-history"),
                        onClick = {
                            historyImportJob?.cancel()
                                ?: run { confirmHistoryImport = true }
                        },
                    )
                    NoopButton(
                        text = stringResource(R.string.managed_cloud_disconnect_phone),
                        leadingIcon = Icons.AutoMirrored.Filled.Logout,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = { scope.launch { service.disconnect() } },
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
                    state.deletionNotBefore?.let { raw ->
                        val formatted = managedDeletionEligibilityTime(raw)
                        Text(
                            formatted?.let {
                                stringResource(
                                    R.string.managed_cloud_deletion_after,
                                    it,
                                )
                            } ?: stringResource(
                                R.string.managed_cloud_deletion_time_unavailable,
                            ),
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
            if (verificationSuccessVisible) {
                ManagedVerificationSuccessOverlay(
                    modifier = Modifier.matchParentSize(),
                )
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
    if (confirmHistoryImport) {
        AlertDialog(
            onDismissRequest = { confirmHistoryImport = false },
            title = { Text(stringResource(R.string.managed_cloud_import_alert_title)) },
            text = {
                Text(stringResource(R.string.managed_cloud_import_alert_detail_android))
            },
            confirmButton = {
                TextButton(
                    enabled = !state.busy,
                    onClick = {
                        confirmHistoryImport = false
                        historyImportLauncher.launch(arrayOf("application/zip"))
                    },
                ) {
                    Text(stringResource(R.string.managed_cloud_choose_file))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmHistoryImport = false }) {
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

@Composable
private fun ManagedVerificationCodeField(
    value: String,
    onValueChange: (String) -> Unit,
    enabled: Boolean,
    failureToken: Int,
    modifier: Modifier = Modifier,
) {
    val reduceMotion = rememberReduceMotion()
    val characters = value.toList()
    val label = stringResource(R.string.managed_cloud_code_label)
    val nudgePhase by animateFloatAsState(
        targetValue = failureToken.toFloat(),
        animationSpec = if (reduceMotion) {
            snap()
        } else {
            tween(durationMillis = 240)
        },
    )
    val nudgeDistancePx = with(LocalDensity.current) {
        Metrics.space4.toPx()
    }

    BasicTextField(
        value = value,
        onValueChange = { onValueChange(sanitizeManagedVerificationCode(it)) },
        enabled = enabled,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
        textStyle = NoopType.body.copy(color = Color.Transparent),
        cursorBrush = SolidColor(Color.Transparent),
        modifier = modifier
            .managedCloudOtpAutofill(onValueChange)
            .graphicsLayer {
                translationX = if (reduceMotion) {
                    0f
                } else {
                    nudgeDistancePx * sin(nudgePhase * PI.toFloat() * 4f)
                }
            }
            .semantics {
                contentDescription = label
                password()
            },
        decorationBox = { innerTextField ->
            Box {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space4),
                ) {
                    repeat(ManagedVerificationCodeMaximumLength) { index ->
                        val populated = index < characters.size
                        val current = enabled &&
                            index == minOf(
                                characters.size,
                                ManagedVerificationCodeMaximumLength - 1,
                            )
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .height(Metrics.verificationCodeSlotHeight)
                                .clip(
                                    RoundedCornerShape(
                                        Metrics.verificationCodeSlotRadius,
                                    ),
                                )
                                .background(
                                    if (current) {
                                        Palette.accent.copy(alpha = 0.10f)
                                    } else {
                                        Palette.surfaceRaised
                                    },
                                )
                                .border(
                                    width = if (current) 1.4.dp else 0.8.dp,
                                    color = if (current) {
                                        Palette.accent
                                    } else {
                                        Palette.hairlineStrong
                                    },
                                    shape = RoundedCornerShape(
                                        Metrics.verificationCodeSlotRadius,
                                    ),
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = if (populated) {
                                    characters[index].toString()
                                } else {
                                    "·"
                                },
                                style = NoopType.title2.copy(
                                    fontWeight = FontWeight.SemiBold,
                                ),
                                color = if (populated) {
                                    Palette.textPrimary
                                } else {
                                    Palette.textTertiary.copy(alpha = 0.48f)
                                },
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .alpha(0.01f),
                ) {
                    innerTextField()
                }
            }
        },
    )
}

@Composable
private fun ManagedVerificationSuccessOverlay(
    modifier: Modifier = Modifier,
) {
    val reduceMotion = rememberReduceMotion()
    val verifiedLabel = stringResource(R.string.ownership_phone_verified_label)
    var showCheck by remember { mutableStateOf(reduceMotion) }
    val checkScale by animateFloatAsState(
        targetValue = if (showCheck) 1f else 0.42f,
        animationSpec = if (reduceMotion) {
            snap()
        } else {
            NoopMotion.value()
        },
    )

    LaunchedEffect(reduceMotion) {
        if (reduceMotion) return@LaunchedEffect
        showCheck = true
    }

    Box(
        modifier = modifier
            .testTag("noop.noop-plus.verified")
            .background(Palette.surfaceBase.copy(alpha = 0.88f))
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        awaitPointerEvent().changes.forEach { it.consume() }
                    }
                }
            }
            .focusable()
            .semantics(mergeDescendants = true) {
                contentDescription = verifiedLabel
                liveRegion = LiveRegionMode.Assertive
                paneTitle = verifiedLabel
            },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Metrics.space12),
        ) {
            Box(
                modifier = Modifier
                    .size(Metrics.verificationSuccessDiameter)
                    .clip(CircleShape)
                    .background(Palette.surfaceRaised)
                    .border(
                        1.dp,
                        Palette.accent.copy(alpha = 0.64f),
                        CircleShape,
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier
                        .size(Metrics.controlHeight + Metrics.space8)
                        .graphicsLayer {
                            scaleX = checkScale
                            scaleY = checkScale
                            alpha = if (showCheck) 1f else 0f
                        },
                )
            }
            Text(
                text = verifiedLabel,
                style = NoopType.headline,
                color = Palette.textPrimary,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = Metrics.space24),
            )
        }
    }
}

@Suppress("DEPRECATION")
@Composable
private fun Modifier.managedCloudOtpAutofill(
    onFill: (String) -> Unit,
): Modifier {
    val autofill = LocalAutofill.current
    val autofillTree = LocalAutofillTree.current
    val currentOnFill by rememberUpdatedState(onFill)
    val node = remember {
        AutofillNode(
            autofillTypes = listOf(AutofillType.SmsOtpCode),
            onFill = {
                currentOnFill(sanitizeManagedVerificationCode(it))
            },
        )
    }
    DisposableEffect(autofillTree, node) {
        autofillTree += node
        onDispose {
            autofillTree.children.remove(node.id)
        }
    }
    return onGloballyPositioned {
        node.boundingBox = it.boundsInWindow()
    }.onFocusChanged {
        if (it.isFocused) {
            autofill?.requestAutofillForNode(node)
        } else {
            autofill?.cancelAutofillForNode(node)
        }
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

internal fun managedDeletionEligibilityTime(
    value: String,
    zoneId: ZoneId = ZoneId.systemDefault(),
    locale: Locale = Locale.getDefault(),
): String? = runCatching {
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
        .withLocale(locale)
        .withZone(zoneId)
        .format(Instant.parse(value))
}.getOrNull()

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
