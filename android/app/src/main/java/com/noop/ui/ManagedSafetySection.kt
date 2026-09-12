package com.noop.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.foundation.text.KeyboardOptions
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.NoopApplication
import com.noop.R
import com.noop.managed.ManagedCloudPhase
import com.noop.managed.ManagedCloudService
import com.noop.managed.ManagedSafetyContact
import com.noop.managed.ManagedSafetyIncident
import com.noop.managed.ManagedSafetyLocationAuthorization
import com.noop.managed.ManagedSafetyRequest
import com.noop.managed.ManagedSocialIdentifier
import com.noop.safety.SafetyLocation
import java.time.Instant
import java.util.Locale
import kotlinx.coroutines.launch

@Composable
internal fun ManagedSafetySection(
    currentLocation: SafetyLocation?,
    locationReady: Boolean,
    foregroundLocationReady: Boolean,
    backgroundLocationReady: Boolean,
    onRequestLocation: () -> Unit,
    onRequestBackgroundLocation: () -> Unit,
    durationHours: Int,
    onDurationHoursChange: (Int) -> Unit,
) {
    val context = LocalContext.current
    val service = remember {
        (context.applicationContext as? NoopApplication)?.managedCloud
            ?: ManagedCloudService.get(context)
    }
    val state by service.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var noopId by rememberSaveable { mutableStateOf("") }
    var shareLocation by rememberSaveable { mutableStateOf(false) }
    var confirmPage by rememberSaveable { mutableStateOf(false) }
    var contactToRemove by remember { mutableStateOf<ManagedSafetyContact?>(null) }
    val managedLocationReady = locationReady &&
        currentLocation?.horizontalAccuracyMeters?.let {
            it.isFinite() && it in 0.0..10_000.0
        } == true
    val locationIncidentReady =
        ManagedSafetyLocationAuthorization.canStartIncident(
            shareLocation = shareLocation,
            sdkInt = Build.VERSION.SDK_INT,
            foregroundGranted = foregroundLocationReady,
            backgroundGranted = backgroundLocationReady,
        ) && (!shareLocation || managedLocationReady)
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            scope.launch { service.registerCurrentManagedPushToken() }
        }
    }

    fun ensureNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            scope.launch { service.registerCurrentManagedPushToken() }
        }
    }

    fun shareInvite() {
        val link = service.safetyInviteUri()?.toString() ?: return
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(
                Intent.EXTRA_SUBJECT,
                context.getString(R.string.managed_safety_share_invite_subject),
            )
            putExtra(
                Intent.EXTRA_TEXT,
                context.getString(R.string.managed_safety_share_invite_body) + "\n\n" + link,
            )
        }
        context.startActivity(
            Intent.createChooser(
                intent,
                context.getString(R.string.managed_safety_share_invite),
            ),
        )
    }

    LaunchedEffect(service) {
        service.bootstrap()
        if (service.state.value.phase == ManagedCloudPhase.ENROLLED) {
            service.refreshSafety()
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                service.registerCurrentManagedPushToken()
            }
        }
    }

    if (confirmPage) {
        AlertDialog(
            onDismissRequest = { confirmPage = false },
            title = { Text(stringResource(R.string.managed_safety_confirm_title)) },
            text = {
                Text(
                    if (shareLocation) {
                        stringResource(
                            R.string.managed_safety_confirm_location_body,
                            durationHours,
                        )
                    } else {
                        stringResource(R.string.managed_safety_confirm_body)
                    },
                )
            },
            confirmButton = {
                TextButton(
                    enabled = !state.busy && locationIncidentReady,
                    onClick = {
                        if (!locationIncidentReady) {
                            confirmPage = false
                            return@TextButton
                        }
                        confirmPage = false
                        val fix = currentLocation
                        scope.launch {
                            val incident = service.createSafetyIncident(
                                durationHours = durationHours,
                                shareLocation = shareLocation,
                            )
                            if (shareLocation && incident != null && fix != null) {
                                service.updateSafetyLocation(
                                    incidentId = incident.incidentId,
                                    latitude = fix.latitude,
                                    longitude = fix.longitude,
                                    horizontalAccuracyM =
                                        fix.horizontalAccuracyMeters ?: return@launch,
                                    capturedAt = Instant.ofEpochSecond(fix.capturedAtUnix),
                                )
                                service.refreshSafety()
                            }
                        }
                    },
                ) {
                    Text(
                        stringResource(R.string.managed_safety_confirm_send),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmPage = false }) {
                    Text(stringResource(R.string.safety_cancel))
                }
            },
        )
    }

    contactToRemove?.let { contact ->
        AlertDialog(
            onDismissRequest = { contactToRemove = null },
            title = { Text(stringResource(R.string.managed_safety_remove_contact)) },
            text = { Text(contact.displayName) },
            confirmButton = {
                TextButton(
                    onClick = {
                        contactToRemove = null
                        scope.launch { service.removeSafetyContact(contact.profileId) }
                    },
                ) {
                    Text(
                        stringResource(R.string.safety_remove),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { contactToRemove = null }) {
                    Text(stringResource(R.string.safety_cancel))
                }
            },
        )
    }

    SectionHeader(
        stringResource(R.string.managed_safety_section),
        overline = stringResource(R.string.managed_safety_section_overline),
    )
    if (state.phase != ManagedCloudPhase.ENROLLED) {
        NoopCard {
            Row(
                horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                verticalAlignment = Alignment.Top,
                modifier = Modifier.semantics(mergeDescendants = true) {},
            ) {
                Icon(Icons.Filled.Shield, contentDescription = null, tint = Palette.accent)
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    Text(
                        stringResource(R.string.managed_safety_app_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.managed_safety_not_enrolled),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            }
        }
        return
    }

    val contacts = state.safetyContacts
    val outboundContacts = contacts?.contacts.orEmpty().filter { it.role == "contact" }
    val minimum = contacts?.minimumRequired ?: 2
    val activeOwner = state.safetyIncidents.firstOrNull {
        it.role == "owner" && it.status in setOf("open", "acknowledged")
    }
    val eightHourLabel = stringResource(R.string.safety_sos_duration_8_hours)
    val twelveHourLabel = stringResource(R.string.safety_sos_duration_12_hours)

    NoopCard(tint = Palette.statusCritical) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(Icons.Filled.Warning, contentDescription = null, tint = Palette.statusCritical)
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
                    Text(
                        stringResource(R.string.managed_safety_page_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.managed_safety_page_body),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            }
            Text(
                stringResource(R.string.managed_safety_duration),
                style = NoopType.overline,
                color = Palette.textTertiary,
            )
            SegmentedPillControl(
                items = listOf(8, 12),
                selection = durationHours,
                label = { if (it == 12) twelveHourLabel else eightHourLabel },
                accessibilityLabel = {
                    context.getString(
                        if (it == 12) {
                            R.string.safety_sos_duration_12_hours
                        } else {
                            R.string.safety_sos_duration_8_hours
                        },
                    )
                },
                onSelect = onDurationHoursChange,
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .toggleable(
                        value = shareLocation,
                        role = Role.Switch,
                        onValueChange = { shareLocation = it },
                    )
                    .padding(vertical = Metrics.space4)
                    .semantics(mergeDescendants = true) {},
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        stringResource(R.string.managed_safety_location_current),
                        style = NoopType.body,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.managed_safety_location_current_body),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Spacer(Modifier.width(Metrics.space12))
                NoopToggleSwitch(checked = shareLocation, onCheckedChange = null)
            }
            if (
                shareLocation &&
                (!foregroundLocationReady || !managedLocationReady)
            ) {
                NoopButton(
                    text = stringResource(R.string.safety_location_get),
                    leadingIcon = Icons.Filled.LocationOn,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    onClick = onRequestLocation,
                )
                Text(
                    stringResource(R.string.managed_safety_location_needed),
                    style = NoopType.caption,
                    color = Palette.statusWarning,
                )
            }
            if (
                shareLocation &&
                managedLocationReady &&
                !backgroundLocationReady
            ) {
                Text(
                    stringResource(
                        R.string.managed_safety_location_background_body,
                    ),
                    style = NoopType.caption,
                    color = Palette.statusWarning,
                )
                NoopButton(
                    text = stringResource(
                        R.string.managed_safety_location_background_enable,
                    ),
                    leadingIcon = Icons.Filled.MyLocation,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    onClick = onRequestBackgroundLocation,
                )
            }
            NoopButton(
                text = if (state.busy) {
                    stringResource(R.string.managed_safety_working)
                } else {
                    stringResource(R.string.managed_safety_confirm_send)
                },
                leadingIcon = Icons.AutoMirrored.Filled.Send,
                kind = NoopButtonKind.Destructive,
                fullWidth = true,
                enabled = !state.busy &&
                    (contacts?.deliveryCapableCount ?: 0) >= minimum &&
                    activeOwner == null &&
                    locationIncidentReady,
                onClick = { confirmPage = true },
            )
            when {
                (contacts?.deliveryCapableCount ?: 0) < minimum -> Text(
                    stringResource(
                        R.string.managed_safety_threshold_remaining_format,
                        minimum - (contacts?.deliveryCapableCount ?: 0),
                    ),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                activeOwner != null -> Text(
                    stringResource(R.string.safety_page_disabled_active),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                else -> StatePill(
                    stringResource(R.string.managed_safety_threshold_ready),
                    tone = StrandTone.Positive,
                )
            }
            ManagedSafetyIncidents(
                incidents = state.safetyIncidents,
                currentLocation = currentLocation,
                locationReady = managedLocationReady,
                busy = state.busy,
                onRespond = { incident, responding ->
                    scope.launch {
                        service.respondToSafetyIncident(
                            incident.incidentId,
                            responding,
                        )
                    }
                },
                onEnd = { incident, resolved ->
                    scope.launch {
                        service.endSafetyIncident(incident.incidentId, resolved)
                    }
                },
                onRetry = { incident ->
                    scope.launch { service.retrySafetyPush(incident.incidentId) }
                },
                onUpdateLocation = { incident ->
                    val fix = currentLocation
                    val accuracy = fix?.horizontalAccuracyMeters
                    if (fix != null && accuracy != null) {
                        scope.launch {
                            service.updateSafetyLocation(
                                incidentId = incident.incidentId,
                                latitude = fix.latitude,
                                longitude = fix.longitude,
                                horizontalAccuracyM = accuracy,
                                capturedAt = Instant.ofEpochSecond(fix.capturedAtUnix),
                            )
                            service.refreshSafety()
                        }
                    }
                },
                onOpenMap = { incident ->
                    incident.location?.let { fix ->
                        context.startActivity(
                            Intent(
                                Intent.ACTION_VIEW,
                                Uri.parse(
                                    "geo:${fix.latitude},${fix.longitude}" +
                                        "?q=${fix.latitude},${fix.longitude}",
                                ),
                            ),
                        )
                    }
                },
            )
            if (state.safetyStatus.isNotBlank()) {
                Text(
                    state.safetyStatus,
                    style = NoopType.caption,
                    color = Palette.textSecondary,
                )
            }
        }
    }

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
            ManagedSafetyLead()
            if (state.hasPendingSafetyInvite) {
                ManagedPendingSafetyInvite(
                    busy = state.busy,
                    onAccept = {
                        ensureNotifications()
                        scope.launch { service.redeemPendingSafetyInvite() }
                    },
                    onDismiss = service::clearPendingSafetyInvite,
                )
                HorizontalDivider(color = Palette.hairline)
            }

            Text(
                stringResource(R.string.managed_safety_add_by_id),
                style = NoopType.overline,
                color = Palette.textTertiary,
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = noopId,
                    onValueChange = {
                        noopId = it.uppercase(Locale.ROOT).take(24)
                    },
                    placeholder = {
                        Text(stringResource(R.string.managed_safety_noop_id_placeholder))
                    },
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Characters,
                    ),
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    enabled = !state.busy &&
                        ManagedSocialIdentifier.canonicalNoopId(noopId) != null,
                    onClick = {
                        ensureNotifications()
                        val value = noopId
                        noopId = ""
                        scope.launch { service.createSafetyRequest(value) }
                    },
                ) {
                    Icon(
                        Icons.Filled.PersonAdd,
                        contentDescription =
                            stringResource(R.string.managed_safety_add_contact),
                    )
                }
            }

            ManagedSafetyInviteControls(
                hasInvite = state.safetyInvite?.status == "active",
                busy = state.busy,
                onCreate = {
                    ensureNotifications()
                    scope.launch { service.createSafetyInvite() }
                },
                onShare = ::shareInvite,
                onRevoke = { scope.launch { service.revokeSafetyInvite() } },
            )

            ManagedSafetyRequests(
                requests = state.safetyRequests.filter { it.status == "pending" },
                busy = state.busy,
                onDecision = { request, accepted ->
                    if (accepted) ensureNotifications()
                    scope.launch {
                        service.decideSafetyRequest(request.requestId, accepted)
                    }
                },
            )

            ManagedSafetyContacts(
                contacts = contacts?.contacts.orEmpty(),
                outboundCount = contacts?.deliveryCapableCount ?: 0,
                minimum = minimum,
                busy = state.busy,
                onRemove = { contactToRemove = it },
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                NoopButton(
                    text = stringResource(R.string.managed_safety_notification_permission),
                    leadingIcon = Icons.Filled.Notifications,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    onClick = ::ensureNotifications,
                )
            }
        }
    }
}

