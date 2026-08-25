package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.safety.SafetyContactStatus
import com.noop.safety.SafetyDeliveryStatus
import com.noop.safety.SafetyPagingContact
import com.noop.safety.SafetyPagingController
import com.noop.safety.SafetyPagingSetupState
import kotlinx.coroutines.launch

/**
 * Shared emergency-contact enrollment surface for onboarding and Safety Center.
 *
 * Contact acceptance is authoritative on the user's self-hosted server. A saved phone number does not
 * count toward the two-person threshold until its recipient explicitly accepts the one-time invitation.
 */
@Composable
internal fun SafetyContactsSetup(
    controller: SafetyPagingController,
    marksReminderNeeded: Boolean = true,
) {
    val scope = rememberCoroutineScope()
    var ownerName by remember { mutableStateOf("") }
    var contactName by remember { mutableStateOf("") }
    var contactPhone by remember { mutableStateOf("") }
    var contactToRemove by remember { mutableStateOf<SafetyPagingContact?>(null) }

    LaunchedEffect(controller, marksReminderNeeded) {
        if (marksReminderNeeded) controller.markSetupPresented()
        controller.refresh()
    }

    controller.errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = controller::dismissError,
            title = { Text(stringResource(R.string.safety_setup_title)) },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = controller::dismissError) {
                    Text(stringResource(R.string.safety_ok))
                }
            },
        )
    }

    contactToRemove?.let { contact ->
        AlertDialog(
            onDismissRequest = { contactToRemove = null },
            title = { Text(stringResource(R.string.safety_contact_remove_title)) },
            text = {
                Text(
                    stringResource(
                        R.string.safety_contact_remove_body_format,
                        contact.displayName,
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        contactToRemove = null
                        scope.launch { controller.remove(contact) }
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

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(Metrics.space16),
    ) {
        when (controller.setupState) {
            SafetyPagingSetupState.NEEDS_SERVER -> {
                SetupMessage(
                    icon = Icons.Filled.Shield,
                    title = stringResource(R.string.safety_network_unavailable_title),
                    body = stringResource(R.string.safety_network_unavailable_body),
                    tone = StrandTone.Warning,
                )
                StatePill(
                    stringResource(R.string.safety_setup_required),
                    tone = StrandTone.Warning,
                )
            }

            SafetyPagingSetupState.NEEDS_ENROLLMENT -> {
                SetupMessage(
                    icon = Icons.Filled.Shield,
                    title = stringResource(R.string.safety_enrollment_title),
                    body = stringResource(R.string.safety_enrollment_body),
                    tone = StrandTone.Accent,
                )
                OutlinedTextField(
                    value = ownerName,
                    onValueChange = { ownerName = it.take(64) },
                    label = { Text(stringResource(R.string.safety_owner_name)) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !controller.isBusy,
                    singleLine = true,
                    colors = safetySetupFieldColors(),
                )
                NoopButton(
                    text = if (controller.isBusy) {
                        stringResource(R.string.safety_enrollment_activating)
                    } else {
                        stringResource(R.string.safety_enrollment_activate)
                    },
                    leadingIcon = Icons.Filled.Shield,
                    kind = NoopButtonKind.Primary,
                    fullWidth = true,
                    enabled = !controller.isBusy && ownerName.trim().isNotEmpty(),
                ) {
                    scope.launch { controller.bootstrap(ownerName) }
                }
            }

            SafetyPagingSetupState.READY -> {
                SafetyReadinessHeader(controller)

                if (!controller.pagingConfigured || controller.pagingEnabled == false) {
                    SetupMessage(
                        icon = Icons.Filled.Warning,
                        title = stringResource(R.string.safety_network_unavailable_title),
                        body = stringResource(R.string.safety_delivery_unavailable),
                        tone = StrandTone.Warning,
                    )
                }

                if (controller.contacts.isEmpty()) {
                    Text(
                        stringResource(R.string.safety_contacts_empty),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                } else {
                    Column(modifier = Modifier.fillMaxWidth()) {
                        controller.contacts.forEachIndexed { index, contact ->
                            SafetyContactRow(
                                contact = contact,
                                busy = controller.isBusy,
                                onResend = { scope.launch { controller.resend(contact) } },
                                onRemove = { contactToRemove = contact },
                            )
                            if (index != controller.contacts.lastIndex) {
                                HorizontalDivider(color = Palette.hairline)
                            }
                        }
                    }
                }

                if (controller.contacts.size < controller.maximumContacts) {
                    HorizontalDivider(color = Palette.hairline)
                    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
                        Text(
                            stringResource(R.string.safety_contact_invite_title),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        OutlinedTextField(
                            value = contactName,
                            onValueChange = { contactName = it.take(64) },
                            label = { Text(stringResource(R.string.safety_contact_name)) },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !controller.isBusy,
                            singleLine = true,
                            colors = safetySetupFieldColors(),
                        )
                        OutlinedTextField(
                            value = contactPhone,
                            onValueChange = { contactPhone = it.take(24) },
                            label = { Text(stringResource(R.string.safety_contact_phone)) },
                            supportingText = {
                                Text(stringResource(R.string.safety_contact_phone_help))
                            },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !controller.isBusy,
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
                            colors = safetySetupFieldColors(),
                        )
                        Text(
                            stringResource(R.string.safety_contact_invitation_help),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                        NoopButton(
                            text = if (controller.isBusy) {
                                stringResource(R.string.safety_contact_invitation_sending)
                            } else {
                                stringResource(R.string.safety_contact_invitation_send)
                            },
                            leadingIcon = Icons.Filled.PersonAdd,
                            kind = NoopButtonKind.Secondary,
                            fullWidth = true,
                            enabled = !controller.isBusy &&
                                controller.pagingConfigured &&
                                controller.pagingEnabled != false &&
                                contactName.trim().isNotEmpty() &&
                                contactPhone.trim().isNotEmpty(),
                        ) {
                            scope.launch {
                                if (controller.addContact(contactName, contactPhone)) {
                                    contactName = ""
                                    contactPhone = ""
                                }
                            }
                        }
                    }
                } else {
                    Text(
                        stringResource(R.string.safety_contacts_maximum),
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                }
            }
        }

        if (controller.isBusy) {
            StatePill(
                stringResource(R.string.safety_setup_updating),
                tone = StrandTone.Accent,
                pulsing = true,
            )
        } else if (controller.statusMessage.isNotBlank()) {
            Text(
                controller.statusMessage,
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
    }
}

@Composable
private fun SafetyReadinessHeader(controller: SafetyPagingController) {
    val scope = rememberCoroutineScope()
    val ready = controller.acceptedCount >= SafetyPagingController.MINIMUM_ACCEPTED
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
    ) {
        Icon(
            if (ready) Icons.Filled.CheckCircle else Icons.Filled.Schedule,
            contentDescription = null,
            tint = if (ready) Palette.statusPositive else Palette.statusWarning,
            modifier = Modifier.size(28.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(Metrics.space4),
        ) {
            Text(
                stringResource(
                    R.string.safety_contacts_accepted_count_format,
                    controller.acceptedCount,
                    SafetyPagingController.MINIMUM_ACCEPTED,
                ),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            Text(
                if (ready) {
                    stringResource(R.string.safety_contacts_threshold_complete)
                } else if (controller.remainingAcceptedContacts == 1) {
                    stringResource(R.string.safety_contacts_acceptance_one)
                } else {
                    stringResource(
                        R.string.safety_contacts_acceptances_format,
                        controller.remainingAcceptedContacts,
                    )
                },
                style = NoopType.caption,
                color = Palette.textSecondary,
            )
        }
        androidx.compose.material3.IconButton(
            onClick = { scope.launch { controller.refresh() } },
            enabled = !controller.isBusy,
        ) {
            Icon(
                Icons.Filled.Refresh,
                contentDescription = stringResource(R.string.safety_contacts_refresh),
                tint = Palette.textSecondary,
            )
        }
    }
}

@Composable
private fun SafetyContactRow(
    contact: SafetyPagingContact,
    busy: Boolean,
    onResend: () -> Unit,
    onRemove: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = Metrics.space12),
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        ) {
            Icon(
                if (contact.status == SafetyContactStatus.ACCEPTED) {
                    Icons.Filled.CheckCircle
                } else {
                    Icons.Filled.Schedule
                },
                contentDescription = null,
                tint = if (contact.status == SafetyContactStatus.ACCEPTED) {
                    Palette.statusPositive
                } else {
                    Palette.statusWarning
                },
                modifier = Modifier.size(24.dp),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    contact.displayName,
                    style = NoopType.body,
                    color = Palette.textPrimary,
                )
                Text(
                    contact.phoneE164,
                    style = NoopType.captionNumber,
                    color = Palette.textSecondary,
                )
                if (
                    contact.invitationDeliveryStatus == SafetyDeliveryStatus.FAILED &&
                    !contact.invitationError.isNullOrBlank()
                ) {
                    Text(
                        contact.invitationError,
                        style = NoopType.caption,
                        color = Palette.statusCritical,
                        maxLines = 2,
                    )
                }
            }
            StatePill(
                safetyContactStatusLabel(contact.status),
                tone = contact.status.tone,
                showsDot = contact.status == SafetyContactStatus.ACCEPTED,
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (contact.status != SafetyContactStatus.ACCEPTED) {
                TextButton(onClick = onResend, enabled = !busy) {
                    Icon(
                        Icons.AutoMirrored.Filled.Send,
                        contentDescription = null,
                        modifier = Modifier.size(17.dp),
                    )
                    Spacer(Modifier.width(Metrics.space4))
                    Text(stringResource(R.string.safety_contact_resend))
                }
            }
            TextButton(onClick = onRemove, enabled = !busy) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = null,
                    modifier = Modifier.size(17.dp),
                )
                Spacer(Modifier.width(Metrics.space4))
                Text(
                    stringResource(R.string.safety_remove),
                    color = Palette.statusCritical,
                )
            }
        }
    }
}

@Composable
private fun SetupMessage(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    body: String,
    tone: StrandTone,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = tone.color,
            modifier = Modifier.size(24.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(Metrics.space4),
        ) {
            Text(title, style = NoopType.headline, color = Palette.textPrimary)
            Text(body, style = NoopType.body, color = Palette.textSecondary)
        }
    }
}

@Composable
private fun safetyContactStatusLabel(status: SafetyContactStatus): String =
    when (status) {
        SafetyContactStatus.PENDING ->
            stringResource(R.string.safety_contact_status_pending)
        SafetyContactStatus.ACCEPTED ->
            stringResource(R.string.safety_contact_status_accepted)
        SafetyContactStatus.DECLINED ->
            stringResource(R.string.safety_contact_status_declined)
        SafetyContactStatus.EXPIRED ->
            stringResource(R.string.safety_contact_status_expired)
    }

private val SafetyContactStatus.tone: StrandTone
    get() = when (this) {
        SafetyContactStatus.ACCEPTED -> StrandTone.Positive
        SafetyContactStatus.PENDING -> StrandTone.Warning
        SafetyContactStatus.DECLINED, SafetyContactStatus.EXPIRED -> StrandTone.Neutral
    }

@Composable
private fun safetySetupFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
    focusedLabelColor = Palette.textSecondary,
    unfocusedLabelColor = Palette.textTertiary,
    focusedSupportingTextColor = Palette.textTertiary,
    unfocusedSupportingTextColor = Palette.textTertiary,
)
