package com.noop.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.noop.NoopApplication
import com.noop.social.FriendContact
import com.noop.social.FriendInvite
import com.noop.social.FriendRequest
import com.noop.social.FriendVisibility
import com.noop.social.FriendsException
import com.noop.social.FriendsService
import com.noop.social.FriendsSetupState
import com.noop.social.FriendsSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

internal enum class FriendsAction {
    REFRESH,
    CREATE_PROFILE,
    JOIN,
    CREATE_INVITE,
    DECIDE_REQUEST,
    SAVE_PRIVACY,
    REMOVE_FRIEND,
    DELETE_PROFILE,
    DISCARD_PENDING,
}

internal enum class FriendsNoticeKind {
    PROFILE_READY,
    REQUEST_SENT,
    REQUEST_ACCEPTED,
    REQUEST_DECLINED,
    PRIVACY_SAVED,
    FRIEND_REMOVED,
    PROFILE_DELETED,
    PENDING_DISCARDED,
}

internal data class FriendsNotice(
    val kind: FriendsNoticeKind,
    val subject: String? = null,
)

internal enum class FriendsErrorKind {
    INPUT,
    NETWORK,
    SERVER,
    RESPONSE,
    STORAGE,
    UNKNOWN,
}

internal data class FriendsUiError(
    val kind: FriendsErrorKind,
    val detail: String? = null,
    val statusCode: Int? = null,
)

internal data class FriendsUiState(
    val setupState: FriendsSetupState,
    val profileName: String,
    val serverAddress: String,
    val snapshot: FriendsSnapshot = FriendsSnapshot(emptyList(), emptyList()),
    val action: FriendsAction? = null,
    val invite: FriendInvite? = null,
    val notice: FriendsNotice? = null,
    val error: FriendsUiError? = null,
    val summaryUploadPending: Boolean = false,
) {
    val friends: List<FriendContact> get() = snapshot.friends
    val requests: List<FriendRequest> get() = snapshot.requests
    val isBusy: Boolean get() = action != null
}

/**
 * Lifecycle owner for Android Friends.
 *
 * Network and persistence behavior stays in [FriendsService]. This model serializes user actions,
 * resolves the current registry device for every operation, and exposes immutable presentation state
 * so rotation cannot duplicate an invite, acceptance, privacy write, or profile deletion.
 */
internal class FriendsViewModel(app: Application) : AndroidViewModel(app) {
    private val noopApp = app as NoopApplication

    private val _state = MutableStateFlow(localState())
    val state: StateFlow<FriendsUiState> = _state.asStateFlow()

    /** Re-evaluate setup after returning from Backup & Sync, then fetch the current circle if ready. */
    fun onEnter() {
        if (_state.value.isBusy) return
        synchronizeLocalState()
        if (_state.value.setupState == FriendsSetupState.READY) refresh()
    }

    fun refresh() = launchSnapshotAction(FriendsAction.REFRESH) { activeDeviceId ->
        FriendsService.refresh(noopApp, noopApp.repository, activeDeviceId)
    }

    fun createProfile(displayName: String) =
        launchSnapshotAction(
            action = FriendsAction.CREATE_PROFILE,
            success = FriendsNotice(FriendsNoticeKind.PROFILE_READY),
        ) { activeDeviceId ->
            FriendsService.bootstrap(
                context = noopApp,
                repository = noopApp.repository,
                activeDeviceId = activeDeviceId,
                displayName = displayName,
            )
        }

    fun join(serverAddress: String, code: String, displayName: String) =
        launchSnapshotAction(
            action = FriendsAction.JOIN,
            success = FriendsNotice(FriendsNoticeKind.REQUEST_SENT),
        ) { activeDeviceId ->
            FriendsService.join(
                context = noopApp,
                repository = noopApp.repository,
                activeDeviceId = activeDeviceId,
                serverAddress = serverAddress,
                code = code,
                displayName = displayName,
            )
        }

    fun createInvite() {
        if (!begin(FriendsAction.CREATE_INVITE)) return
        viewModelScope.launch {
            runCatching { FriendsService.createInvite(noopApp) }
                .onSuccess { invite ->
                    _state.update { it.copy(invite = invite) }
                }
                .onFailure(::present)
            finish(FriendsAction.CREATE_INVITE)
        }
    }

    fun clearInvite() {
        _state.update { it.copy(invite = null) }
    }

    fun decide(request: FriendRequest, accept: Boolean) =
        launchSnapshotAction(
            action = FriendsAction.DECIDE_REQUEST,
            success = FriendsNotice(
                if (accept) FriendsNoticeKind.REQUEST_ACCEPTED
                else FriendsNoticeKind.REQUEST_DECLINED,
                request.displayName,
            ),
        ) { activeDeviceId ->
            FriendsService.decide(
                context = noopApp,
                repository = noopApp.repository,
                activeDeviceId = activeDeviceId,
                requestId = request.requestId,
                accept = accept,
            )
        }