@Composable
private fun ManagedSafetyLead() {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Shield, contentDescription = null, tint = Palette.accent)
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
            Text(
                stringResource(R.string.managed_safety_app_title),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            Text(
                stringResource(R.string.managed_safety_app_body),
                style = NoopType.body,
                color = Palette.textSecondary,
            )
        }
    }
}

@Composable
private fun ManagedPendingSafetyInvite(
    busy: Boolean,
    onAccept: () -> Unit,
    onDismiss: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        Text(
            stringResource(R.string.managed_safety_invite_pending_title),
            style = NoopType.headline,
            color = Palette.textPrimary,
        )
        Text(
            stringResource(R.string.managed_safety_invite_pending_body),
            style = NoopType.footnote,
            color = Palette.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
            NoopButton(
                text = stringResource(R.string.managed_safety_add_contact),
                leadingIcon = Icons.AutoMirrored.Filled.Send,
                fullWidth = true,
                enabled = !busy,
                modifier = Modifier.weight(1f),
                onClick = onAccept,
            )
            IconButton(onClick = onDismiss, enabled = !busy) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription =
                        stringResource(R.string.managed_safety_dismiss_invite),
                )
            }
        }
    }
}

@Composable
private fun ManagedSafetyInviteControls(
    hasInvite: Boolean,
    busy: Boolean,
    onCreate: () -> Unit,
    onShare: () -> Unit,
    onRevoke: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        Text(
            stringResource(R.string.managed_safety_invite_title),
            style = NoopType.overline,
            color = Palette.textTertiary,
        )
        Text(
            stringResource(R.string.managed_safety_invite_body),
            style = NoopType.footnote,
            color = Palette.textSecondary,
        )
        if (hasInvite) {
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                NoopButton(
                    text = stringResource(R.string.managed_safety_share_invite),
                    leadingIcon = Icons.Filled.Share,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                    onClick = onShare,
                )
                IconButton(onClick = onRevoke, enabled = !busy) {
                    Icon(
                        Icons.Filled.Delete,
                        contentDescription =
                            stringResource(R.string.managed_safety_revoke_invite),
                    )
                }
            }
        } else {
            NoopButton(
                text = stringResource(R.string.managed_safety_create_invite),
                leadingIcon = Icons.Filled.Link,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !busy,
                onClick = onCreate,
            )
        }
    }
}

