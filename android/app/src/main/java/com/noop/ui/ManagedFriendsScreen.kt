package com.noop.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Handshake
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.NoopApplication
import com.noop.R
import com.noop.managed.ManagedCloudPhase
import com.noop.managed.ManagedCloudService
import com.noop.managed.ManagedSocialBadge
import com.noop.managed.ManagedSocialBlockedProfile
import com.noop.managed.ManagedSocialFeedDay
import com.noop.managed.ManagedSocialFriend
import com.noop.managed.ManagedSocialIdentifier
import com.noop.managed.ManagedSocialProfile
import com.noop.managed.ManagedSocialRequest
import com.noop.managed.ManagedSocialSummary
import com.noop.managed.ManagedSocialVisibility
import com.noop.managed.ManagedSocialVisibilityPatch
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

private const val FRIENDS_SOURCE_KEY = "friends.source.v1"
private const val FRIENDS_SOURCE_MANAGED = "managed"
private const val FRIENDS_SOURCE_SELF_HOSTED = "selfHosted"

@Composable
internal fun FriendsScreen(onOpenBackupSync: () -> Unit) {
    val context = LocalContext.current
    val service = remember {
        (context.applicationContext as? NoopApplication)?.managedCloud
            ?: ManagedCloudService.get(context)
    }
    val state by service.state.collectAsStateWithLifecycle()
    var source by rememberSaveable {
        mutableStateOf(
            NoopPrefs.of(context)
                .getString(FRIENDS_SOURCE_KEY, FRIENDS_SOURCE_MANAGED)
                .takeIf {
                    it == FRIENDS_SOURCE_MANAGED || it == FRIENDS_SOURCE_SELF_HOSTED
                } ?: FRIENDS_SOURCE_MANAGED,
        )
    }

    fun select(value: String) {
        source = value
        NoopPrefs.of(context).edit().putString(FRIENDS_SOURCE_KEY, value).apply()
    }

    LaunchedEffect(state.hasPendingSocialInvite, state.pendingSocialNoopId) {
        if (state.hasPendingSocialInvite || state.pendingSocialNoopId != null) {
            select(FRIENDS_SOURCE_MANAGED)
        }
    }

    val picker: @Composable () -> Unit = {
        FriendsSourcePicker(
            selected = source,
            onSelected = ::select,
        )
    }
    if (source == FRIENDS_SOURCE_MANAGED) {
        ManagedFriendsScreen(service = service, sourcePicker = picker)
    } else {
        SelfHostedFriendsScreen(
            onOpenBackupSync = onOpenBackupSync,
            sourcePicker = picker,
        )
    }
}

