@file:OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)

package com.noop.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.automirrored.filled.Message
import androidx.compose.material.icons.filled.Badge
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Vibration
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.AutofillNode
import androidx.compose.ui.autofill.AutofillType
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalAutofill
import androidx.compose.ui.platform.LocalAutofillTree
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.NoopApplication
import com.noop.R
import com.noop.ownership.NoopProductPlan
import com.noop.ownership.OwnershipInstallation
import com.noop.ownership.OwnershipPhase
import com.noop.ownership.OwnershipService
import kotlinx.coroutines.launch
import java.time.Instant

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun OwnershipAccountScreen() {
    val context = LocalContext.current
    val activity = remember(context) { context.ownershipActivity() }
    val service = remember {
        (context.applicationContext as? NoopApplication)?.ownership
            ?: OwnershipService.get(context)
    }
    val state by service.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var createMode by remember { mutableStateOf(true) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var phone by remember { mutableStateOf("") }
    var phoneCode by remember { mutableStateOf("") }
    var acceptedTerms by remember { mutableStateOf(false) }
    var selectedPlan by remember {
        mutableStateOf(state.overview?.plan ?: NoopProductPlan.stored(context))
    }
    var pendingRevocation by remember { mutableStateOf<OwnershipInstallation?>(null) }
    var confirmsLocalReset by remember { mutableStateOf(false) }

    LaunchedEffect(service) {
        service.bootstrap()
    }
    LaunchedEffect(state.overview?.plan) {
        state.overview?.plan?.let { selectedPlan = it }
    }

    LazyScreenScaffold(
        title = stringResource(R.string.ownership_screen_title),
        subtitle = stringResource(R.string.ownership_screen_subtitle),
    ) {
        item {
            when (state.phase) {
                OwnershipPhase.UNAVAILABLE -> OwnershipUnavailableCard()
                OwnershipPhase.LOCAL_RECOVERY_REQUIRED ->
                    OwnershipLocalRecoveryCard(
                        busy = state.busy,
                        onReset = { confirmsLocalReset = true },
                    )
                OwnershipPhase.SIGNED_OUT -> OwnershipAuthenticationCard(
                    createMode = createMode,
                    onCreateModeChange = { createMode = it },
                    terms = state.terms?.text,
                    acceptedTerms = acceptedTerms,
                    onAcceptedTermsChange = { acceptedTerms = it },
                    email = email,
                    onEmailChange = { email = it.take(254) },
                    password = password,
                    onPasswordChange = { password = it.take(128) },
                    confirmation = confirmation,
                    onConfirmationChange = { confirmation = it.take(128) },
                    busy = state.busy,
                    onAuthenticate = {
                        val suppliedPassword = password
                        val suppliedConfirmation = confirmation
                        password = ""
                        confirmation = ""
                        scope.launch {
                            if (createMode) {
                                service.createAccount(
                                    email,
                                    suppliedPassword,
                                    suppliedConfirmation,
                                    acceptedTerms,
                                )
                            } else {
                                service.signIn(email, suppliedPassword)
                            }
                        }
                    },
                    onPasswordReset = {
                        scope.launch { service.sendPasswordReset(email) }
                    },
                    onLoadTerms = {
                        acceptedTerms = false
                        scope.launch {
                            service.loadTerms(forAccountCreation = true)
                        }
                    },
                )
                OwnershipPhase.EMAIL_VERIFICATION -> OwnershipEmailVerificationCard(
                    maskedEmail = state.maskedEmail,
                    busy = state.busy,
                    onCheck = { scope.launch { service.checkEmailVerification() } },
                    onResend = { scope.launch { service.resendEmailVerification() } },
                    onSignOut = service::signOut,
                )
                OwnershipPhase.TERMS_REVIEW -> OwnershipTermsCard(
                    terms = state.terms?.text,
                    accepted = acceptedTerms,
                    onAcceptedChange = { acceptedTerms = it },
                    busy = state.busy,
                    onLoad = {
                        acceptedTerms = false
                        scope.launch { service.loadTerms() }
                    },
                    onAccept = {
                        scope.launch { service.acceptTermsAndRegister() }
                    },
                    onSignOut = service::signOut,
                )
                OwnershipPhase.REGISTERING -> OwnershipProgressCard(
                    title = stringResource(R.string.ownership_registering_title),
                    detail = stringResource(R.string.ownership_registering_detail),
                )
                OwnershipPhase.CLAIMING -> OwnershipProgressCard(
                    title = stringResource(R.string.ownership_claiming_title),
                    detail = stringResource(R.string.ownership_claiming_detail),
                )
                OwnershipPhase.REPLACEMENT_REQUIRED -> OwnershipReplacementCard(
                    possessionAvailable = service.possessionAvailable,
                    busy = state.busy,
                    onAuthorize = {
                        scope.launch { service.authorizeReplacementPhone() }
                    },
                    onSignOut = service::signOut,
                )
                OwnershipPhase.AUTHORIZING_REPLACEMENT -> OwnershipProgressCard(
                    title = stringResource(R.string.ownership_replacement_working_title),
                    detail = stringResource(R.string.ownership_replacement_working_detail),
                )
                OwnershipPhase.ACCOUNT_READY,
                OwnershipPhase.POSSESSION_UNAVAILABLE,
                OwnershipPhase.CLAIMED,
                OwnershipPhase.COMPLETE,
                -> OwnershipAccountCard(
                    state = state,
                    selectedPlan = selectedPlan,
                    onPlanChange = { selectedPlan = it },
                    onClaim = { scope.launch { service.claimBand() } },
                    onSavePlan = {
                        scope.launch { service.selectPlan(selectedPlan) }
                    },
                )
            }
        }

        if (
            state.phase in setOf(
                OwnershipPhase.ACCOUNT_READY,
                OwnershipPhase.POSSESSION_UNAVAILABLE,
                OwnershipPhase.CLAIMED,
                OwnershipPhase.COMPLETE,
            )
        ) {
            item {
                OwnershipPhoneCard(
                    verified = state.overview?.phoneVerified == true,
                    phone = phone,
                    onPhoneChange = { phone = it.take(24) },
                    code = phoneCode,
                    onCodeChange = { phoneCode = it.filter(Char::isDigit).take(6) },
                    busy = state.busy,
                    activityAvailable = activity != null,
                    onSend = {
                        activity?.let { owner ->
                            scope.launch { service.sendPhoneCode(owner, phone) }
                        }
                    },
                    onVerify = {
                        val suppliedCode = phoneCode
                        phoneCode = ""
                        scope.launch { service.linkPhone(suppliedCode) }
                    },
                )
            }
            if (state.installations.any { it.status == "active" }) {
                item {
                    OwnershipInstallationsCard(
                        installations = state.installations.filter { it.status == "active" },
                        busy = state.busy,
                        onRevoke = { pendingRevocation = it },
                    )
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    NoopButton(
                        text = if (state.busy) {
                            stringResource(R.string.ownership_refreshing)
                        } else {
                            stringResource(R.string.ownership_refresh)
                        },
                        leadingIcon = Icons.Filled.Refresh,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = { scope.launch { service.refreshOverview() } },
                    )
                    NoopButton(
                        text = stringResource(R.string.ownership_sign_out),
                        leadingIcon = Icons.AutoMirrored.Filled.Logout,
                        kind = NoopButtonKind.Tertiary,
                        fullWidth = true,
                        enabled = !state.busy,
                        onClick = service::signOut,
                    )
                }
            }
        }

        if (state.status.isNotBlank()) {
            item {
                Text(
                    text = state.status,
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }
        item { OwnershipLocalBoundary() }
    }

    pendingRevocation?.let { installation ->
        AlertDialog(
            onDismissRequest = { if (!state.busy) pendingRevocation = null },
            title = { Text(stringResource(R.string.ownership_revoke_title)) },
            text = { Text(stringResource(R.string.ownership_revoke_detail)) },
            confirmButton = {
                TextButton(
                    enabled = !state.busy,
                    onClick = {
                        pendingRevocation = null
                        scope.launch { service.revokeInstallation(installation) }
                    },
                ) {
                    Text(
                        stringResource(R.string.ownership_revoke),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(
                    enabled = !state.busy,
                    onClick = { pendingRevocation = null },
                ) {
                    Text(stringResource(R.string.ownership_cancel))
                }
            },
            containerColor = Palette.surfaceOverlay,
        )
    }
    if (confirmsLocalReset) {
        AlertDialog(
            onDismissRequest = {
                if (!state.busy) confirmsLocalReset = false
            },
            title = {
                Text(stringResource(R.string.ownership_local_reset_title))
            },
            text = {
                Text(stringResource(R.string.ownership_local_reset_confirmation))
            },
            confirmButton = {
                TextButton(
                    enabled = !state.busy,
                    onClick = {
                        confirmsLocalReset = false
                        service.resetLocalOwnershipSetup()
                    },
                ) {
                    Text(
                        stringResource(R.string.ownership_local_reset_action),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(
                    enabled = !state.busy,
                    onClick = { confirmsLocalReset = false },
                ) {
                    Text(stringResource(R.string.ownership_cancel))
                }
            },
            containerColor = Palette.surfaceOverlay,
        )
    }
}

@Composable
private fun OwnershipUnavailableCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OwnershipHeader(
                icon = Icons.Filled.Lock,
                title = stringResource(R.string.ownership_unavailable_title),
                detail = stringResource(R.string.ownership_unavailable_detail),
            )
            Text(
                stringResource(R.string.ownership_unavailable_sdk_detail),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun OwnershipLocalRecoveryCard(
    busy: Boolean,
    onReset: () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OwnershipHeader(
                icon = Icons.Filled.Key,
                title = stringResource(R.string.ownership_local_recovery_title),
                detail = stringResource(R.string.ownership_local_recovery_detail),
            )
            Text(
                stringResource(R.string.ownership_local_recovery_boundary),
                style = NoopType.caption,
                color = Palette.textSecondary,
            )
            NoopButton(
                text = stringResource(R.string.ownership_local_reset_action),
                leadingIcon = Icons.Filled.Refresh,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !busy,
                onClick = onReset,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OwnershipAuthenticationCard(
    createMode: Boolean,
    onCreateModeChange: (Boolean) -> Unit,
    terms: String?,
    acceptedTerms: Boolean,
    onAcceptedTermsChange: (Boolean) -> Unit,
    email: String,
    onEmailChange: (String) -> Unit,
    password: String,
    onPasswordChange: (String) -> Unit,
    confirmation: String,
    onConfirmationChange: (String) -> Unit,
    busy: Boolean,
    onAuthenticate: () -> Unit,
    onPasswordReset: () -> Unit,
    onLoadTerms: () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OwnershipHeader(
                icon = Icons.Filled.Key,
                title = stringResource(
                    if (createMode) {
                        R.string.ownership_create_title
                    } else {
                        R.string.ownership_sign_in_title
                    },
                ),
                detail = stringResource(R.string.ownership_credentials_detail),
            )
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                listOf(true, false).forEachIndexed { index, create ->
                    SegmentedButton(
                        selected = createMode == create,
                        onClick = { onCreateModeChange(create) },
                        enabled = !busy,
                        shape = SegmentedButtonDefaults.itemShape(index, 2),
                        label = {
                            Text(
                                stringResource(
                                    if (create) {
                                        R.string.ownership_create
                                    } else {
                                        R.string.ownership_sign_in
                                    },
                                ),
                            )
                        },
                    )
                }
            }
            if (createMode) {
                if (terms == null) {
                    NoopButton(
                        text = if (busy) {
                            stringResource(R.string.ownership_loading)
                        } else {
                            stringResource(R.string.ownership_load_terms)
                        },
                        leadingIcon = Icons.Filled.Security,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = !busy,
                        onClick = onLoadTerms,
                    )
                } else {
                    Text(
                        stringResource(R.string.ownership_terms_before_account),
                        style = NoopType.caption,
                        color = Palette.textSecondary,
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 150.dp, max = 240.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(Palette.surfaceInset)
                            .verticalScroll(rememberScrollState())
                            .padding(12.dp)
                            .testTag("noop.ownership.pre_account_terms"),
                    ) {
                        SelectionContainer {
                            Text(
                                terms,
                                style = NoopType.body,
                                color = Palette.textPrimary,
                            )
                        }
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Checkbox(
                            checked = acceptedTerms,
                            onCheckedChange = onAcceptedTermsChange,
                            enabled = !busy,
                            colors = CheckboxDefaults.colors(
                                checkedColor = Palette.accent,
                                uncheckedColor = Palette.textTertiary,
                                checkmarkColor = Palette.accentInk,
                            ),
                        )
                        Text(
                            stringResource(R.string.ownership_terms_agree),
                            style = NoopType.body,
                            color = Palette.textPrimary,
                        )
                    }
                }
            }
            OwnershipTextField(
                value = email,
                onValueChange = onEmailChange,
                label = stringResource(R.string.ownership_email),
                keyboardType = KeyboardType.Email,
                autofillType = AutofillType.EmailAddress,
                enabled = !busy,
                modifier = Modifier.testTag("noop.ownership.email"),
            )
            OwnershipTextField(
                value = password,
                onValueChange = onPasswordChange,
                label = stringResource(R.string.ownership_password),
                keyboardType = KeyboardType.Password,
                password = true,
                autofillType = if (createMode) {
                    AutofillType.NewPassword
                } else {
                    AutofillType.Password
                },
                enabled = !busy,
                modifier = Modifier.testTag("noop.ownership.password"),
            )
            if (createMode) {
                OwnershipTextField(
                    value = confirmation,
                    onValueChange = onConfirmationChange,
                    label = stringResource(R.string.ownership_confirm_password),
                    keyboardType = KeyboardType.Password,
                    password = true,
                    autofillType = AutofillType.NewPassword,
                    enabled = !busy,
                    modifier = Modifier.testTag("noop.ownership.password_confirmation"),
                )
            }
            NoopButton(
                text = if (busy) {
                    stringResource(R.string.ownership_working)
                } else {
                    stringResource(
                        if (createMode) {
                            R.string.ownership_create
                        } else {
                            R.string.ownership_sign_in
                        },
                    )
                },
                leadingIcon = if (createMode) Icons.Filled.Badge else Icons.Filled.Security,
                fullWidth = true,
                enabled = !busy &&
                    email.isNotBlank() &&
                    password.isNotBlank() &&
                    (
                        !createMode ||
                            (
                                confirmation.isNotBlank() &&
                                    terms != null &&
                                    acceptedTerms
                                )
                        ),
                modifier = Modifier.testTag("noop.ownership.authenticate"),
                onClick = onAuthenticate,
            )
            TextButton(
                enabled = !busy && email.isNotBlank(),
                onClick = onPasswordReset,
            ) {
                Text(
                    stringResource(R.string.ownership_password_reset),
                    color = Palette.accent,
                )
            }
        }
    }
}

@Composable
private fun OwnershipEmailVerificationCard(
    maskedEmail: String,
    busy: Boolean,
    onCheck: () -> Unit,
    onResend: () -> Unit,
    onSignOut: () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OwnershipHeader(
                icon = Icons.Filled.Email,
                title = stringResource(R.string.ownership_verify_email_title),
                detail = if (maskedEmail.isBlank()) {
                    stringResource(R.string.ownership_verify_email_detail)
                } else {
                    stringResource(R.string.ownership_verify_email_masked, maskedEmail)
                },
            )
            NoopButton(
                text = if (busy) {
                    stringResource(R.string.ownership_checking)
                } else {
                    stringResource(R.string.ownership_email_verified_action)
                },
                leadingIcon = Icons.Filled.CheckCircle,
                fullWidth = true,
                enabled = !busy,
                onClick = onCheck,
            )
            NoopButton(
                text = stringResource(R.string.ownership_resend_verification),
                leadingIcon = Icons.Filled.Refresh,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !busy,
                onClick = onResend,
            )
            NoopButton(
                text = stringResource(R.string.ownership_sign_out),
                leadingIcon = Icons.AutoMirrored.Filled.Logout,
                kind = NoopButtonKind.Tertiary,
                fullWidth = true,
                enabled = !busy,
                onClick = onSignOut,
            )
        }
    }
}

@Composable
private fun OwnershipTermsCard(
    terms: String?,
    accepted: Boolean,
    onAcceptedChange: (Boolean) -> Unit,
    busy: Boolean,
    onLoad: () -> Unit,
    onAccept: () -> Unit,
    onSignOut: () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OwnershipHeader(
                icon = Icons.Filled.Security,
                title = stringResource(R.string.ownership_terms_title),
                detail = stringResource(R.string.ownership_terms_detail),
            )
            if (terms == null) {
                NoopButton(
                    text = if (busy) {
                        stringResource(R.string.ownership_loading)
                    } else {
                        stringResource(R.string.ownership_load_terms)
                    },
                    leadingIcon = Icons.Filled.Refresh,
                    fullWidth = true,
                    enabled = !busy,
                    onClick = onLoad,
                )
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 180.dp, max = 320.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(Palette.surfaceInset)
                        .verticalScroll(rememberScrollState())
                        .padding(12.dp)
                        .testTag("noop.ownership.terms"),
                ) {
                    SelectionContainer {
                        Text(
                            terms,
                            style = NoopType.body,
                            color = Palette.textPrimary,
                        )
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Checkbox(
                        checked = accepted,
                        onCheckedChange = onAcceptedChange,
                        enabled = !busy,
                        colors = CheckboxDefaults.colors(
                            checkedColor = Palette.statusPositive,
                        ),
                    )
                    Text(
                        stringResource(R.string.ownership_terms_agree),
                        style = NoopType.body,
                        color = Palette.textPrimary,
                    )
                }
                NoopButton(
                    text = if (busy) {
                        stringResource(R.string.ownership_registering)
                    } else {
                        stringResource(R.string.ownership_agree_continue)
                    },
                    leadingIcon = Icons.Filled.CheckCircle,
                    fullWidth = true,
                    enabled = !busy && accepted,
                    modifier = Modifier.testTag("noop.ownership.accept_terms"),
                    onClick = onAccept,
                )
            }
            NoopButton(
                text = stringResource(R.string.ownership_sign_out),
                leadingIcon = Icons.AutoMirrored.Filled.Logout,
                kind = NoopButtonKind.Tertiary,
                fullWidth = true,
                enabled = !busy,
                onClick = onSignOut,
            )
        }
    }
}

@Composable
private fun OwnershipProgressCard(title: String, detail: String) {
    NoopCard(padding = 20.dp) {
        OwnershipHeader(
            icon = Icons.Filled.Refresh,
            title = title,
            detail = detail,
        )
    }
}

@Composable
private fun OwnershipReplacementCard(
    possessionAvailable: Boolean,
    busy: Boolean,
    onAuthorize: () -> Unit,
    onSignOut: () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OwnershipHeader(
                icon = Icons.Filled.PhoneAndroid,
                title = stringResource(R.string.ownership_replacement_title),
                detail = stringResource(R.string.ownership_replacement_detail),
            )
            if (possessionAvailable) {
                NoopButton(
                    text = stringResource(R.string.ownership_replacement_action),
                    leadingIcon = Icons.Filled.Vibration,
                    fullWidth = true,
                    enabled = !busy,
                    onClick = onAuthorize,
                )
            } else {
                Text(
                    stringResource(R.string.ownership_replacement_sdk_pending),
                    style = NoopType.caption,
                    color = Palette.statusWarning,
                )
            }
            NoopButton(
                text = stringResource(R.string.ownership_sign_out),
                leadingIcon = Icons.AutoMirrored.Filled.Logout,
                kind = NoopButtonKind.Tertiary,
                fullWidth = true,
                enabled = !busy,
                onClick = onSignOut,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OwnershipAccountCard(
    state: com.noop.ownership.OwnershipState,
    selectedPlan: NoopProductPlan,
    onPlanChange: (NoopProductPlan) -> Unit,
    onClaim: () -> Unit,
    onSavePlan: () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val claimed = state.overview?.bandState == "claimed"
            OwnershipHeader(
                icon = if (claimed) Icons.Filled.CheckCircle else Icons.Filled.Key,
                title = stringResource(R.string.ownership_account_title),
                detail = stringResource(
                    if (claimed) {
                        R.string.ownership_account_claimed_detail
                    } else {
                        R.string.ownership_account_ready_detail
                    },
                ),
            )
            if (!claimed && state.phase == OwnershipPhase.ACCOUNT_READY) {
                NoopButton(
                    text = stringResource(R.string.ownership_confirm_band),
                    leadingIcon = Icons.Filled.Vibration,
                    fullWidth = true,
                    enabled = !state.busy,
                    onClick = onClaim,
                )
            } else if (!claimed) {
                Text(
                    stringResource(R.string.ownership_possession_locked),
                    style = NoopType.caption,
                    color = Palette.statusWarning,
                )
            }
            Text(
                stringResource(R.string.ownership_product_label),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                NoopProductPlan.entries.forEachIndexed { index, plan ->
                    SegmentedButton(
                        selected = selectedPlan == plan,
                        onClick = { onPlanChange(plan) },
                        enabled = !state.busy,
                        shape = SegmentedButtonDefaults.itemShape(
                            index,
                            NoopProductPlan.entries.size,
                        ),
                        icon = {
                            Icon(
                                if (plan == NoopProductPlan.NOOP) {
                                    Icons.Filled.Smartphone
                                } else {
                                    Icons.Filled.Star
                                },
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                        },
                        label = {
                            Text(
                                stringResource(
                                    if (plan == NoopProductPlan.NOOP) {
                                        R.string.ownership_plan_noop_title
                                    } else {
                                        R.string.ownership_plan_plus_title
                                    },
                                ),
                            )
                        },
                    )
                }
            }
            NoopButton(
                text = stringResource(R.string.ownership_save_preference),
                leadingIcon = Icons.Filled.CheckCircle,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !state.busy,
                onClick = onSavePlan,
            )
            Text(
                stringResource(R.string.ownership_payment_unavailable),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun OwnershipPhoneCard(
    verified: Boolean,
    phone: String,
    onPhoneChange: (String) -> Unit,
    code: String,
    onCodeChange: (String) -> Unit,
    busy: Boolean,
    activityAvailable: Boolean,
    onSend: () -> Unit,
    onVerify: () -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                stringResource(R.string.ownership_phone_title),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            if (verified) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = Palette.statusPositive,
                    )
                    Text(
                        stringResource(R.string.ownership_phone_verified_label),
                        style = NoopType.body,
                        color = Palette.statusPositive,
                    )
                }
            } else {
                OwnershipTextField(
                    value = phone,
                    onValueChange = onPhoneChange,
                    label = stringResource(R.string.ownership_phone),
                    keyboardType = KeyboardType.Phone,
                    autofillType = AutofillType.PhoneNumber,
                    enabled = !busy,
                )
                NoopButton(
                    text = stringResource(R.string.ownership_send_code),
                    leadingIcon = Icons.AutoMirrored.Filled.Message,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = !busy && activityAvailable && phone.isNotBlank(),
                    onClick = onSend,
                )
                OwnershipTextField(
                    value = code,
                    onValueChange = onCodeChange,
                    label = stringResource(R.string.ownership_code),
                    keyboardType = KeyboardType.NumberPassword,
                    autofillType = AutofillType.SmsOtpCode,
                    enabled = !busy,
                )
                NoopButton(
                    text = stringResource(R.string.ownership_verify_phone),
                    leadingIcon = Icons.Filled.Security,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = !busy && code.length == 6,
                    onClick = onVerify,
                )
            }
        }
    }
}

@Composable
private fun OwnershipInstallationsCard(
    installations: List<OwnershipInstallation>,
    busy: Boolean,
    onRevoke: (OwnershipInstallation) -> Unit,
) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                stringResource(R.string.ownership_installations_title),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            installations.forEach { installation ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        if (installation.platform == "ios") {
                            Icons.Filled.PhoneIphone
                        } else {
                            Icons.Filled.PhoneAndroid
                        },
                        contentDescription = null,
                        tint = if (installation.current) {
                            Palette.statusPositive
                        } else {
                            Palette.textSecondary
                        },
                        modifier = Modifier.size(22.dp),
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            stringResource(
                                if (installation.current) {
                                    R.string.ownership_this_phone
                                } else {
                                    R.string.ownership_authorized_phone
                                },
                            ),
                            style = NoopType.body,
                            color = Palette.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            stringResource(
                                R.string.ownership_last_seen,
                                ownershipRelativeTime(installation.lastSeenAt),
                            ),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                    if (!installation.current) {
                        TextButton(
                            enabled = !busy,
                            onClick = { onRevoke(installation) },
                        ) {
                            Text(
                                stringResource(R.string.ownership_revoke),
                                color = Palette.statusCritical,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun OwnershipHeader(
    icon: ImageVector,
    title: String,
    detail: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Palette.surfaceInset),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(23.dp),
            )
        }
        Text(title, style = NoopType.title2, color = Palette.textPrimary)
        Text(detail, style = NoopType.body, color = Palette.textSecondary)
    }
}

@Composable
private fun OwnershipTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    keyboardType: KeyboardType,
    enabled: Boolean,
    password: Boolean = false,
    autofillType: AutofillType? = null,
    modifier: Modifier = Modifier,
) {
    val fieldModifier = if (autofillType == null) {
        modifier
    } else {
        modifier.ownershipAutofill(
            autofillType = autofillType,
            onFill = onValueChange,
        )
    }
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        enabled = enabled,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        visualTransformation = if (password) {
            PasswordVisualTransformation()
        } else {
            androidx.compose.ui.text.input.VisualTransformation.None
        },
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = Palette.textPrimary,
            unfocusedTextColor = Palette.textPrimary,
            focusedBorderColor = Palette.accent,
            unfocusedBorderColor = Palette.hairlineStrong,
            focusedLabelColor = Palette.accent,
            unfocusedLabelColor = Palette.textTertiary,
            cursorColor = Palette.accent,
        ),
        modifier = fieldModifier.fillMaxWidth(),
    )
}

@Suppress("DEPRECATION")
@Composable
private fun Modifier.ownershipAutofill(
    autofillType: AutofillType,
    onFill: (String) -> Unit,
): Modifier {
    val autofill = LocalAutofill.current
    val autofillTree = LocalAutofillTree.current
    val currentOnFill by rememberUpdatedState(onFill)
    val node = remember(autofillType) {
        AutofillNode(
            autofillTypes = listOf(autofillType),
            onFill = { currentOnFill(it) },
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

@Composable
private fun OwnershipLocalBoundary() {
    Text(
        stringResource(R.string.ownership_local_boundary),
        style = NoopType.caption,
        color = Palette.textTertiary,
    )
}

@Composable
private fun ownershipRelativeTime(raw: String): String {
    val fallback = stringResource(R.string.ownership_recently)
    return runCatching {
        DateUtils.getRelativeTimeSpanString(Instant.parse(raw).toEpochMilli())
            .toString()
    }.getOrDefault(fallback)
}

private tailrec fun Context.ownershipActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.ownershipActivity()
    else -> null
}