@Composable
private fun ManagedSafetyRequests(
    requests: List<ManagedSafetyRequest>,
    busy: Boolean,
    onDecision: (ManagedSafetyRequest, Boolean) -> Unit,
) {
    HorizontalDivider(color = Palette.hairline)
    Text(
        stringResource(R.string.managed_safety_pending_requests),
        style = NoopType.overline,
        color = Palette.textTertiary,
    )
    if (requests.isEmpty()) {
        Text(
            stringResource(R.string.managed_safety_requests_empty),
            style = NoopType.footnote,
            color = Palette.textSecondary,
        )
    } else {
        requests.forEachIndexed { index, request ->
            if (index > 0) HorizontalDivider(color = Palette.hairline)
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                Text(
                    if (request.isIncoming) {
                        stringResource(
                            R.string.managed_safety_incoming_request_format,
                            request.displayName,
                        )
                    } else {
                        stringResource(
                            R.string.managed_safety_outgoing_request_format,
                            request.displayName,
                        )
                    },
                    style = NoopType.body,
                    color = Palette.textPrimary,
                )
                if (request.isIncoming) {
                    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                        NoopButton(
                            text = stringResource(R.string.managed_safety_accept),
                            leadingIcon = Icons.Filled.CheckCircle,
                            fullWidth = true,
                            enabled = !busy,
                            modifier = Modifier.weight(1f),
                        ) { onDecision(request, true) }
                        NoopButton(
                            text = stringResource(R.string.managed_safety_decline),
                            kind = NoopButtonKind.Tertiary,
                            fullWidth = true,
                            enabled = !busy,
                            modifier = Modifier.weight(1f),
                        ) { onDecision(request, false) }
                    }
                }
            }
        }
    }
}

