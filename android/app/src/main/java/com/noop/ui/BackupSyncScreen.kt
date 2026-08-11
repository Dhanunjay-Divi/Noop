package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.content.Intent
import android.net.Uri
import android.text.format.DateUtils
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.LinkOff
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import com.noop.NoopApplication
import com.noop.ble.WhoopBleClient
import com.noop.data.DataBackup
import com.noop.data.BackupEnvelope
import com.noop.data.BackupPassphraseStore
import com.noop.sync.RemoteSyncPrefs
import com.noop.sync.RemoteSyncService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Backup & Sync (Phase 1 - folder). Apple mirror of `BackupSyncView`: pick a folder, turn on the
 * opt-in daily auto-backup, back up now, or restore. Snapshots are the existing `.noopbak` whole-DB
 * format ([DataBackup]). Point the folder at a Google Drive / Dropbox sync app for off-device backup
 * with no in-app cloud account.
 *
 * Must-fixes baked in here:
 *  1. Restore lists the snapshots in the CHOSEN folder (newest-first) and lets the user pick one,
 *     rather than re-prompting with an unrelated document picker. A tightened file fallback exists
 *     only for folders we can't enumerate / legacy files.
 *  2. An explicit in-app confirm dialog fires before any destructive restore call.
 *  3. The file-fallback picker is tightened off the all-files wildcard to the backup MIME types, and
 *     the live [DataBackup.importFrom] now also rejects a foreign-but-valid SQLite (Mac/GRDB or other-app DB).
 */
