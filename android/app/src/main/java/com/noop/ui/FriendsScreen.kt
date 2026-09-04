package com.noop.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Numbers
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.noop.R
import com.noop.social.FriendContact
import com.noop.social.FriendDailySummary
import com.noop.social.FriendInvite
import com.noop.social.FriendRequest
import com.noop.social.FriendVisibility
import com.noop.social.FriendsSetupState
import java.text.NumberFormat
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.delay

/**
 * Private, invitation-only sharing through the user's self-hosted Noop server.
 *
 * There is deliberately no discovery, follower count, rank, or leaderboard here. Every relationship
 * is accepted, every field is directional, and only six daily summary scalars can reach this surface.
 */
@Composable
internal fun FriendsScreen(
    onOpenBackupSync: () -> Unit,
    vm: FriendsViewModel = viewModel(),
) {
    val context = LocalContext.current
    val state by vm.state.collectAsStateWithLifecycle()
    var displayName by rememberSaveable { mutableStateOf(state.profileName) }
    var showJoin by rememberSaveable { mutableStateOf(false) }
    var selectedFriend by remember { mutableStateOf<FriendContact?>(null) }
    var removeCandidate by remember { mutableStateOf<FriendContact?>(null) }
    var confirmLeave by rememberSaveable { mutableStateOf(false) }
    var confirmDiscardPending by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(Unit) { vm.onEnter() }
    LaunchedEffect(state.profileName) {
        if (displayName.isBlank() && state.profileName.isNotBlank()) {
            displayName = state.profileName
        }
    }
    LaunchedEffect(state.notice) {
        if (state.notice != null) {
            delay(5_000L)
            vm.dismissNotice()
        }
    }

    state.error?.let { error ->
        AlertDialog(
            onDismissRequest = vm::dismissError,
            title = { Text(stringResource(R.string.friends_error_title)) },
            text = { Text(friendsErrorText(error)) },
            confirmButton = {
                TextButton(onClick = vm::dismissError) {
                    Text(stringResource(R.string.friends_action_ok))
                }
            },
        )
    }

    state.invite?.let { invite ->
        FriendInviteDialog(
            invite = invite,
            onDismiss = vm::clearInvite,
            onShare = {
                val text = context.getString(
                    R.string.friends_invite_share_text,
                    invite.serverAddress,
                    invite.code,
                )
                context.startActivity(
                    Intent.createChooser(
                        Intent(Intent.ACTION_SEND)
                            .setType("text/plain")
                            .putExtra(Intent.EXTRA_SUBJECT, context.getString(R.string.friends_invite_subject))
                            .putExtra(Intent.EXTRA_TEXT, text),
                        context.getString(R.string.friends_invite_share),
                    ),
                )
            },
        )
    }

    if (showJoin) {
        FriendJoinDialog(
            setupState = state.setupState,
            initialServer = state.serverAddress,
            initialName = displayName,
            busy = state.isBusy,
            onDismiss = { showJoin = false },
            onSubmit = { server, code, name ->
                displayName = name
                showJoin = false
                vm.join(server, code, name)
            },
        )
    }

    selectedFriend?.let { friend ->
        FriendSharingDialog(
            friend = friend,
            busy = state.isBusy,
            onDismiss = { selectedFriend = null },
            onSave = {
                selectedFriend = null
                vm.updatePrivacy(friend, it)
            },
            onRemove = {
                selectedFriend = null
                removeCandidate = friend
            },
        )
    }

    removeCandidate?.let { friend ->
        AlertDialog(
            onDismissRequest = { removeCandidate = null },
            title = {
                Text(stringResource(R.string.friends_remove_title, friend.displayName))
            },
            text = { Text(stringResource(R.string.friends_remove_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        removeCandidate = null
                        vm.remove(friend)
                    },
                ) {
                    Text(
                        stringResource(R.string.friends_action_remove),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { removeCandidate = null }) {
                    Text(stringResource(R.string.friends_action_cancel))
                }
            },
        )
    }

    if (confirmLeave) {
        AlertDialog(
            onDismissRequest = { confirmLeave = false },
            title = { Text(stringResource(R.string.friends_leave_title)) },
            text = { Text(stringResource(R.string.friends_leave_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmLeave = false
                        vm.leaveAndDelete()
                    },
                ) {
                    Text(
                        stringResource(R.string.friends_leave_action),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmLeave = false }) {
                    Text(stringResource(R.string.friends_action_cancel))
                }
            },
        )
    }

    if (confirmDiscardPending) {
        AlertDialog(
            onDismissRequest = { confirmDiscardPending = false },
            title = { Text(stringResource(R.string.friends_pending_discard_title)) },
            text = { Text(stringResource(R.string.friends_pending_discard_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmDiscardPending = false
                        vm.discardPendingJoin()
                    },
                ) {
                    Text(
                        stringResource(R.string.friends_pending_discard_action),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDiscardPending = false }) {
                    Text(stringResource(R.string.friends_action_cancel))
                }
            },
        )
    }

    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }
    ScreenScaffold(
        title = stringResource(R.string.friends_title),
        subtitle = stringResource(R.string.friends_subtitle),
        modifier = Modifier.testTag("noop.screen.friends"),
        trailing = {
            IconButton(
                onClick = vm::refresh,
                enabled = state.setupState == FriendsSetupState.READY && !state.isBusy,
                modifier = Modifier.semantics {
                    contentDescription = context.getString(R.string.friends_refresh)
                },
            ) {
                if (state.action == FriendsAction.REFRESH) {
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        color = Palette.accent,
                        modifier = Modifier.size(20.dp),
                    )
                } else {
                    Icon(
                        Icons.Filled.Refresh,
                        contentDescription = null,
                        tint = if (state.setupState == FriendsSetupState.READY) {
                            Palette.textPrimary
                        } else {
                            Palette.textTertiary
                        },
                    )
                }
            }
        },
        topBackground = if (showDayCycleBackground) {
            { LiquidScreenSky(fillHeight = skyBehindCards) }
        } else {
            null
        },
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        state.notice?.let {
            StatePill(
                title = friendsNoticeText(it),
                tone = StrandTone.Positive,
                showsDot = true,
            )
        }
        if (state.summaryUploadPending) {
            FriendsWarningRow(stringResource(R.string.friends_upload_pending))
        }

        when (state.setupState) {
            FriendsSetupState.NEEDS_SERVER -> FriendsServerSetup(
                busy = state.isBusy,
                onOpenBackupSync = onOpenBackupSync,
                onJoin = { showJoin = true },
            )
            FriendsSetupState.PENDING_JOIN -> FriendsPendingJoin(
                displayName = state.profileName,
                serverAddress = state.serverAddress,
                busy = state.isBusy,
                onRetry = { showJoin = true },
                onDiscard = { confirmDiscardPending = true },
            )
            FriendsSetupState.NEEDS_PROFILE -> FriendsProfileSetup(
                displayName = displayName,
                busy = state.isBusy,
                serverAddress = state.serverAddress,
                onDisplayNameChange = { displayName = it.take(64) },
                onCreate = { vm.createProfile(displayName) },
                onJoin = { showJoin = true },
            )
            FriendsSetupState.READY -> FriendsReadyContent(
                state = state,
                onInvite = vm::createInvite,
                onJoin = { showJoin = true },
                onDecide = vm::decide,
                onSelectFriend = { selectedFriend = it },
                onLeave = { confirmLeave = true },
            )
        }
    }
}