@Composable
private fun ManagedSafetyContacts(
    contacts: List<ManagedSafetyContact>,
    outboundCount: Int,
    minimum: Int,
    busy: Boolean,
    onRemove: (ManagedSafetyContact) -> Unit,
) {
    HorizontalDivider(color = Palette.hairline)
    Text(
        stringResource(R.string.managed_safety_contacts_title),
        style = NoopType.overline,
        color = Palette.textTertiary,
    )
    Text(
        stringResource(
            R.string.managed_safety_contact_count_format,
            outboundCount,
            minimum,
        ),
        style = NoopType.caption,
        color = if (outboundCount >= minimum) {
            Palette.statusPositive
        } else {
            Palette.textTertiary
        },
    )
    if (contacts.isEmpty()) {
        Text(
            stringResource(R.string.managed_safety_contact_empty),
            style = NoopType.footnote,
            color = Palette.textSecondary,
        )
    } else {
        contacts.forEachIndexed { index, contact ->
            if (index > 0) HorizontalDivider(color = Palette.hairline)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                ) {
                    Text(
                        contact.displayName,
                        style = NoopType.body,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(
                            if (contact.role == "contact") {
                                R.string.managed_safety_contact_you_page
                            } else {
                                R.string.managed_safety_contact_pages_you
                            },
                        ),
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                }
                IconButton(onClick = { onRemove(contact) }, enabled = !busy) {
                    Icon(
                        Icons.Filled.Delete,
                        contentDescription =
                            stringResource(R.string.managed_safety_remove_contact),
                    )
                }
            }
        }
    }
}