@Composable
private fun FriendsSourcePicker(
    selected: String,
    onSelected: (String) -> Unit,
) {
    Surface(
        color = Palette.surfaceInset,
        shape = RoundedCornerShape(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(modifier = Modifier.padding(3.dp)) {
            listOf(
                FRIENDS_SOURCE_MANAGED to stringResource(R.string.managed_friends_source_noop_plus),
                FRIENDS_SOURCE_SELF_HOSTED to
                    stringResource(R.string.managed_friends_source_self_hosted),
            ).forEach { (value, label) ->
                val active = selected == value
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(6.dp))
                        .background(
                            if (active) {
                                Palette.surfaceRaised
                            } else {
                                androidx.compose.ui.graphics.Color.Transparent
                            },
                        )
                        .testTag("noop.friends.source.$value")
                        .clickable(role = Role.Tab) { onSelected(value) }
                        .semantics { this.selected = active }
                        .padding(vertical = 10.dp),
                ) {
                    Text(
                        text = label,
                        style = NoopType.footnote,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                        color = if (active) Palette.textPrimary else Palette.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun ManagedFriendsScreen(
    service: ManagedCloudService,
    sourcePicker: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val state by service.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var displayName by rememberSaveable {
        mutableStateOf(ProfileStore.from(context).displayName)
    }
    var searchId by rememberSaveable { mutableStateOf("") }
    var pokeOptIn by rememberSaveable { mutableStateOf(false) }
    var quietStart by rememberSaveable { mutableStateOf("22:00") }
    var quietEnd by rememberSaveable { mutableStateOf("07:00") }
    var selectedFriend by remember { mutableStateOf<ManagedSocialFriend?>(null) }
    var requestToBlock by remember { mutableStateOf<ManagedSocialRequest?>(null) }
    var profileToUnblock by remember {
        mutableStateOf<ManagedSocialBlockedProfile?>(null)
    }
    var confirmRotate by rememberSaveable { mutableStateOf(false) }
    var confirmDelete by rememberSaveable { mutableStateOf(false) }
    var showInvite by rememberSaveable { mutableStateOf(false) }
    val notificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) {}

    LaunchedEffect(service) {
        service.bootstrap()
        if (service.state.value.phase == ManagedCloudPhase.ENROLLED) {
            service.refreshSocial()
        }
    }
    LaunchedEffect(state.socialProfile) {
        state.socialProfile?.let { profile ->
            displayName = profile.displayName
            pokeOptIn = profile.pokeOptIn
            quietStart = minuteText(profile.quietStartMinute)
            quietEnd = minuteText(profile.quietEndMinute)
        }
    }
    LaunchedEffect(state.pendingSocialNoopId) {
        state.pendingSocialNoopId?.let { searchId = it }
    }
    LaunchedEffect(searchId) { service.clearSocialLookup() }
    LaunchedEffect(state.socialInvite?.inviteId) {
        if (state.socialInvite != null) showInvite = true
    }

    if (confirmRotate) {
        ConfirmDialog(
            title = stringResource(R.string.managed_friends_rotate_title),
            body = stringResource(R.string.managed_friends_rotate_body),
            action = stringResource(R.string.managed_friends_rotate_action),
            onDismiss = { confirmRotate = false },
            onConfirm = {
                confirmRotate = false
                scope.launch { service.rotateSocialNoopId() }
            },
        )
    }
    if (confirmDelete) {
        ConfirmDialog(
            title = stringResource(R.string.managed_friends_delete_title),
            body = stringResource(R.string.managed_friends_delete_body),
            action = stringResource(R.string.managed_friends_delete_action),
            onDismiss = { confirmDelete = false },
            onConfirm = {
                confirmDelete = false
                scope.launch { service.deleteSocialProfile() }
            },
        )
    }
    if (showInvite && state.socialInvite != null) {
        ManagedInviteDialog(
            link = service.socialInviteUri()?.toString().orEmpty(),
            busy = state.busy,
            onDismiss = { showInvite = false },
            onShare = {
                service.socialInviteUri()?.toString()?.let { link ->
                    shareText(
                        context,
                        context.getString(R.string.managed_friends_invite_subject),
                        context.getString(
                            R.string.managed_friends_invite_share_text,
                            link,
                        ),
                    )
                }
            },
            onRevoke = {
                showInvite = false
                scope.launch { service.revokeSocialInvite() }
            },
        )
    }
    requestToBlock?.let { request ->
        ConfirmDialog(
            title = stringResource(
                R.string.managed_friends_block_title,
                request.displayName,
            ),
            body = stringResource(R.string.managed_friends_block_request_body),
            action = stringResource(R.string.managed_friends_block_profile),
            onDismiss = { requestToBlock = null },
            onConfirm = {
                requestToBlock = null
                scope.launch { service.blockSocialProfile(request.profileId) }
            },
        )
    }
    profileToUnblock?.let { blocked ->
        ConfirmDialog(
            title = stringResource(
                R.string.managed_friends_unblock_title,
                blocked.displayName,
            ),
            body = stringResource(R.string.managed_friends_unblock_body),
            action = stringResource(R.string.managed_friends_unblock_profile),
            destructive = false,
            onDismiss = { profileToUnblock = null },
            onConfirm = {
                profileToUnblock = null
                scope.launch { service.unblockSocialProfile(blocked.profileId) }
            },
        )
    }
    selectedFriend?.let { friend ->
        ManagedFriendSettingsDialog(
            friend = friend,
            history = state.socialFeed
                .filter { it.profileId == friend.profileId }
                .sortedByDescending(ManagedSocialFeedDay::day)
                .take(7),
            busy = state.busy,
            onDismiss = { selectedFriend = null },
            onSave = { patch ->
                selectedFriend = null
                scope.launch {
                    service.updateSocialVisibility(friend.profileId, patch)
                }
            },
            onRemove = {
                selectedFriend = null
                scope.launch { service.removeSocialFriend(friend.profileId) }
            },
            onBlock = {
                selectedFriend = null
                scope.launch { service.blockSocialProfile(friend.profileId) }
            },
        )
    }
    ScreenScaffold(
        title = stringResource(R.string.friends_title),
        subtitle = stringResource(R.string.managed_friends_subtitle),
        modifier = Modifier.testTag("noop.screen.friends"),
        trailing = {
            IconButton(
                enabled = state.phase == ManagedCloudPhase.ENROLLED && !state.busy,
                onClick = { scope.launch { service.refreshSocial() } },
                modifier = Modifier.semantics {
                    contentDescription =
                        context.getString(R.string.managed_friends_refresh)
                },
            ) {
                if (state.busy) {
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        color = Palette.accent,
                        modifier = Modifier.size(20.dp),
                    )
                } else {
                    Icon(Icons.Filled.Refresh, contentDescription = null)
                }
            }
        },
    ) {
        sourcePicker()
        if (state.phase != ManagedCloudPhase.ENROLLED) {
            ManagedCloudBackupCard()
            ManagedFriendsBoundaryCard()
        } else if (state.socialProfile == null) {
            ManagedProfileSetup(
                name = displayName,
                busy = state.busy,
                hasInvite =
                    state.hasPendingSocialInvite || state.pendingSocialNoopId != null,
                onNameChange = { displayName = it.take(64) },
                onCreate = {
                    scope.launch { service.createSocialProfile(displayName) }
                },
            )
        } else {
            state.pendingSocialNoopId?.let { noopId ->
                ManagedPendingProfileLinkCard(
                    busy = state.busy,
                    onReview = {
                        searchId = noopId
                        service.clearPendingSocialProfileLink()
                        scope.launch { service.lookupSocialProfile(noopId) }
                    },
                    onDismiss = service::clearPendingSocialProfileLink,
                )
            }
            if (state.hasPendingSocialInvite) {
                ManagedPendingInviteCard(
                    busy = state.busy,
                    onAccept = {
                        scope.launch { service.redeemPendingSocialInvite() }
                    },
                    onDismiss = service::clearPendingSocialInvite,
                )
            }
            ManagedIdentityCard(
                profile = state.socialProfile,
                busy = state.busy,
                onShareProfile = {
                    val link = service.socialProfileUri()?.toString().orEmpty()
                    shareText(
                        context,
                        context.getString(R.string.managed_friends_id_subject),
                        context.getString(
                            R.string.managed_friends_id_share_text,
                            link,
                        ),
                    )
                },
                onRotate = { confirmRotate = true },
                onCreateInvite = {
                    scope.launch {
                        service.createSocialInvite()
                        showInvite = true
                    }
                },
            )
            ManagedExactSearch(
                value = searchId,
                lookup = state.socialLookup,
                busy = state.busy,
                onValueChange = {
                    searchId = it.uppercase(Locale.ROOT).take(24)
                },
                onSearch = {
                    scope.launch { service.lookupSocialProfile(searchId) }
                },
                onRequest = { noopId ->
                    searchId = ""
                    scope.launch { service.sendSocialRequest(noopId) }
                },
            )
            ManagedRequests(
                requests = state.socialRequests.filter { it.status == "pending" },
                busy = state.busy,
                onDecision = { request, accepted ->
                    scope.launch {
                        service.decideSocialRequest(request.requestId, accepted)
                    }
                },
                onBlock = { requestToBlock = it },
            )
            ManagedFriendList(
                friends = state.socialFriends,
                busy = state.busy,
                onSettings = { selectedFriend = it },
                onPoke = { friend ->
                    scope.launch { service.sendSocialPoke(friend.profileId) }
                },
            )
            ManagedFriendsSettings(
                displayName = displayName,
                pokeOptIn = pokeOptIn,
                quietStart = quietStart,
                quietEnd = quietEnd,
                blockedProfiles = state.socialBlockedProfiles,
                busy = state.busy,
                onDisplayNameChange = { displayName = it.take(64) },
                onPokeChange = {
                    pokeOptIn = it
                    if (it && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                },
                onQuietStartChange = { quietStart = it.take(5) },
                onQuietEndChange = { quietEnd = it.take(5) },
                onSave = {
                    val start = parseMinute(quietStart) ?: return@ManagedFriendsSettings
                    val end = parseMinute(quietEnd) ?: return@ManagedFriendsSettings
                    scope.launch {
                        service.updateSocialProfile(
                            displayName = displayName,
                            pokeOptIn = pokeOptIn,
                            quietStartMinute = start,
                            quietEndMinute = end,
                        )
                    }
                },
                onUnblock = { profileToUnblock = it },
                onDelete = { confirmDelete = true },
            )
        }
        if (state.socialStatus.isNotBlank()) {
            Text(
                text = state.socialStatus,
                style = NoopType.footnote,
                color = Palette.textSecondary,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun ManagedFriendsBoundaryCard() {
    NoopCard {
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.statusPositive)
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    stringResource(R.string.managed_friends_two_options_title),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.managed_friends_two_options_body),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun ManagedProfileSetup(
    name: String,
    busy: Boolean,
    hasInvite: Boolean,
    onNameChange: (String) -> Unit,
    onCreate: () -> Unit,
) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            ManagedLead(
                Icons.Filled.PersonAdd,
                stringResource(R.string.managed_friends_create_title),
                stringResource(R.string.managed_friends_create_body),
            )
            OutlinedTextField(
                value = name,
                onValueChange = onNameChange,
                label = { Text(stringResource(R.string.friends_display_name)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            NoopButton(
                text = if (busy) {
                    stringResource(R.string.friends_working)
                } else {
                    stringResource(R.string.managed_friends_create_action)
                },
                leadingIcon = Icons.Filled.PersonAdd,
                fullWidth = true,
                enabled = !busy && name.trim().isNotEmpty(),
                onClick = onCreate,
            )
            if (hasInvite) {
                Text(
                    stringResource(R.string.managed_friends_create_invite_note),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
            }
        }
    }
}

@Composable
private fun ManagedPendingProfileLinkCard(
    busy: Boolean,
    onReview: () -> Unit,
    onDismiss: () -> Unit,
) {
    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ManagedLead(
                Icons.Filled.PersonAdd,
                stringResource(R.string.managed_friends_pending_profile_title),
                stringResource(R.string.managed_friends_pending_profile_body),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                NoopButton(
                    text = stringResource(R.string.managed_friends_review_profile),
                    leadingIcon = Icons.Filled.Search,
                    fullWidth = true,
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                    onClick = onReview,
                )
                IconButton(onClick = onDismiss, enabled = !busy) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription =
                            stringResource(R.string.managed_friends_dismiss_profile),
                    )
                }
            }
        }
    }
}

@Composable
private fun ManagedPendingInviteCard(
    busy: Boolean,
    onAccept: () -> Unit,
    onDismiss: () -> Unit,
) {
    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ManagedLead(
                Icons.Filled.Link,
                stringResource(R.string.managed_friends_pending_invite_title),
                stringResource(R.string.managed_friends_pending_invite_body),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                NoopButton(
                    text = stringResource(R.string.managed_friends_send_request),
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
                            stringResource(R.string.managed_friends_dismiss_invite),
                    )
                }
            }
        }
    }
}

@Composable
private fun ManagedIdentityCard(
    profile: ManagedSocialProfile?,
    busy: Boolean,
    onShareProfile: () -> Unit,
    onRotate: () -> Unit,
    onCreateInvite: () -> Unit,
) {
    val value = profile ?: return
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            ManagedLead(
                Icons.Filled.People,
                value.displayName,
                stringResource(R.string.managed_friends_identity_caption),
            )
            Surface(
                color = Palette.surfaceInset,
                shape = RoundedCornerShape(6.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = value.noopId,
                    style = NoopType.body,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.textPrimary,
                    modifier = Modifier.padding(14.dp),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                NoopButton(
                    text = stringResource(R.string.managed_friends_share_id),
                    leadingIcon = Icons.Filled.Share,
                    fullWidth = true,
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                    onClick = onShareProfile,
                )
                IconButton(onClick = onRotate, enabled = !busy) {
                    Icon(
                        Icons.Filled.Refresh,
                        contentDescription =
                            stringResource(R.string.managed_friends_rotate_action),
                    )
                }
            }
            NoopButton(
                text = stringResource(R.string.managed_friends_create_invite),
                leadingIcon = Icons.Filled.Link,
                fullWidth = true,
                enabled = !busy,
                onClick = onCreateInvite,
            )
            ManagedBadges(value.badges)
        }
    }
}

@Composable
private fun ManagedExactSearch(
    value: String,
    lookup: com.noop.managed.ManagedSocialLookupProfile?,
    busy: Boolean,
    onValueChange: (String) -> Unit,
    onSearch: () -> Unit,
    onRequest: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            stringResource(R.string.managed_friends_add_by_id),
            style = NoopType.headline,
            color = Palette.textPrimary,
        )
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = value,
                        onValueChange = onValueChange,
                        placeholder = {
                            Text(stringResource(R.string.managed_friends_id_placeholder))
                        },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.Characters,
                        ),
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(
                        enabled = !busy &&
                            ManagedSocialIdentifier.canonicalNoopId(value) != null,
                        onClick = onSearch,
                    ) {
                        Icon(
                            Icons.Filled.Search,
                            contentDescription =
                                stringResource(R.string.managed_friends_search),
                        )
                    }
                }
                lookup?.let { result ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        ManagedAvatar(result.displayName)
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .padding(horizontal = 10.dp),
                        ) {
                            Text(
                                result.displayName,
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                            Text(
                                stringResource(
                                    if (result.isSelf) {
                                        R.string.managed_friends_lookup_self
                                    } else {
                                        R.string.managed_friends_lookup_found
                                    },
                                ),
                                style = NoopType.footnote,
                                color = Palette.textSecondary,
                            )
                        }
                        if (!result.isSelf) {
                            IconButton(
                                enabled = !busy,
                                onClick = { onRequest(result.noopId) },
                            ) {
                                Icon(
                                    Icons.Filled.PersonAdd,
                                    contentDescription = stringResource(
                                        R.string.managed_friends_send_request,
                                    ),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ManagedRequests(
    requests: List<ManagedSocialRequest>,
    busy: Boolean,
    onDecision: (ManagedSocialRequest, Boolean) -> Unit,
    onBlock: (ManagedSocialRequest) -> Unit,
) {
    if (requests.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            stringResource(R.string.managed_friends_requests_title),
            style = NoopType.headline,
            color = Palette.textPrimary,
        )
        requests.forEach { request ->
            NoopCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ManagedAvatar(request.displayName)
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .padding(horizontal = 10.dp),
                    ) {
                        Text(
                            request.displayName,
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(
                                if (request.isIncoming) {
                                    R.string.managed_friends_request_incoming
                                } else {
                                    R.string.managed_friends_request_outgoing
                                },
                            ),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    if (request.isIncoming) {
                        IconButton(
                            enabled = !busy,
                            onClick = { onBlock(request) },
                        ) {
                            Icon(
                                Icons.Filled.Block,
                                contentDescription = stringResource(
                                    R.string.managed_friends_block_profile,
                                ),
                                tint = Palette.statusCritical,
                            )
                        }
                        IconButton(
                            enabled = !busy,
                            onClick = { onDecision(request, false) },
                        ) {
                            Icon(
                                Icons.Filled.Close,
                                contentDescription =
                                    stringResource(R.string.managed_friends_decline),
                            )
                        }
                        IconButton(
                            enabled = !busy,
                            onClick = { onDecision(request, true) },
                        ) {
                            Icon(
                                Icons.Filled.Check,
                                contentDescription =
                                    stringResource(R.string.managed_friends_accept),
                                tint = Palette.statusPositive,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ManagedFriendList(
    friends: List<ManagedSocialFriend>,
    busy: Boolean,
    onSettings: (ManagedSocialFriend) -> Unit,
    onPoke: (ManagedSocialFriend) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            stringResource(R.string.managed_friends_friends_title),
            style = NoopType.headline,
            color = Palette.textPrimary,
        )
        if (friends.isEmpty()) {
            NoopCard {
                ManagedLead(
                    Icons.Filled.Handshake,
                    stringResource(R.string.managed_friends_empty_title),
                    stringResource(R.string.managed_friends_empty_body),
                )
            }
        } else {
            friends.forEach { friend ->
                ManagedFriendCard(
                    friend = friend,
                    busy = busy,
                    onSettings = { onSettings(friend) },
                    onPoke = { onPoke(friend) },
                )
            }
        }
    }
}

@Composable
private fun ManagedFriendCard(
    friend: ManagedSocialFriend,
    busy: Boolean,
    onSettings: () -> Unit,
    onPoke: () -> Unit,
) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ManagedAvatar(friend.displayName)
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 10.dp),
                ) {
                    Text(
                        friend.displayName,
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        friend.latest?.day
                            ?: stringResource(R.string.managed_friends_waiting_shared_day),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                IconButton(onClick = onSettings, enabled = !busy) {
                    Icon(
                        Icons.Filled.Settings,
                        contentDescription =
                            stringResource(R.string.managed_friends_sharing_settings),
                    )
                }
            }
            friend.latest?.summary?.let { ManagedSummary(it) } ?: Text(
                stringResource(R.string.managed_friends_no_shared_details),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            ManagedBadges(friend.badges)
            if (friend.sharedWithMe.pokeAllowed) {
                NoopButton(
                    text = stringResource(R.string.managed_friends_poke_action),
                    leadingIcon = Icons.Filled.TouchApp,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = !busy,
                    onClick = onPoke,
                )
            }
        }
    }
}

@Composable
private fun ManagedSummary(summary: ManagedSocialSummary) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ManagedScore(
                stringResource(R.string.appwide_day_overview_recovery),
                summary.charge,
                Palette.chargeColor,
                Modifier.weight(1f),
            )
            ManagedScore(
                stringResource(R.string.managed_friends_effort),
                summary.effort,
                Palette.effortColor,
                Modifier.weight(1f),
            )
            ManagedScore(
                stringResource(R.string.managed_friends_rest),
                summary.rest,
                Palette.restColor,
                Modifier.weight(1f),
            )
        }
        val details = buildList {
            summary.sleepDuration?.let {
                add(stringResource(R.string.managed_friends_sleep_value, it / 60.0))
            }
            summary.hrv?.let {
                add(stringResource(R.string.managed_friends_hrv_value, it.roundToInt()))
            }
            summary.rhr?.let {
                add(stringResource(R.string.managed_friends_rhr_value, it.roundToInt()))
            }
        }
        if (details.isNotEmpty()) {
            Text(
                details.joinToString("  |  "),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
    }
}

@Composable
private fun ManagedScore(
    label: String,
    value: Double?,
    color: androidx.compose.ui.graphics.Color,
    modifier: Modifier,
) {
    Surface(
        color = Palette.surfaceInset,
        shape = RoundedCornerShape(6.dp),
        modifier = modifier,
    ) {
        Column(modifier = Modifier.padding(10.dp)) {
            Text(label, style = NoopType.overline, color = Palette.textTertiary)
            Text(
                value?.roundToInt()?.toString() ?: NoopDisplayFormat.MISSING,
                style = NoopType.title2,
                color = if (value == null) Palette.textTertiary else color,
            )
        }
    }
}

@Composable
private fun ManagedFriendsSettings(
    displayName: String,
    pokeOptIn: Boolean,
    quietStart: String,
    quietEnd: String,
    blockedProfiles: List<ManagedSocialBlockedProfile>,
    busy: Boolean,
    onDisplayNameChange: (String) -> Unit,
    onPokeChange: (Boolean) -> Unit,
    onQuietStartChange: (String) -> Unit,
    onQuietEndChange: (String) -> Unit,
    onSave: () -> Unit,
    onUnblock: (ManagedSocialBlockedProfile) -> Unit,
    onDelete: () -> Unit,
) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            ManagedLead(
                Icons.Filled.TouchApp,
                stringResource(R.string.managed_friends_settings_title),
                stringResource(R.string.managed_friends_settings_body),
            )
            OutlinedTextField(
                value = displayName,
                onValueChange = onDisplayNameChange,
                label = { Text(stringResource(R.string.friends_display_name)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            ManagedToggleRow(
                label = stringResource(R.string.managed_friends_allow_pokes),
                checked = pokeOptIn,
                onCheckedChange = onPokeChange,
            )
            if (pokeOptIn) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = quietStart,
                        onValueChange = onQuietStartChange,
                        label = { Text(stringResource(R.string.managed_friends_quiet_start)) },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        value = quietEnd,
                        onValueChange = onQuietEndChange,
                        label = { Text(stringResource(R.string.managed_friends_quiet_end)) },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            NoopButton(
                text = stringResource(R.string.managed_friends_save_settings),
                leadingIcon = Icons.Filled.Check,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !busy &&
                    displayName.trim().isNotEmpty() &&
                    parseMinute(quietStart) != null &&
                    parseMinute(quietEnd) != null,
                onClick = onSave,
            )
            HorizontalDivider(color = Palette.hairline)
            Text(
                stringResource(R.string.appwide_friends_data_boundary),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            if (blockedProfiles.isNotEmpty()) {
                HorizontalDivider(color = Palette.hairline)
                Text(
                    stringResource(
                        R.string.managed_friends_blocked_profiles,
                        blockedProfiles.size,
                    ),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                blockedProfiles.forEach { blocked ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        ManagedAvatar(blocked.displayName)
                        Text(
                            text = blocked.displayName,
                            style = NoopType.body,
                            color = Palette.textPrimary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier
                                .weight(1f)
                                .padding(horizontal = 10.dp),
                        )
                        IconButton(
                            onClick = { onUnblock(blocked) },
                            enabled = !busy,
                        ) {
                            Icon(
                                Icons.Filled.LockOpen,
                                contentDescription = stringResource(
                                    R.string.managed_friends_unblock_name,
                                    blocked.displayName,
                                ),
                            )
                        }
                    }
                }
            }
            NoopButton(
                text = stringResource(R.string.managed_friends_delete_action),
                leadingIcon = Icons.Filled.Delete,
                kind = NoopButtonKind.Tertiary,
                fullWidth = true,
                enabled = !busy,
                onClick = onDelete,
            )
        }
    }
}

@Composable
private fun ManagedFriendSettingsDialog(
    friend: ManagedSocialFriend,
    history: List<ManagedSocialFeedDay>,
    busy: Boolean,
    onDismiss: () -> Unit,
    onSave: (ManagedSocialVisibilityPatch) -> Unit,
    onRemove: () -> Unit,
    onBlock: () -> Unit,
) {
    var sharing by remember(friend.profileId) { mutableStateOf(friend.sharing) }
    var confirmRemove by remember(friend.profileId) { mutableStateOf(false) }
    var confirmBlock by remember(friend.profileId) { mutableStateOf(false) }

    if (confirmRemove) {
        ConfirmDialog(
            title = stringResource(
                R.string.managed_friends_remove_title,
                friend.displayName,
            ),
            body = stringResource(R.string.managed_friends_remove_body),
            action = stringResource(R.string.managed_friends_remove_friend),
            onDismiss = { confirmRemove = false },
            onConfirm = {
                confirmRemove = false
                onRemove()
            },
        )
    }
    if (confirmBlock) {
        ConfirmDialog(
            title = stringResource(
                R.string.managed_friends_block_title,
                friend.displayName,
            ),
            body = stringResource(R.string.managed_friends_block_body),
            action = stringResource(R.string.managed_friends_block_profile),
            onDismiss = { confirmBlock = false },
            onConfirm = {
                confirmBlock = false
                onBlock()
            },
        )
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = Palette.surfaceRaised,
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 680.dp),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
            ) {
                ManagedLead(
                    Icons.Filled.Settings,
                    friend.displayName,
                    stringResource(R.string.managed_friends_directional_sharing),
                )
                if (history.isNotEmpty()) {
                    Text(
                        stringResource(R.string.managed_friends_shared_history),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    history.forEachIndexed { index, day ->
                        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(
                                day.day,
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                            Text(
                                compactSummaryLabels(day.summary),
                                style = NoopType.body,
                                color = Palette.textPrimary,
                            )
                        }
                        if (index < history.lastIndex) {
                            HorizontalDivider(color = Palette.hairline)
                        }
                    }
                    HorizontalDivider(color = Palette.hairline)
                }
                ManagedSharingToggles(sharing) { sharing = it }
                NoopButton(
                    text = stringResource(R.string.managed_friends_save_sharing),
                    leadingIcon = Icons.Filled.Check,
                    fullWidth = true,
                    enabled = !busy,
                    onClick = {
                        onSave(
                            ManagedSocialVisibilityPatch(
                                charge = sharing.charge,
                                effort = sharing.effort,
                                rest = sharing.rest,
                                sleepDuration = sharing.sleepDuration,
                                hrv = sharing.hrv,
                                rhr = sharing.rhr,
                                pokeAllowed = sharing.pokeAllowed,
                            ),
                        )
                    },
                )
                HorizontalDivider(color = Palette.hairline)
                Text(
                    stringResource(R.string.managed_friends_they_share),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    sharingLabels(friend.sharedWithMe),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
                NoopButton(
                    text = stringResource(R.string.managed_friends_remove_friend),
                    leadingIcon = Icons.Filled.Delete,
                    kind = NoopButtonKind.Tertiary,
                    fullWidth = true,
                    enabled = !busy,
                    onClick = { confirmRemove = true },
                )
                NoopButton(
                    text = stringResource(R.string.managed_friends_block_profile),
                    leadingIcon = Icons.Filled.Block,
                    kind = NoopButtonKind.Destructive,
                    fullWidth = true,
                    enabled = !busy,
                    onClick = { confirmBlock = true },
                )
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) {
                    Text(stringResource(R.string.friends_action_cancel))
                }
            }
        }
    }
}

@Composable
private fun ManagedSharingToggles(
    value: ManagedSocialVisibility,
    onChange: (ManagedSocialVisibility) -> Unit,
) {
    listOf(
        R.string.appwide_day_overview_recovery to value.charge,
        R.string.managed_friends_effort to value.effort,
        R.string.managed_friends_rest to value.rest,
        R.string.managed_friends_sleep_duration to value.sleepDuration,
        R.string.managed_friends_hrv to value.hrv,
        R.string.managed_friends_rhr to value.rhr,
        R.string.managed_friends_allow_friend_poke to value.pokeAllowed,
    ).forEachIndexed { index, (label, checked) ->
        ManagedToggleRow(
            label = stringResource(label),
            checked = checked,
            onCheckedChange = { enabled ->
                onChange(
                    when (index) {
                        0 -> value.copy(charge = enabled)
                        1 -> value.copy(effort = enabled)
                        2 -> value.copy(rest = enabled)
                        3 -> value.copy(sleepDuration = enabled)
                        4 -> value.copy(hrv = enabled)
                        5 -> value.copy(rhr = enabled)
                        else -> value.copy(pokeAllowed = enabled)
                    },
                )
            },
        )
    }
}

@Composable
private fun ManagedToggleRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            label,
            style = NoopType.body,
            color = Palette.textPrimary,
            modifier = Modifier.weight(1f),
        )
        NoopToggleSwitch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ManagedBadges(badges: List<ManagedSocialBadge>) {
    if (badges.isEmpty()) return
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        badges.take(3).forEach { badge ->
            StatePill(
                title = when (badge.code) {
                    "connected" -> stringResource(R.string.managed_friends_badge_connected)
                    "steady_week" -> stringResource(R.string.managed_friends_badge_week)
                    "steady_month" -> stringResource(R.string.managed_friends_badge_month)
                    else -> stringResource(R.string.managed_friends_badge_progress)
                },
                tone = StrandTone.Positive,
                showsDot = true,
            )
        }
    }
}

@Composable
private fun ManagedLead(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    body: String,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = Palette.accent)
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = NoopType.headline, color = Palette.textPrimary)
            Text(body, style = NoopType.footnote, color = Palette.textSecondary)
        }
    }
}