@Composable
private fun FriendsPendingJoin(
    displayName: String,
    serverAddress: String,
    busy: Boolean,
    onRetry: () -> Unit,
    onDiscard: () -> Unit,
) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            FriendsLead(
                icon = Icons.Filled.Warning,
                title = stringResource(R.string.friends_pending_title),
                body = stringResource(R.string.friends_pending_body),
            )
            FriendsDisclosure(
                Icons.Filled.People,
                displayName,
                serverHost(serverAddress),
            )
            NoopButton(
                text = stringResource(R.string.friends_pending_retry),
                leadingIcon = Icons.Filled.Refresh,
                fullWidth = true,
                enabled = !busy,
                onClick = onRetry,
            )
            NoopButton(
                text = stringResource(R.string.friends_pending_discard),
                leadingIcon = Icons.Filled.DeleteForever,
                kind = NoopButtonKind.Tertiary,
                fullWidth = true,
                enabled = !busy,
                onClick = onDiscard,
            )
        }
    }
}

@Composable
private fun FriendsServerSetup(
    busy: Boolean,
    onOpenBackupSync: () -> Unit,
    onJoin: () -> Unit,
) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            FriendsLead(
                icon = Icons.Filled.People,
                title = stringResource(R.string.friends_server_title),
                body = stringResource(R.string.friends_server_body),
            )
            NoopButton(
                text = stringResource(R.string.friends_server_setup_action),
                leadingIcon = Icons.Filled.CloudSync,
                fullWidth = true,
                enabled = !busy,
                onClick = onOpenBackupSync,
            )
            NoopButton(
                text = stringResource(R.string.friends_join_details),
                leadingIcon = Icons.Filled.Numbers,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !busy,
                onClick = onJoin,
            )
            Text(
                stringResource(R.string.friends_server_invite_note),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun FriendsProfileSetup(
    displayName: String,
    busy: Boolean,
    serverAddress: String,
    onDisplayNameChange: (String) -> Unit,
    onCreate: () -> Unit,
    onJoin: () -> Unit,
) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalAlignment = Alignment.Top,
            ) {
                FriendOrb(displayName.ifBlank { stringResource(R.string.friends_you) }, 54.dp, true)
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        stringResource(R.string.friends_profile_title),
                        style = NoopType.title2,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(
                            R.string.friends_profile_body,
                            serverHost(serverAddress),
                        ),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }
            }
            OutlinedTextField(
                value = displayName,
                onValueChange = onDisplayNameChange,
                label = { Text(stringResource(R.string.friends_display_name)) },
                singleLine = true,
                colors = friendsFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
            NoopButton(
                text = if (busy) {
                    stringResource(R.string.friends_working)
                } else {
                    stringResource(R.string.friends_create_profile)
                },
                leadingIcon = Icons.Filled.Shield,
                fullWidth = true,
                enabled = !busy && displayName.trim().isNotEmpty(),
                onClick = onCreate,
            )
            NoopButton(
                text = stringResource(R.string.friends_join_details),
                leadingIcon = Icons.Filled.Numbers,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !busy,
                onClick = onJoin,
            )
            Text(
                stringResource(R.string.friends_profile_security_note),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun FriendsReadyContent(
    state: FriendsUiState,
    onInvite: () -> Unit,
    onJoin: () -> Unit,
    onDecide: (FriendRequest, Boolean) -> Unit,
    onSelectFriend: (FriendContact) -> Unit,
    onLeave: () -> Unit,
) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Overline(stringResource(R.string.friends_circle_overline), color = Palette.textTertiary)
                    Text(
                        pluralStringResource(
                            R.plurals.friends_people_count,
                            state.friends.size + 1,
                            state.friends.size + 1,
                        ),
                        style = NoopType.title1,
                        color = Palette.textPrimary,
                    )
                    Text(
                        serverHost(state.serverAddress),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Icon(
                    Icons.Filled.People,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(38.dp),
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy((-10).dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FriendOrb(
                    state.profileName.ifBlank { stringResource(R.string.friends_you) },
                    52.dp,
                    true,
                )
                state.friends.take(4).forEach { friend ->
                    FriendOrb(friend.displayName, 52.dp)
                }
                if (state.friends.size > 4) {
                    Box(
                        modifier = Modifier
                            .size(52.dp)
                            .clip(CircleShape)
                            .background(Palette.surfaceInset)
                            .border(1.dp, Palette.hairlineStrong, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            stringResource(
                                R.string.friends_overflow_count,
                                state.friends.size - 4,
                            ),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                NoopButton(
                    text = if (state.action == FriendsAction.CREATE_INVITE) {
                        stringResource(R.string.friends_working)
                    } else {
                        stringResource(R.string.friends_invite_action)
                    },
                    leadingIcon = Icons.Filled.PersonAdd,
                    enabled = !state.isBusy,
                    modifier = Modifier.weight(1f),
                    onClick = onInvite,
                )
                IconButton(
                    onClick = onJoin,
                    enabled = !state.isBusy,
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(Palette.surfaceInset)
                        .border(1.dp, Palette.hairline, CircleShape),
                ) {
                    Icon(
                        Icons.Filled.Numbers,
                        contentDescription = stringResource(R.string.friends_enter_invite_code),
                        tint = Palette.textPrimary,
                    )
                }
            }
        }
    }

    if (state.requests.isNotEmpty()) {
        SectionHeader(
            title = stringResource(R.string.friends_requests_title),
            trailing = state.requests.size.toString(),
        )
        state.requests.forEach { request ->
            FriendRequestCard(
                request = request,
                busy = state.isBusy,
                onDecide = onDecide,
            )
        }
    }

    SectionHeader(
        title = stringResource(R.string.friends_today_title),
        trailing = if (state.friends.isEmpty()) {
            stringResource(R.string.friends_private)
        } else {
            pluralStringResource(
                R.plurals.friends_friend_count,
                state.friends.size,
                state.friends.size,
            )
        },
    )
    if (state.friends.isEmpty()) {
        NoopCard {
            FriendsLead(
                icon = Icons.Filled.PersonAdd,
                title = stringResource(R.string.friends_empty_title),
                body = stringResource(R.string.friends_empty_body),
            )
        }
    } else {
        state.friends.forEach { friend ->
            FriendCard(friend = friend, onClick = { onSelectFriend(friend) })
        }
    }

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            FriendsLead(
                icon = Icons.Filled.Lock,
                title = stringResource(R.string.friends_privacy_title),
                body = stringResource(R.string.friends_privacy_body),
            )
            HorizontalDivider(color = Palette.hairline)
            NoopButton(
                text = stringResource(R.string.friends_leave_action),
                leadingIcon = Icons.Filled.DeleteForever,
                kind = NoopButtonKind.Tertiary,
                fullWidth = true,
                enabled = !state.isBusy,
                onClick = onLeave,
            )
        }
    }
}

@Composable
private fun FriendRequestCard(
    request: FriendRequest,
    busy: Boolean,
    onDecide: (FriendRequest, Boolean) -> Unit,
) {
    val acceptLabel = stringResource(R.string.friends_accept_named, request.displayName)
    NoopCard {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            FriendOrb(request.displayName, 44.dp)
            Column(modifier = Modifier.weight(1f)) {
                Text(request.displayName, style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    if (request.direction == FriendRequest.Direction.INCOMING) {
                        stringResource(R.string.friends_request_incoming)
                    } else {
                        stringResource(R.string.friends_request_outgoing)
                    },
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            if (request.direction == FriendRequest.Direction.INCOMING) {
                TextButton(
                    onClick = { onDecide(request, false) },
                    enabled = !busy,
                ) {
                    Text(
                        stringResource(R.string.friends_action_decline),
                        color = Palette.textSecondary,
                    )
                }
                IconButton(
                    onClick = { onDecide(request, true) },
                    enabled = !busy,
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(Palette.accent),
                ) {
                    Icon(
                        Icons.Filled.Check,
                        contentDescription = acceptLabel,
                        tint = Palette.accentInk,
                    )
                }
            }
        }
    }
}

@Composable
private fun FriendCard(friend: FriendContact, onClick: () -> Unit) {
    val openSharingLabel = stringResource(
        R.string.friends_open_sharing_named,
        friend.displayName,
    )
    NoopCard(
        modifier = Modifier
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = openSharingLabel },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                FriendOrb(friend.displayName, 46.dp)
                Column(modifier = Modifier.weight(1f)) {
                    Text(friend.displayName, style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        friend.latest?.let { friendFreshness(it.day) }
                            ?: stringResource(R.string.friends_waiting_shared_day),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Icon(Icons.Filled.Tune, contentDescription = null, tint = Palette.textTertiary)
            }
            friend.latest?.let { summary ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FriendScoreTile(
                        label = stringResource(R.string.friends_score_charge),
                        value = summary.charge,
                        icon = Icons.Filled.Favorite,
                        color = Palette.chargeColor,
                        modifier = Modifier.weight(1f),
                    )
                    FriendScoreTile(
                        label = stringResource(R.string.friends_score_effort),
                        value = summary.effort,
                        icon = Icons.Filled.FitnessCenter,
                        color = Palette.effortColor,
                        modifier = Modifier.weight(1f),
                    )
                    FriendScoreTile(
                        label = stringResource(R.string.friends_score_rest),
                        value = summary.rest,
                        icon = Icons.Filled.Bedtime,
                        color = Palette.restColor,
                        modifier = Modifier.weight(1f),
                    )
                }
                FriendOptionalDetails(summary)
            } ?: Text(
                stringResource(R.string.friends_scores_waiting, friend.displayName),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
    }
}

@Composable
private fun FriendScoreTile(
    label: String,
    value: Double?,
    icon: ImageVector,
    color: Color,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .heightIn(min = 84.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, RoundedCornerShape(8.dp))
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(17.dp))
        Text(
            label,
            style = NoopType.overline.copy(fontSize = 9.sp),
            color = Palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            value?.roundToInt()?.toString() ?: "--",
            style = NoopType.number(25f),
            color = if (value == null) Palette.textTertiary else color,
        )
    }
}

@Composable
private fun FriendOptionalDetails(summary: FriendDailySummary) {
    val values = buildList {
        summary.sleepMinutes?.let {
            val minutes = it.roundToInt().coerceAtLeast(0)
            add(
                stringResource(
                    R.string.friends_detail_sleep,
                    stringResource(
                        R.string.friends_duration_hours_minutes,
                        minutes / 60,
                        minutes % 60,
                    ),
                ),
            )
        }
        summary.hrv?.let {
            add(stringResource(R.string.friends_detail_hrv, formatNumber(it)))
        }
        summary.rhr?.let {
            add(stringResource(R.string.friends_detail_rhr, formatNumber(it)))
        }
    }
    if (values.isNotEmpty()) {
        Text(
            values.joinToString("  |  "),
            style = NoopType.footnote,
            color = Palette.textSecondary,
        )
    }
}

@Composable
private fun FriendInviteDialog(
    invite: FriendInvite,
    onDismiss: () -> Unit,
    onShare: () -> Unit,
) {
    FriendsDialog(onDismiss = onDismiss) {
        FriendsLead(
            icon = Icons.Filled.PersonAdd,
            title = stringResource(R.string.friends_invite_title),
            body = stringResource(R.string.friends_invite_body),
        )
        Text(
            invite.serverAddress,
            style = NoopType.footnote,
            color = Palette.textSecondary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            invite.code,
            style = NoopType.title2.copy(fontFamily = FontFamily.Monospace),
            color = Palette.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(Palette.surfaceInset)
                .padding(14.dp),
        )
        Text(
            stringResource(R.string.friends_invite_expires, formatInviteExpiry(invite.expiresAt)),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
        NoopButton(
            text = stringResource(R.string.friends_invite_share),
            leadingIcon = Icons.Filled.Share,
            fullWidth = true,
            onClick = onShare,
        )
        Text(
            stringResource(R.string.friends_invite_disclosure),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
        NoopButton(
            text = stringResource(R.string.friends_action_done),
            kind = NoopButtonKind.Secondary,
            fullWidth = true,
            onClick = onDismiss,
        )
    }
}

@Composable
private fun FriendJoinDialog(
    setupState: FriendsSetupState,
    initialServer: String,
    initialName: String,
    busy: Boolean,
    onDismiss: () -> Unit,
    onSubmit: (String, String, String) -> Unit,
) {
    val requiresProfile = setupState != FriendsSetupState.READY
    val pendingJoin = setupState == FriendsSetupState.PENDING_JOIN
    var server by rememberSaveable(initialServer) { mutableStateOf(initialServer) }
    var displayName by rememberSaveable(initialName) { mutableStateOf(initialName) }
    var code by rememberSaveable { mutableStateOf("") }
    val canSubmit =
        code.filter(Char::isLetterOrDigit).length in 12..32 &&
            (!requiresProfile || (server.isNotBlank() && displayName.trim().isNotBlank()))

    FriendsDialog(onDismiss = onDismiss) {
        FriendsLead(
            icon = Icons.Filled.People,
            title = stringResource(R.string.friends_join_title),
            body = stringResource(R.string.friends_join_body),
        )
        if (requiresProfile) {
            OutlinedTextField(
                value = server,
                onValueChange = { server = it },
                label = { Text(stringResource(R.string.friends_server_address)) },
                placeholder = { Text("https://") },
                singleLine = true,
                readOnly = pendingJoin,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                colors = friendsFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = displayName,
                onValueChange = { displayName = it.take(64) },
                label = { Text(stringResource(R.string.friends_display_name)) },
                singleLine = true,
                readOnly = pendingJoin,
                colors = friendsFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
        } else {
            Text(
                serverHost(initialServer),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
        OutlinedTextField(
            value = code,
            onValueChange = { code = it.uppercase(Locale.ROOT).take(40) },
            label = { Text(stringResource(R.string.friends_invite_code)) },
            singleLine = true,
            colors = friendsFieldColors(),
            textStyle = NoopType.body.copy(fontFamily = FontFamily.Monospace),
            modifier = Modifier.fillMaxWidth(),
        )
        FriendsDisclosure(
            Icons.Filled.Check,
            stringResource(R.string.friends_join_default_title),
            stringResource(R.string.friends_join_default_body),
        )
        FriendsDisclosure(
            Icons.Filled.Lock,
            stringResource(R.string.friends_join_never_title),
            stringResource(R.string.friends_join_never_body),
        )
        FriendsDisclosure(
            Icons.Filled.CloudSync,
            stringResource(R.string.friends_join_trust_title),
            stringResource(R.string.friends_join_trust_body),
        )
        NoopButton(
            text = stringResource(
                if (pendingJoin) {
                    R.string.friends_pending_retry
                } else {
                    R.string.friends_join_send
                },
            ),
            leadingIcon = Icons.AutoMirrored.Filled.Send,
            fullWidth = true,
            enabled = canSubmit && !busy,
            onClick = {
                onSubmit(if (requiresProfile) server else initialServer, code, displayName)
            },
        )
        NoopButton(
            text = stringResource(R.string.friends_action_cancel),
            kind = NoopButtonKind.Secondary,
            fullWidth = true,
            enabled = !busy,
            onClick = onDismiss,
        )
    }
}

@Composable
private fun FriendSharingDialog(
    friend: FriendContact,
    busy: Boolean,
    onDismiss: () -> Unit,
    onSave: (FriendVisibility) -> Unit,
    onRemove: () -> Unit,
) {
    var sharing by remember(friend.profileId) { mutableStateOf(friend.sharing) }
    FriendsDialog(onDismiss = onDismiss) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(13.dp),
        ) {
            FriendOrb(friend.displayName, 52.dp)
            Column(modifier = Modifier.weight(1f)) {
                Text(friend.displayName, style = NoopType.title2, color = Palette.textPrimary)
                Text(
                    stringResource(R.string.friends_sharing_directional),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
        }
        Overline(stringResource(R.string.friends_daily_scores), color = Palette.textTertiary)
        FriendVisibilityToggle(
            stringResource(R.string.friends_score_charge),
            sharing.charge,
        ) { sharing = sharing.copy(charge = it) }
        FriendVisibilityToggle(
            stringResource(R.string.friends_score_effort),
            sharing.effort,
        ) { sharing = sharing.copy(effort = it) }
        FriendVisibilityToggle(
            stringResource(R.string.friends_score_rest),
            sharing.rest,
        ) { sharing = sharing.copy(rest = it) }
        Overline(stringResource(R.string.friends_additional_details), color = Palette.textTertiary)
        FriendVisibilityToggle(
            stringResource(R.string.friends_sleep_duration),
            sharing.sleepDuration,
        ) { sharing = sharing.copy(sleepDuration = it) }
        FriendVisibilityToggle(
            stringResource(R.string.friends_hrv),
            sharing.hrv,
        ) { sharing = sharing.copy(hrv = it) }
        FriendVisibilityToggle(
            stringResource(R.string.friends_rhr),
            sharing.rhr,
        ) { sharing = sharing.copy(rhr = it) }
        Text(
            stringResource(R.string.friends_additional_default_note),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
        HorizontalDivider(color = Palette.hairline)
        Overline(stringResource(R.string.friends_they_share), color = Palette.textTertiary)
        FriendReadOnlyVisibility(stringResource(R.string.friends_score_charge), friend.sharedWithMe.charge)
        FriendReadOnlyVisibility(stringResource(R.string.friends_score_effort), friend.sharedWithMe.effort)
        FriendReadOnlyVisibility(stringResource(R.string.friends_score_rest), friend.sharedWithMe.rest)
        FriendReadOnlyVisibility(stringResource(R.string.friends_sleep_duration), friend.sharedWithMe.sleepDuration)
        FriendReadOnlyVisibility(stringResource(R.string.friends_hrv), friend.sharedWithMe.hrv)
        FriendReadOnlyVisibility(stringResource(R.string.friends_rhr), friend.sharedWithMe.rhr)
        NoopButton(
            text = stringResource(R.string.friends_action_save),
            leadingIcon = Icons.Filled.Check,
            fullWidth = true,
            enabled = !busy,
            onClick = { onSave(sharing) },
        )
        NoopButton(
            text = stringResource(R.string.friends_remove_named, friend.displayName),
            leadingIcon = Icons.Filled.DeleteForever,
            kind = NoopButtonKind.Destructive,
            fullWidth = true,
            enabled = !busy,
            onClick = onRemove,
        )
        NoopButton(
            text = stringResource(R.string.friends_action_cancel),
            kind = NoopButtonKind.Secondary,
            fullWidth = true,
            enabled = !busy,
            onClick = onDismiss,
        )
    }
}

@Composable
private fun FriendVisibilityToggle(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        NoopToggleSwitch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun FriendReadOnlyVisibility(label: String, visible: Boolean) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        Text(
            if (visible) {
                stringResource(R.string.friends_shared)
            } else {
                stringResource(R.string.friends_hidden)
            },
            style = NoopType.footnote,
            color = if (visible) Palette.statusPositiveText else Palette.textTertiary,
        )
    }
}

@Composable
private fun FriendsDialog(
    onDismiss: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val maxHeight = LocalConfiguration.current.screenHeightDp.dp * 0.9f
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(8.dp),
            color = Palette.surfaceRaised,
            contentColor = Palette.textPrimary,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = maxHeight),
        ) {
            Column(
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                content = content,
            )
        }
    }
}

@Composable
private fun FriendsLead(icon: ImageVector, title: String, body: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(13.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(46.dp)
                .clip(CircleShape)
                .background(Palette.surfaceInset)
                .border(1.dp, Palette.hairline, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(22.dp))
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(title, style = NoopType.title2, color = Palette.textPrimary)
            Text(body, style = NoopType.subhead, color = Palette.textSecondary)
        }
    }
}

@Composable
private fun FriendsDisclosure(icon: ImageVector, title: String, body: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = Palette.textPrimary, modifier = Modifier.size(20.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = NoopType.subhead, color = Palette.textPrimary)
            Text(body, style = NoopType.footnote, color = Palette.textSecondary)
        }
    }
}