@Composable
private fun ManagedSafetyIncidents(
    incidents: List<ManagedSafetyIncident>,
    currentLocation: SafetyLocation?,
    locationReady: Boolean,
    busy: Boolean,
    onRespond: (ManagedSafetyIncident, Boolean) -> Unit,
    onEnd: (ManagedSafetyIncident, Boolean) -> Unit,
    onRetry: (ManagedSafetyIncident) -> Unit,
    onUpdateLocation: (ManagedSafetyIncident) -> Unit,
    onOpenMap: (ManagedSafetyIncident) -> Unit,
) {
    val active = incidents.filter { it.status == "open" || it.status == "acknowledged" }
    if (active.isEmpty()) {
        incidents.firstOrNull()?.let {
            HorizontalDivider(color = Palette.hairline)
            Text(
                stringResource(
                    R.string.managed_safety_last_closed_format,
                    stringResource(managedSafetyIncidentStatusResource(it.status)),
                ),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
        return
    }
    active.forEach { incident ->
        HorizontalDivider(color = Palette.hairline)
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                ) {
                    Text(
                        if (incident.role == "owner") {
                            stringResource(R.string.managed_safety_role_owner)
                        } else {
                            stringResource(
                                R.string.managed_safety_role_contact_format,
                                incident.ownerDisplayName,
                            )
                        },
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    StatePill(
                        stringResource(
                            if (incident.status == "acknowledged") {
                                R.string.managed_safety_status_acknowledged
                            } else {
                                R.string.managed_safety_status_active
                            },
                        ),
                        tone = if (incident.status == "acknowledged") {
                            StrandTone.Positive
                        } else {
                            StrandTone.Warning
                        },
                    )
                }
            }
            incident.delivery?.let { delivery ->
                Text(
                    stringResource(
                        R.string.managed_safety_delivery_format,
                        delivery.contactsReached,
                        delivery.contactsTargeted,
                        delivery.installationsReached,
                        delivery.installationsTargeted,
                    ),
                    style = NoopType.caption,
                    color = Palette.textSecondary,
                )
            }
            incident.participants.forEach { participant ->
                Text(
                    stringResource(
                        R.string.managed_safety_participant_status_format,
                        participant.displayName,
                        stringResource(
                            managedSafetyParticipantStatusResource(
                                participant.status,
                            ),
                        ),
                    ),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            if (incident.location != null) {
                NoopButton(
                    text = stringResource(R.string.managed_safety_open_maps),
                    leadingIcon = Icons.Filled.LocationOn,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    onClick = { onOpenMap(incident) },
                )
            }
            if (incident.role == "owner") {
                if (incident.shareLocation && currentLocation != null && locationReady) {
                    NoopButton(
                        text = stringResource(R.string.managed_safety_location_update),
                        leadingIcon = Icons.Filled.LocationOn,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !busy,
                        onClick = { onUpdateLocation(incident) },
                    )
                }
                if ((incident.delivery?.installationsRetryable ?: 0) > 0) {
                    NoopButton(
                        text = stringResource(R.string.managed_safety_retry_push),
                        leadingIcon = Icons.Filled.Refresh,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !busy,
                        onClick = { onRetry(incident) },
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    NoopButton(
                        text = stringResource(R.string.managed_safety_resolve_page),
                        leadingIcon = Icons.Filled.CheckCircle,
                        fullWidth = true,
                        enabled = !busy,
                        modifier = Modifier.weight(1f),
                    ) { onEnd(incident, true) }
                    NoopButton(
                        text = stringResource(R.string.managed_safety_cancel_page),
                        kind = NoopButtonKind.Tertiary,
                        fullWidth = true,
                        enabled = !busy,
                        modifier = Modifier.weight(1f),
                    ) { onEnd(incident, false) }
                }
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    NoopButton(
                        text = stringResource(R.string.managed_safety_responding),
                        leadingIcon = Icons.Filled.CheckCircle,
                        fullWidth = true,
                        enabled = !busy,
                        modifier = Modifier.weight(1f),
                    ) { onRespond(incident, true) }
                    NoopButton(
                        text = stringResource(R.string.managed_safety_cannot_respond),
                        kind = NoopButtonKind.Tertiary,
                        fullWidth = true,
                        enabled = !busy,
                        modifier = Modifier.weight(1f),
                    ) { onRespond(incident, false) }
                }
            }
        }
    }
}

internal fun managedSafetyIncidentStatusResource(status: String): Int =
    when (status) {
        "open" -> R.string.managed_safety_status_active
        "acknowledged" -> R.string.managed_safety_status_acknowledged
        "resolved" -> R.string.managed_safety_status_label_resolved
        "canceled" -> R.string.managed_safety_status_label_canceled
        "expired" -> R.string.managed_safety_status_label_expired
        else -> R.string.managed_safety_status_label_unavailable
    }

internal fun managedSafetyParticipantStatusResource(status: String): Int =
    when (status) {
        "pending" -> R.string.managed_safety_participant_status_pending
        "responding" -> R.string.managed_safety_participant_status_responding
        "cannot_respond" ->
            R.string.managed_safety_participant_status_cannot_respond
        "revoked" -> R.string.managed_safety_participant_status_revoked
        else -> R.string.managed_safety_participant_status_unavailable
    }