@Composable
private fun ManagedAvatar(name: String) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(Palette.surfaceInset)
            .clearAndSetSemantics {},
    ) {
        Text(
            name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?",
            style = NoopType.headline,
            color = Palette.accent,
        )
    }
}

@Composable
private fun ManagedInviteDialog(
    link: String,
    busy: Boolean,
    onDismiss: () -> Unit,
    onShare: () -> Unit,
    onRevoke: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.managed_friends_invite_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.managed_friends_invite_body))
                Text(
                    link,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                )
                NoopButton(
                    text = stringResource(R.string.managed_friends_share_invite),
                    leadingIcon = Icons.Filled.Share,
                    fullWidth = true,
                    enabled = !busy && link.isNotBlank(),
                    onClick = onShare,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.friends_action_ok))
            }
        },
        dismissButton = {
            TextButton(onClick = onRevoke, enabled = !busy) {
                Text(
                    stringResource(R.string.managed_friends_revoke_invite),
                    color = Palette.statusCritical,
                )
            }
        },
    )
}

@Composable
private fun ConfirmDialog(
    title: String,
    body: String,
    action: String,
    destructive: Boolean = true,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(
                    action,
                    color = if (destructive) {
                        Palette.statusCritical
                    } else {
                        Palette.statusPositive
                    },
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.friends_action_cancel))
            }
        },
    )
}