    fun updatePrivacy(friend: FriendContact, visibility: FriendVisibility) =
        launchSnapshotAction(
            action = FriendsAction.SAVE_PRIVACY,
            success = FriendsNotice(FriendsNoticeKind.PRIVACY_SAVED, friend.displayName),
        ) { activeDeviceId ->
            FriendsService.updatePrivacy(
                context = noopApp,
                repository = noopApp.repository,
                activeDeviceId = activeDeviceId,
                friendId = friend.profileId,
                visibility = visibility,
            )
        }

    fun remove(friend: FriendContact) =
        launchSnapshotAction(
            action = FriendsAction.REMOVE_FRIEND,
            success = FriendsNotice(FriendsNoticeKind.FRIEND_REMOVED, friend.displayName),
        ) { activeDeviceId ->
            FriendsService.removeFriend(
                context = noopApp,
                repository = noopApp.repository,
                activeDeviceId = activeDeviceId,
                friendId = friend.profileId,
            )
        }

    fun leaveAndDelete() {
        if (!begin(FriendsAction.DELETE_PROFILE)) return
        viewModelScope.launch {
            runCatching { FriendsService.leaveAndDelete(noopApp) }
                .onSuccess {
                    _state.value = localState().copy(
                        notice = FriendsNotice(FriendsNoticeKind.PROFILE_DELETED),
                    )
                }
                .onFailure {
                    synchronizeLocalState()
                    present(it)
                }
            finish(FriendsAction.DELETE_PROFILE)
        }
    }

    fun discardPendingJoin() {
        if (!begin(FriendsAction.DISCARD_PENDING)) return
        viewModelScope.launch {
            runCatching { FriendsService.discardPendingJoin(noopApp) }
                .onSuccess {
                    _state.value = localState().copy(
                        notice = FriendsNotice(FriendsNoticeKind.PENDING_DISCARDED),
                    )
                }
                .onFailure {
                    synchronizeLocalState()
                    present(it)
                }
            finish(FriendsAction.DISCARD_PENDING)
        }
    }

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    fun dismissNotice() {
        _state.update { it.copy(notice = null) }
    }

    private fun launchSnapshotAction(
        action: FriendsAction,
        success: FriendsNotice? = null,
        block: suspend (String) -> com.noop.social.FriendsRefreshResult,
    ) {
        if (!begin(action)) return
        viewModelScope.launch {
            runCatching { block(activeDeviceId()) }
                .onSuccess { result ->
                    synchronizeLocalState()
                    _state.update {
                        it.copy(
                            snapshot = result.snapshot,
                            notice = success ?: it.notice,
                            summaryUploadPending = !result.summaryUploaded,
                        )
                    }
                }
                .onFailure {
                    synchronizeLocalState()
                    present(it)
                }
            finish(action)
        }
    }

    private fun begin(action: FriendsAction): Boolean {
        if (_state.value.isBusy) return false
        _state.update { it.copy(action = action, error = null, notice = null) }
        return true
    }

    private fun finish(action: FriendsAction) {
        _state.update { current ->
            if (current.action == action) current.copy(action = null) else current
        }
    }

    private suspend fun activeDeviceId(): String =
        noopApp.deviceRegistry.activeDeviceId()
            ?.takeIf(String::isNotBlank)
            ?: noopApp.activeDeviceId

    private fun synchronizeLocalState() {
        val setup = FriendsService.setupState(noopApp)
        _state.update {
            it.copy(
                setupState = setup,
                profileName = FriendsService.profileName(noopApp),
                serverAddress = FriendsService.serverAddress(noopApp).orEmpty(),
                snapshot = if (setup == FriendsSetupState.READY) {
                    it.snapshot
                } else {
                    FriendsSnapshot(emptyList(), emptyList())
                },
            )
        }
    }

    private fun localState(): FriendsUiState = FriendsUiState(
        setupState = FriendsService.setupState(noopApp),
        profileName = FriendsService.profileName(noopApp),
        serverAddress = FriendsService.serverAddress(noopApp).orEmpty(),
    )

    private fun present(error: Throwable) {
        if (error is CancellationException) throw error
        val presentation = when (error) {
            is FriendsException.InvalidInput ->
                FriendsUiError(FriendsErrorKind.INPUT, detail = error.message)
            is FriendsException.Network ->
                FriendsUiError(FriendsErrorKind.NETWORK)
            is FriendsException.Server ->
                FriendsUiError(
                    FriendsErrorKind.SERVER,
                    detail = error.message,
                    statusCode = error.statusCode,
                )
            is FriendsException.InvalidResponse ->
                FriendsUiError(FriendsErrorKind.RESPONSE)
            is FriendsException.Storage ->
                FriendsUiError(FriendsErrorKind.STORAGE)
            else ->
                FriendsUiError(FriendsErrorKind.UNKNOWN)
        }
        _state.update { it.copy(error = presentation) }
    }
}