@Composable
fun BackupSyncScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    RemoteSyncService.initialize(context)

    var treeUri by remember { mutableStateOf(BackupSyncPrefs.treeUri(context)) }
    var backupSecretConfigured by remember {
        mutableStateOf(runCatching { BackupPassphraseStore.has(context) }.getOrDefault(false))
    }
    var auto by remember {
        mutableStateOf(BackupSyncPrefs.autoEnabled(context) && backupSecretConfigured)
    }
    var folderPassphrase by remember { mutableStateOf("") }
    var folderPassphraseConfirm by remember { mutableStateOf("") }
    var lastMs by remember { mutableStateOf(BackupSyncPrefs.lastBackupMs(context)) }
    var busy by remember { mutableStateOf(false) }
    // How many dated snapshots to keep; pruning deletes the oldest beyond this (BackupSync.snapshotsToPrune).
    var keep by remember { mutableStateOf(BackupSyncPrefs.keepCount(context)) }
    var keepMenu by remember { mutableStateOf(false) }
    // Time-of-day the daily backup runs (minutes since midnight); default 01:00, user-adjustable.
    var backupMinute by remember { mutableStateOf(BackupSyncPrefs.backupMinute(context)) }

    // Optional self-hosted destination. The key field intentionally starts blank even when one is
    // saved; its Keystore-backed value is never read into Compose state or rendered on screen.
    var serverUrl by remember { mutableStateOf(RemoteSyncPrefs.endpoint()) }
    var serverApiKey by remember { mutableStateOf("") }
    var serverHasKey by remember { mutableStateOf(RemoteSyncPrefs.apiKey() != null) }
    var serverAuto by remember { mutableStateOf(RemoteSyncPrefs.automatic()) }
    var serverStatus by remember { mutableStateOf(RemoteSyncPrefs.lastStatus()) }
    var serverLastSuccess by remember { mutableStateOf(RemoteSyncPrefs.lastSuccessMs()) }
    var serverBusy by remember { mutableStateOf(false) }
    var confirmFullReplay by remember { mutableStateOf(false) }
    var confirmServerDisconnect by remember { mutableStateOf(false) }

    // Restore-from-folder sheet state: the listed snapshots, and the one pending confirmation.
    var snapshots by remember { mutableStateOf<List<BackupSync.SnapshotDoc>>(emptyList()) }
    var showSnapshotPicker by remember { mutableStateOf(false) }
    var pendingRestore by remember { mutableStateOf<Pair<String, Uri>?>(null) }
    var restoreSecretTarget by remember { mutableStateOf<Pair<String, Uri>?>(null) }
    var restorePassphrase by remember { mutableStateOf("") }

    // Runs the actual destructive restore for a chosen backup Uri, off the main thread.
    fun runRestore(uri: Uri, passphrase: String) {
        busy = true
        scope.launch {
            val r = withContext(Dispatchers.IO) { DataBackup.importFrom(context, uri, passphrase) }
            busy = false
            when (r) {
                is DataBackup.ImportResult.NeedsRestart -> {
                    // Import staged a verified candidate without touching the live Room connection. A cold
                    // launch performs the atomic swap, forces Room's migration/open checks, and rolls back on
                    // failure; restart automatically so the safety gate runs now.
                    Toast.makeText(
                        context,
                        uiString(R.string.noop_backup_restart_apply),
                        Toast.LENGTH_LONG,
                    ).show()
                    // NonCancellable: this coroutine runs in the screen's scope, which is cancelled the
                    // instant the user navigates away. The restart is a data-safety guarantee (the DB is
                    // already swapped), so it must complete even if the composition leaves — otherwise the
                        // a staged restore could otherwise remain unapplied until a later cold launch.
                    withContext(NonCancellable) {
                        delay(800)
                        val ctx = context.applicationContext
                        ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
                            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                            ?.let { ctx.startActivity(it) }
                        Runtime.getRuntime().exit(0)
                    }
                }
                is DataBackup.ImportResult.Failed ->
                    Toast.makeText(context, r.message, Toast.LENGTH_LONG).show()
            }
        }
    }

    val pickFolder = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
        BackupSyncPrefs.setTreeUri(context, uri)
        treeUri = uri
        runCatching { BackupSync.reschedule(context) }
    }

    // Must-fix #1 + #3: the FILE fallback is tightened to the backup MIME types (was `*/*`). Used only
    // when the chosen folder holds no snapshots, or to restore a one-off file from elsewhere. The chosen
    // file still passes through importFrom's full validation (magic + Room/GRDB-origin) and the same
    // confirm dialog before it overwrites anything.
    val pickRestoreFile = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        pendingRestore = "the selected file" to uri
    }

    LazyScreenScaffold(
        title = uiString(R.string.l10n_backup_sync_screen_backup_sync_81758ffa),
        subtitle = "Keep local snapshots, or opt in to sending your data to a server you control.",
    ) {
        // Optional self-hosted decoded-data upload. Distinct from immutable .noopbak snapshots below.
        item {
            NoopCard(
                padding = 20.dp,
                tint = if (serverAuto && RemoteSyncPrefs.isConfigured()) Palette.accent else null,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        uiString(R.string.remote_sync_self_hosted_server),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        uiString(R.string.remote_sync_description),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                    OutlinedTextField(
                        value = serverUrl,
                        onValueChange = { serverUrl = it },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !serverBusy,
                        singleLine = true,
                        label = {
                            Text(uiString(R.string.l10n_coach_screen_server_url_1d5d1eff))
                        },
                        placeholder = { Text("https://noop.example.com") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        textStyle = NoopType.body,
                        colors = remoteSyncFieldColors(),
                    )
                    OutlinedTextField(
                        value = serverApiKey,
                        onValueChange = { serverApiKey = it },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !serverBusy,
                        singleLine = true,
                        label = { Text(uiString(R.string.remote_sync_api_key)) },
                        placeholder = {
                            Text(
                                if (serverHasKey) {
                                    uiString(R.string.remote_sync_saved_key_placeholder)
                                } else {
                                    uiString(R.string.remote_sync_bearer_token_placeholder)
                                },
                            )
                        },
                        visualTransformation = PasswordVisualTransformation(),
                        textStyle = NoopType.body,
                        colors = remoteSyncFieldColors(),
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(
                                uiString(R.string.remote_sync_automatic_upload),
                                style = NoopType.body,
                                color = Palette.textPrimary,
                            )
                            Text(
                                uiString(R.string.remote_sync_automatic_upload_description),
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        Switch(
                            checked = serverAuto,
                            enabled = !serverBusy,
                            onCheckedChange = { enabled ->
                                serverAuto = enabled
                                if (RemoteSyncPrefs.isConfigured()) {
                                    RemoteSyncService.setAutomatic(context, enabled)
                                }
                            },
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Palette.surfaceBase,
                                checkedTrackColor = Palette.accent,
                                uncheckedThumbColor = Palette.textSecondary,
                                uncheckedTrackColor = Palette.surfaceInset,
                                uncheckedBorderColor = Palette.hairline,
                            ),
                        )
                    }
                    NoopButton(
                        text = if (serverBusy) {
                            uiString(R.string.l10n_settings_screen_working_13b7bfca)
                        } else {
                            uiString(R.string.remote_sync_save_and_test)
                        },
                        leadingIcon = Icons.Filled.CloudDone,
                        fullWidth = true,
                        enabled = !serverBusy && serverUrl.isNotBlank() &&
                            (serverApiKey.isNotBlank() || serverHasKey),
                        onClick = {
                            serverBusy = true
                            scope.launch {
                                try {
                                    val status = RemoteSyncService.testConnection(
                                        context,
                                        serverUrl,
                                        serverApiKey,
                                    )
                                    serverUrl = RemoteSyncService.saveConfiguration(
                                        context,
                                        serverUrl,
                                        serverApiKey,
                                        serverAuto,
                                    )
                                    serverHasKey = true
                                    serverApiKey = ""
                                    serverStatus = "Connected — authenticated server status: ${status.status}."
                                    Toast.makeText(
                                        context,
                                        "Connected to your self-hosted server.",
                                        Toast.LENGTH_LONG,
                                    ).show()
                                } catch (error: Throwable) {
                                    serverStatus = "Connection failed: ${error.message ?: "Unknown error"}"
                                    Toast.makeText(context, serverStatus, Toast.LENGTH_LONG).show()
                                } finally {
                                    serverBusy = false
                                }
                            }
                        },
                    )
                    NoopButton(
                        text = if (serverBusy) {
                            uiString(R.string.l10n_settings_screen_working_13b7bfca)
                        } else {
                            uiString(R.string.remote_sync_sync_now)
                        },
                        leadingIcon = Icons.Filled.Sync,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !serverBusy && RemoteSyncPrefs.isConfigured(),
                        onClick = {
                            serverBusy = true
                            scope.launch {
                                try {
                                    val app = context.applicationContext as? NoopApplication
                                    val deviceId = runCatching { app?.deviceRegistry?.activeDeviceId() }
                                        .getOrNull()
                                        ?: app?.activeDeviceId
                                        ?: WhoopBleClient.DEFAULT_DEVICE_ID
                                    val result = RemoteSyncService.sync(context, deviceId)
                                    serverStatus = RemoteSyncPrefs.lastStatus()
                                    serverLastSuccess = RemoteSyncPrefs.lastSuccessMs()
                                    Toast.makeText(
                                        context,
                                        "Uploaded ${result.uploadedRawRows} pending raw rows.",
                                        Toast.LENGTH_LONG,
                                    ).show()
                                } catch (error: Throwable) {
                                    serverStatus = RemoteSyncPrefs.lastStatus()
                                    Toast.makeText(
                                        context,
                                        error.message ?: "Sync failed.",
                                        Toast.LENGTH_LONG,
                                    ).show()
                                } finally {
                                    serverBusy = false
                                }
                            }
                        },
                    )
                    NoopButton(
                        text = uiString(R.string.remote_sync_full_replay),
                        leadingIcon = Icons.Filled.Replay,
                        kind = NoopButtonKind.Tertiary,
                        fullWidth = true,
                        enabled = !serverBusy && RemoteSyncPrefs.isConfigured(),
                        onClick = { confirmFullReplay = true },
                    )
                    NoopButton(
                        text = uiString(R.string.remote_sync_disconnect_and_forget),
                        leadingIcon = Icons.Filled.LinkOff,
                        kind = NoopButtonKind.Destructive,
                        fullWidth = true,
                        enabled = !serverBusy && (serverHasKey || serverUrl.isNotBlank()),
                        onClick = { confirmServerDisconnect = true },
                    )
                    Text(
                        buildString {
                            if (serverStatus.isNotBlank()) append(serverStatus)
                            if (serverLastSuccess > 0L) {
                                if (isNotEmpty()) append("\n")
                                append("Last success: ")
                                append(DateUtils.getRelativeTimeSpanString(serverLastSuccess))
                            }
                        }.ifBlank { "Not connected yet." },
                        style = NoopType.caption,
                        color = if (serverStatus.startsWith("Sync failed") ||
                            serverStatus.startsWith("Connection failed")
                        ) {
                            Palette.statusCritical
                        } else {
                            Palette.textTertiary
                        },
                    )
                    Text(
                        uiString(R.string.remote_sync_privacy_notice),
                        style = NoopType.caption,
                        color = Palette.accent,
                    )
                }
            }
        }

        // 1 · Destination folder
        item {
            NoopCard(padding = 20.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(uiString(R.string.l10n_backup_sync_screen_backup_folder_2a33df93), style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        treeUri?.let { "Saving to: ${folderLabel(it)}" }
                            ?: "No folder chosen yet. Pick one your cloud app already syncs, or any local folder.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                    Text(
                        uiString(R.string.l10n_backup_sync_screen_tip_a_desktop_drive_dropbox_app_2eaff1e3) +
                            "folder a sync app (e.g. FolderSync / Autosync) keeps in your cloud.",
                        style = NoopType.caption, color = Palette.accent,
                    )
                    NoopButton(
                        text = if (treeUri == null) "Choose folder" else "Change folder",
                        leadingIcon = Icons.Filled.FolderOpen,
                        kind = NoopButtonKind.Secondary,
                        enabled = !busy,
                        onClick = { pickFolder.launch(null) },
                    )
                }
            }
        }

        // 2 · Auto-backup + back up now
        item {
            NoopCard(padding = 20.dp, tint = if (backupSecretConfigured) Palette.accent else null) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        uiString(R.string.noop_backup_encryption_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        if (backupSecretConfigured) {
                            uiString(R.string.noop_backup_encryption_configured_help)
                        } else {
                            uiString(R.string.noop_backup_encryption_required_help)
                        },
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                    OutlinedTextField(
                        value = folderPassphrase,
                        onValueChange = { folderPassphrase = it },
                        label = {
                            Text(
                                uiString(
                                    if (backupSecretConfigured) R.string.noop_backup_new_passphrase
                                    else R.string.noop_backup_recovery_passphrase,
                                ),
                            )
                        },
                        visualTransformation = PasswordVisualTransformation(),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = remoteSyncFieldColors(),
                    )
                    OutlinedTextField(
                        value = folderPassphraseConfirm,
                        onValueChange = { folderPassphraseConfirm = it },
                        label = { Text(uiString(R.string.noop_backup_confirm_passphrase)) },
                        visualTransformation = PasswordVisualTransformation(),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = remoteSyncFieldColors(),
                    )
                    val secretProblem = BackupEnvelope.passphraseProblem(folderPassphrase)
                    NoopButton(
                        text = uiString(
                            if (backupSecretConfigured) R.string.noop_backup_replace_recovery_passphrase
                            else R.string.noop_backup_secure_automatic_backups,
                        ),
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !busy && secretProblem == null && folderPassphrase == folderPassphraseConfirm,
                        onClick = {
                            val saved = runCatching { BackupPassphraseStore.save(context, folderPassphrase) }
                            if (saved.isSuccess) {
                                backupSecretConfigured = true
                                folderPassphrase = ""
                                folderPassphraseConfirm = ""
                                runCatching { BackupSync.reschedule(context) }
                                Toast.makeText(
                                    context,
                                    uiString(R.string.noop_backup_passphrase_saved),
                                    Toast.LENGTH_LONG,
                                ).show()
                            } else {
                                Toast.makeText(
                                    context,
                                    saved.exceptionOrNull()?.message
                                        ?: uiString(R.string.noop_backup_passphrase_save_failed),
                                    Toast.LENGTH_LONG,
                                ).show()
                            }
                        },
                    )
                    if (backupSecretConfigured) {
                        NoopButton(
                            text = uiString(R.string.noop_backup_forget_stored_passphrase),
                            kind = NoopButtonKind.Destructive,
                            fullWidth = true,
                            enabled = !busy,
                            onClick = {
                                val cleared = runCatching { BackupPassphraseStore.clear(context) }
                                if (cleared.isSuccess) {
                                    backupSecretConfigured = false
                                    auto = false
                                    BackupSyncPrefs.setAutoEnabled(context, false)
                                    runCatching { BackupSync.reschedule(context) }
                                    Toast.makeText(
                                        context,
                                        uiString(R.string.noop_backup_passphrase_removed),
                                        Toast.LENGTH_LONG,
                                    ).show()
                                } else {
                                    Toast.makeText(
                                        context,
                                        cleared.exceptionOrNull()?.message
                                            ?: uiString(R.string.noop_backup_passphrase_remove_failed),
                                        Toast.LENGTH_LONG,
                                    ).show()
                                }
                            },
                        )
                    }
                    if (folderPassphrase.isNotEmpty() && (secretProblem != null || folderPassphrase != folderPassphraseConfirm)) {
                        Text(
                            if (secretProblem != null) {
                                uiString(R.string.noop_backup_passphrase_minimum_error)
                            } else {
                                uiString(R.string.noop_backup_passphrase_mismatch)
                            },
                            style = NoopType.caption,
                            color = Palette.statusCritical,
                        )
                    }
                }
            }
        }

        // 3 · Auto-backup + back up now
        item {
            NoopCard(padding = 20.dp, tint = if (auto && treeUri != null && backupSecretConfigured) Palette.accent else null) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(uiString(R.string.l10n_backup_sync_screen_daily_auto_backup_e5627357), style = NoopType.body, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_backup_sync_screen_writes_a_fresh_dated_backup_to_bd964fc5) +
                                    "the latest $keep. Off by default - flip it on if you want it.",
                                style = NoopType.footnote, color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        Switch(
                            checked = auto,
                            enabled = treeUri != null && backupSecretConfigured && !busy,
                            onCheckedChange = {
                                auto = it
                                BackupSyncPrefs.setAutoEnabled(context, it)
                                runCatching { BackupSync.reschedule(context) }
                            },
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Palette.surfaceBase,
                                checkedTrackColor = Palette.accent,
                                uncheckedThumbColor = Palette.textSecondary,
                                uncheckedTrackColor = Palette.surfaceInset,
                                uncheckedBorderColor = Palette.hairline,
                            ),
                        )
                    }
                    // Retention: how many dated snapshots to keep. Wired to the existing setKeepCount; the
                    // next backup (auto or "Back up now") prunes the oldest beyond this count.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(uiString(R.string.l10n_backup_sync_screen_keep_last_snapshots_cd5c9ea9), style = NoopType.body, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_backup_sync_screen_older_backups_beyond_this_many_are_00b7daa6) +
                                    "daily backups). For recovery: if data ever corrupts, grab the newest snapshot.",
                                style = NoopType.footnote, color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        Box {
                            TextButton(
                                enabled = treeUri != null && !busy,
                                onClick = { keepMenu = true },
                            ) {
                                Text(uiString(R.string.l10n_backup_sync_screen_keep_1addd33c, keep), style = NoopType.body, color = Palette.accent)
                            }
                            DropdownMenu(
                                expanded = keepMenu,
                                onDismissRequest = { keepMenu = false },
                            ) {
                                KEEP_OPTIONS.forEach { n ->
                                    DropdownMenuItem(
                                        text = {
                                            Text(
                                                uiString(R.string.l10n_backup_sync_screen_n_9e03569f, n),
                                                style = NoopType.body,
                                                color = if (n == keep) Palette.accent else Palette.textPrimary,
                                            )
                                        },
                                        onClick = {
                                            keep = n
                                            BackupSyncPrefs.setKeepCount(context, n)
                                            keepMenu = false
                                        },
                                    )
                                }
                            }
                        }
                    }
                    // Backup time-of-day. Picking a new time re-anchors the schedule immediately
                    // (BackupSync.applyTimeChange); WorkManager isn't exact so it's best-effort.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(uiString(R.string.l10n_backup_sync_screen_backup_time_81557aaa), style = NoopType.body, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_backup_sync_screen_roughly_when_the_daily_backup_runs_71de04e1),
                                style = NoopType.footnote, color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        TimeChip(
                            minutes = backupMinute,
                            accessibilityLabel = "Daily backup time",
                            onPicked = { m ->
                                backupMinute = m
                                BackupSyncPrefs.setBackupMinute(context, m)
                                runCatching { BackupSync.applyTimeChange(context) }
                            },
                        )
                    }
                    Text(
                        if (lastMs > 0L) {
                            "Last backup: ${DateUtils.getRelativeTimeSpanString(lastMs)}"
                        } else {
                            "No backup yet."
                        },
                        style = NoopType.caption, color = Palette.textTertiary,
                    )
                    NoopButton(
                        text = if (busy) "Working…" else "Back up now",
                        leadingIcon = Icons.Filled.CloudUpload,
                        fullWidth = true,
                        enabled = treeUri != null && backupSecretConfigured && !busy,
                        onClick = {
                            busy = true
                            scope.launch {
                                val ok = withContext(Dispatchers.IO) { BackupSync.backupNow(context) }
                                lastMs = BackupSyncPrefs.lastBackupMs(context)
                                busy = false
                                Toast.makeText(
                                    context,
                                    if (ok) {
                                        "Backed up to your folder."
                                    } else {
                                        "Backup failed - re-pick the folder and try again."
                                    },
                                    Toast.LENGTH_LONG,
                                ).show()
                            }
                        },
                    )
                }
            }
        }

        // 4 · Restore (must-fix #1: from the chosen folder, newest-first)
        item {
            NoopCard(padding = 20.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(uiString(R.string.l10n_backup_sync_screen_restore_3cbe6d6b), style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_backup_sync_screen_replace_this_device_s_data_with_b8679c51) +
                            "so back up first if unsure.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                    NoopButton(
                        text = uiString(R.string.l10n_backup_sync_screen_restore_from_a_backup_c28917c6),
                        leadingIcon = Icons.Filled.Restore,
                        kind = NoopButtonKind.Secondary,
                        enabled = !busy,
                        onClick = {
                            val tree = treeUri
                            if (tree == null) {
                                // No folder set: fall back to the tightened file picker.
                                pickRestoreFile.launch(RESTORE_MIME_TYPES)
                            } else {
                                scope.launch {
                                    val found = withContext(Dispatchers.IO) {
                                        runCatching { BackupSync.listSnapshotDocs(context, tree) }
                                            .getOrDefault(emptyList())
                                    }
                                    if (found.isEmpty()) {
                                        // Folder has no snapshots we wrote - point at a file instead.
                                        pickRestoreFile.launch(RESTORE_MIME_TYPES)
                                    } else {
                                        snapshots = found
                                        showSnapshotPicker = true
                                    }
                                }
                            }
                        },
                    )
                }
            }
        }
    }

    if (confirmFullReplay) {
        AlertDialog(
            onDismissRequest = { confirmFullReplay = false },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(
                    uiString(R.string.remote_sync_replay_title),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
            },
            text = {
                Text(
                    uiString(R.string.remote_sync_replay_message),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmFullReplay = false
                        serverBusy = true
                        scope.launch {
                            try {
                                val app = context.applicationContext as? NoopApplication
                                val deviceId = runCatching { app?.deviceRegistry?.activeDeviceId() }
                                    .getOrNull()
                                    ?: app?.activeDeviceId
                                    ?: WhoopBleClient.DEFAULT_DEVICE_ID
                                val result = RemoteSyncService.sync(
                                    context,
                                    deviceId,
                                    fullReplay = true,
                                )
                                serverStatus = RemoteSyncPrefs.lastStatus()
                                serverLastSuccess = RemoteSyncPrefs.lastSuccessMs()
                                Toast.makeText(
                                    context,
                                    "Replay sent ${result.uploadedRawRows} raw rows; queued history will continue.",
                                    Toast.LENGTH_LONG,
                                ).show()
                            } catch (error: Throwable) {
                                serverStatus = RemoteSyncPrefs.lastStatus()
                                Toast.makeText(
                                    context,
                                    error.message ?: "Full replay failed.",
                                    Toast.LENGTH_LONG,
                                ).show()
                            } finally {
                                serverBusy = false
                            }
                        }
                    },
                ) {
                    Text(
                        uiString(R.string.remote_sync_replay),
                        style = NoopType.body,
                        color = Palette.accent,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmFullReplay = false }) {
                    Text(
                        uiString(R.string.l10n_backup_sync_screen_cancel_77dfd213),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            },
        )
    }

    if (confirmServerDisconnect) {
        AlertDialog(
            onDismissRequest = { confirmServerDisconnect = false },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(
                    uiString(R.string.remote_sync_disconnect_title),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
            },
            text = {
                Text(
                    uiString(R.string.remote_sync_disconnect_message),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmServerDisconnect = false
                        serverBusy = true
                        scope.launch {
                            try {
                                RemoteSyncService.disconnect(context)
                                serverUrl = ""
                                serverApiKey = ""
                                serverHasKey = false
                                serverAuto = false
                                serverStatus = "Disconnected — saved server credentials were removed."
                                serverLastSuccess = 0L
                                Toast.makeText(
                                    context,
                                    "Self-hosted server disconnected.",
                                    Toast.LENGTH_LONG,
                                ).show()
                            } catch (error: Throwable) {
                                serverStatus =
                                    "Disconnect failed: ${error.message ?: "Unknown error"}"
                                Toast.makeText(context, serverStatus, Toast.LENGTH_LONG).show()
                            } finally {
                                serverBusy = false
                            }
                        }
                    },
                ) {
                    Text(
                        uiString(R.string.l10n_coach_screen_disconnect_ed28e068),
                        style = NoopType.body,
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmServerDisconnect = false }) {
                    Text(
                        uiString(R.string.l10n_backup_sync_screen_cancel_77dfd213),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            },
        )
    }

    // Must-fix #1: the snapshot picker - the folder's backups, newest-first.
    if (showSnapshotPicker) {
        AlertDialog(
            onDismissRequest = { showSnapshotPicker = false },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(uiString(R.string.l10n_backup_sync_screen_choose_a_backup_2fbfb0d6), style = NoopType.title2, color = Palette.textPrimary)
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        uiString(R.string.l10n_backup_sync_screen_newest_first_restoring_replaces_this_device_97dbcd8b),
                        style = NoopType.footnote, color = Palette.textSecondary,
                    )
                    snapshots.forEach { snap ->
                        // Label + confirmation come from the resolved timeMs carried through from
                        // listSnapshotDocs, so a hand-named / date-only backup still shows a friendly date
                        // (its file-modification date) instead of the raw filename - parity with Swift. Only
                        // when the date is genuinely unknown (timeMs == 0) do we fall back to the name.
                        val whenLabel = if (snap.timeMs > 0L) {
                            DateUtils.getRelativeTimeSpanString(snap.timeMs).toString()
                        } else {
                            snap.name
                        }
                        Text(
                            text = whenLabel,
                            style = NoopType.body,
                            color = Palette.textPrimary,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    showSnapshotPicker = false
                                    pendingRestore = if (snap.timeMs > 0L) {
                                        "the backup from $whenLabel"
                                    } else {
                                        snap.name
                                    } to snap.uri
                                }
                                .padding(vertical = 10.dp),
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showSnapshotPicker = false }) {
                    Text(uiString(R.string.l10n_backup_sync_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }

    // Must-fix #2: explicit in-app confirm BEFORE any destructive restore call, on every restore path.
    pendingRestore?.let { (label, uri) ->
        AlertDialog(
            onDismissRequest = { pendingRestore = null },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(uiString(R.string.l10n_backup_sync_screen_replace_all_current_data_e9244799), style = NoopType.title2, color = Palette.textPrimary)
            },
            text = {
                Text(
                    uiString(R.string.l10n_backup_sync_screen_replace_all_current_data_with_label_b7799a16, label),
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    restorePassphrase = ""
                    restoreSecretTarget = label to uri
                    pendingRestore = null
                }) {
                    Text(uiString(R.string.l10n_backup_sync_screen_replace_a7cf7b25), style = NoopType.body, color = Palette.statusCritical)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRestore = null }) {
                    Text(uiString(R.string.l10n_backup_sync_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }

    restoreSecretTarget?.let { (_, uri) ->
        AlertDialog(
            onDismissRequest = {
                restoreSecretTarget = null
                restorePassphrase = ""
            },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(
                    uiString(R.string.noop_backup_unlock_title),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        uiString(R.string.noop_backup_unlock_folder_help),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                    OutlinedTextField(
                        value = restorePassphrase,
                        onValueChange = { restorePassphrase = it },
                        label = { Text(uiString(R.string.noop_backup_passphrase_label)) },
                        visualTransformation = PasswordVisualTransformation(),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = remoteSyncFieldColors(),
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    restoreSecretTarget = null
                    val secret = restorePassphrase
                    restorePassphrase = ""
                    runRestore(uri, secret)
                }) {
                    Text(
                        uiString(R.string.noop_backup_verify_restore),
                        style = NoopType.body,
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = {
                    restoreSecretTarget = null
                    restorePassphrase = ""
                }) {
                    Text(
                        uiString(R.string.l10n_backup_sync_screen_cancel_77dfd213),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            },
        )
    }
}

/**
 * Must-fix #3: the restore file fallback is tightened off the all-files wildcard to the backup
 * container MIME types: the .noopbak ZIP (octet-stream / zip) and a legacy plain SQLite. Anything that
 * slips through still meets importFrom's magic-byte + Room/GRDB-origin validation before it can touch
 * the live DB.
 */
/** Retention choices for the "Keep last snapshots" menu. Each snapshot is a dated .noopbak; the daily
 *  job keeps this many and prunes the oldest. Kept modest — a few days of rollback without hoarding. */
private val KEEP_OPTIONS = listOf(1, 3, 5, 7, 10, 14)

private val RESTORE_MIME_TYPES = arrayOf(
    "application/octet-stream",
    "application/zip",
    "application/x-sqlite3",
)

@Composable
private fun remoteSyncFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairlineStrong,
    focusedLabelColor = Palette.accent,
    unfocusedLabelColor = Palette.textTertiary,
    cursorColor = Palette.accent,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
    disabledContainerColor = Palette.surfaceInset,
    disabledTextColor = Palette.textTertiary,
)

/** A short, human label for a SAF tree Uri (the part after the volume colon). */
private fun folderLabel(treeUri: Uri): String {
    val seg = treeUri.lastPathSegment ?: return "selected folder"
    return seg.substringAfterLast(':').ifBlank { seg }
}