private fun shareText(context: Context, subject: String, body: String) {
    context.startActivity(
        Intent.createChooser(
            Intent(Intent.ACTION_SEND)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_SUBJECT, subject)
                .putExtra(Intent.EXTRA_TEXT, body),
            context.getString(R.string.managed_friends_share),
        ),
    )
}

private fun minuteText(value: Int): String =
    "%02d:%02d".format(Locale.ROOT, value.coerceIn(0, 1439) / 60, value.coerceIn(0, 1439) % 60)

private fun parseMinute(value: String): Int? {
    val parts = value.trim().split(":")
    if (parts.size != 2) return null
    val hour = parts[0].toIntOrNull() ?: return null
    val minute = parts[1].toIntOrNull() ?: return null
    if (hour !in 0..23 || minute !in 0..59) return null
    return hour * 60 + minute
}

@Composable
private fun sharingLabels(value: ManagedSocialVisibility): String {
    val labels = buildList {
        if (value.charge) add(stringResource(R.string.appwide_day_overview_recovery))
        if (value.effort) add(stringResource(R.string.managed_friends_effort))
        if (value.rest) add(stringResource(R.string.managed_friends_rest))
        if (value.sleepDuration) {
            add(stringResource(R.string.managed_friends_sleep_duration))
        }
        if (value.hrv) add(stringResource(R.string.managed_friends_hrv))
        if (value.rhr) add(stringResource(R.string.managed_friends_rhr))
        if (value.pokeAllowed) {
            add(stringResource(R.string.managed_friends_poke_action))
        }
    }
    return labels.joinToString(", ").ifBlank {
        stringResource(R.string.managed_friends_nothing_shared)
    }
}

@Composable
private fun compactSummaryLabels(summary: ManagedSocialSummary): String {
    val labels = buildList {
        summary.charge?.let {
            add(
                "${stringResource(R.string.appwide_day_overview_recovery)} " +
                    it.roundToInt(),
            )
        }
        summary.effort?.let {
            add(
                "${stringResource(R.string.managed_friends_effort)} " +
                    it.roundToInt(),
            )
        }
        summary.rest?.let {
            add(
                "${stringResource(R.string.managed_friends_rest)} " +
                    it.roundToInt(),
            )
        }
        summary.sleepDuration?.let {
            add(stringResource(R.string.managed_friends_sleep_value, it / 60.0))
        }
        summary.hrv?.let {
            add(stringResource(R.string.managed_friends_hrv_value, it.roundToInt()))
        }
        summary.rhr?.let {
            add(stringResource(R.string.managed_friends_rhr_value, it.roundToInt()))
        }
    }
    return labels.joinToString("  |  ").ifBlank {
        stringResource(R.string.managed_friends_no_shared_details)
    }
}