@Composable
private fun FriendOrb(name: String, size: Dp, highlighted: Boolean = false) {
    val initials = remember(name) {
        name.trim()
            .split(Regex("""\s+"""))
            .filter(String::isNotBlank)
            .take(2)
            .mapNotNull(String::firstOrNull)
            .joinToString("")
            .uppercase(Locale.getDefault())
            .ifBlank { "?" }
    }
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(
                Brush.linearGradient(
                    listOf(
                        if (highlighted) Palette.accentMuted else Palette.surfaceRaised,
                        Palette.surfaceInset,
                    ),
                ),
            )
            .border(
                if (highlighted) 1.5.dp else 1.dp,
                if (highlighted) Palette.accent else Palette.hairlineStrong,
                CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            initials,
            style = NoopType.headline.copy(
                fontSize = (size.value * 0.28f).sp,
                fontWeight = FontWeight.Bold,
            ),
            color = Palette.textPrimary,
        )
    }
}

@Composable
private fun FriendsWarningRow(text: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Filled.Warning,
            contentDescription = null,
            tint = Palette.statusWarning,
            modifier = Modifier.size(18.dp),
        )
        Text(text, style = NoopType.footnote, color = Palette.textSecondary)
    }
}

@Composable
private fun friendsErrorText(error: FriendsUiError): String = when (error.kind) {
    FriendsErrorKind.INPUT ->
        error.detail ?: stringResource(R.string.friends_error_input)
    FriendsErrorKind.NETWORK ->
        stringResource(R.string.friends_error_network)
    FriendsErrorKind.SERVER ->
        stringResource(R.string.friends_error_server, error.statusCode ?: 0)
    FriendsErrorKind.RESPONSE ->
        stringResource(R.string.friends_error_response)
    FriendsErrorKind.STORAGE ->
        stringResource(R.string.friends_error_storage)
    FriendsErrorKind.UNKNOWN ->
        stringResource(R.string.friends_error_unknown)
}

@Composable
private fun friendsNoticeText(notice: FriendsNotice): String = when (notice.kind) {
    FriendsNoticeKind.PROFILE_READY ->
        stringResource(R.string.friends_notice_profile_ready)
    FriendsNoticeKind.REQUEST_SENT ->
        stringResource(R.string.friends_notice_request_sent)
    FriendsNoticeKind.REQUEST_ACCEPTED ->
        stringResource(R.string.friends_notice_request_accepted, notice.subject.orEmpty())
    FriendsNoticeKind.REQUEST_DECLINED ->
        stringResource(R.string.friends_notice_request_declined)
    FriendsNoticeKind.PRIVACY_SAVED ->
        stringResource(R.string.friends_notice_privacy_saved, notice.subject.orEmpty())
    FriendsNoticeKind.FRIEND_REMOVED ->
        stringResource(R.string.friends_notice_removed, notice.subject.orEmpty())
    FriendsNoticeKind.PROFILE_DELETED ->
        stringResource(R.string.friends_notice_profile_deleted)
    FriendsNoticeKind.PENDING_DISCARDED ->
        stringResource(R.string.friends_notice_pending_discarded)
}

@Composable
private fun friendFreshness(day: String): String {
    val parsed = runCatching { LocalDate.parse(day) }.getOrNull()
        ?: return stringResource(R.string.friends_last_shared)
    val today = LocalDate.now()
    return when (parsed) {
        today -> stringResource(R.string.friends_shared_today)
        today.minusDays(1) -> stringResource(R.string.friends_shared_yesterday)
        else -> stringResource(
            R.string.friends_last_shared_date,
            parsed.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)),
        )
    }
}

private fun formatInviteExpiry(raw: String): String =
    runCatching {
        OffsetDateTime.parse(raw)
            .atZoneSameInstant(ZoneId.systemDefault())
            .format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT))
    }.getOrDefault(raw)

private fun formatNumber(value: Double): String =
    NumberFormat.getNumberInstance().apply { maximumFractionDigits = 1 }.format(value)

private fun serverHost(address: String): String =
    runCatching { java.net.URI(address).host }.getOrNull()?.takeIf(String::isNotBlank)
        ?: address.ifBlank { "--" }

@Composable
private fun friendsFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
    focusedLabelColor = Palette.textSecondary,
    unfocusedLabelColor = Palette.textTertiary,
)
