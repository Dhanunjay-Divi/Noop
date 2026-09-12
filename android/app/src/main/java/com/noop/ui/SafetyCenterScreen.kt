package com.noop.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PhoneInTalk
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.ble.WhoopConnectionService
import com.noop.managed.ManagedCloudPhase
import com.noop.managed.ManagedCloudService
import com.noop.managed.ManagedSafetyContacts
import com.noop.safety.SafetyCheckInPolicy
import com.noop.safety.SafetyCheckInReminderPrefs
import com.noop.safety.SafetyCheckInReminderScheduler
import com.noop.safety.SafetyCheckInState
import com.noop.safety.SafetyContactStatus
import com.noop.safety.SafetyLocation
import com.noop.safety.SafetyLocationCapture
import com.noop.safety.SafetyDeliveryStatus
import com.noop.safety.SafetyIncidentStatus
import com.noop.safety.SafetyPagingController
import com.noop.safety.SafetyPagingSetupState
import com.noop.safety.SafetyPageTrigger
import com.noop.safety.SafetyPagingPrefs
import com.noop.safety.SafetyResponseDecision
import com.noop.safety.SafetyShareCopy
import com.noop.safety.SafetyShareIntent
import com.noop.safety.SafetyShareMessage
import com.noop.safety.SafetySosGesturePrefs
import com.noop.safety.SafetyStatusNotifications
import com.noop.safety.shouldShowAllContactsFailed
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class SafetyLocationState { Idle, Requesting, Ready, Denied, Failed }
private enum class SafetyIncidentAction { Resolve, Cancel }

internal fun shouldDisableBandSosPreference(
    enabled: Boolean,
    phase: ManagedCloudPhase,
    contacts: ManagedSafetyContacts?,
): Boolean =
    enabled &&
        phase == ManagedCloudPhase.ENROLLED &&
        contacts != null &&
        contacts.contacts.count { it.role == "contact" } < contacts.minimumRequired

private enum class CheckInPreset(val seconds: Long, val labelRes: Int) {
    Minutes15(15 * 60L, R.string.safety_duration_15_minutes),
    Minutes30(30 * 60L, R.string.safety_duration_30_minutes),
    Hour1(60 * 60L, R.string.safety_duration_1_hour),
    Hours2(2 * 60 * 60L, R.string.safety_duration_2_hours),
}

/**
 * Personal-safety tools: explicitly page accepted contacts, prepare a one-shot location message, and
 * arm a local check-in reminder. Wellness signals never silently page another person.
 */
@Composable
fun SafetyCenterScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val pagingController = remember(context) { SafetyPagingController(context) }
    val managedService = remember(context) { ManagedCloudService.get(context) }
    val managedState by managedService.state.collectAsStateWithLifecycle()
    var shareIntent by remember { mutableStateOf(SafetyShareIntent.FEEL_UNSAFE) }
    var displayName by remember { mutableStateOf("") }
    var note by remember { mutableStateOf("") }
    var detailsExpanded by remember { mutableStateOf(false) }
    // Precise location is additive, never a prerequisite for asking a trusted contact for help.
    var includeLocation by remember { mutableStateOf(false) }
    var locationState by remember { mutableStateOf(SafetyLocationState.Idle) }
    var location by remember { mutableStateOf<SafetyLocation?>(null) }
    var nowUnix by remember { mutableLongStateOf(System.currentTimeMillis() / 1_000L) }
    val locationIsReady =
        locationState == SafetyLocationState.Ready && location?.isUsable(nowUnix) == true
    val canSharePreparedMessage = !includeLocation || locationIsReady
    var preset by remember { mutableStateOf(CheckInPreset.Minutes30) }
    var dueAtUnix by remember { mutableLongStateOf(SafetyCheckInReminderPrefs.dueAtUnix(context)) }
    var notice by remember { mutableStateOf<String?>(null) }
    var pendingPreset by remember { mutableStateOf<CheckInPreset?>(null) }
    var offerNotificationSettings by remember { mutableStateOf(false) }
    var confirmsContactPage by remember { mutableStateOf(false) }
    var pendingIncidentAction by remember { mutableStateOf<SafetyIncidentAction?>(null) }
    var sosGestureEnabled by remember {
        mutableStateOf(SafetySosGesturePrefs.enabled(context))
    }
    var sosGestureEvents by remember {
        mutableStateOf(SafetySosGesturePrefs.requiredEvents(context))
    }
    var sosGestureSharesLocation by remember {
        mutableStateOf(SafetySosGesturePrefs.sharesLocation(context))
    }
    var shareDurationHours by remember {
        mutableStateOf(SafetyPagingPrefs.shareDurationHours(context))
    }
    var sosNotificationsAvailable by remember {
        mutableStateOf(SafetyStatusNotifications.deliveryAvailable(context))
    }
    val managedBandSosReady =
        managedState.phase == ManagedCloudPhase.ENROLLED &&
            managedState.safetyContacts?.let { contacts ->
                contacts.contacts.count { it.role == "contact" } >=
                    contacts.minimumRequired
            } == true
    val shouldDisableBandSos = shouldDisableBandSosPreference(
        enabled = sosGestureEnabled,
        phase = managedState.phase,
        contacts = managedState.safetyContacts,
    )
    var locationPermissionRevision by remember { mutableIntStateOf(0) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                locationPermissionRevision += 1
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val hasForegroundLocation = remember(locationPermissionRevision, context) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }
    val hasBackgroundLocation = remember(locationPermissionRevision, context) {
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
    }
    val sosLocationReady = hasForegroundLocation && hasBackgroundLocation
    val bandSosReady = managedBandSosReady
    val reminderAvailability = SafetyCheckInReminderScheduler.deliveryAvailability(context)
    val scheduleFailure = stringResource(R.string.safety_error_schedule)
    val notificationsOffStart = stringResource(R.string.safety_error_notifications_start)
    val channelOffStart = stringResource(R.string.safety_error_channel_start)
    val sosThreeLabel = stringResource(R.string.safety_sos_gesture_three)
    val sosFourLabel = stringResource(R.string.safety_sos_gesture_four)
    val duration8Label = stringResource(R.string.safety_sos_duration_8_hours)
    val duration12Label = stringResource(R.string.safety_sos_duration_12_hours)
    val safetyShareCopy = SafetyShareCopy(
        needHelpNowOpening = stringResource(R.string.safety_message_need_help_opening),
        feelUnsafeOpening = stringResource(R.string.safety_message_feel_unsafe_opening),
        missedCheckInOpening = stringResource(R.string.safety_message_missed_opening),
        immediateDangerInstruction = stringResource(R.string.safety_message_immediate_danger),
        locationLabel = stringResource(R.string.safety_message_location_label),
        locationCapturedFormat = stringResource(R.string.safety_message_location_captured_format),
        locationCapturedAccuracyFormat =
            stringResource(R.string.safety_message_location_accuracy_format),
        noteLabel = stringResource(R.string.safety_message_note_label),
        preparedAtFormat = stringResource(R.string.safety_message_prepared_at_format),
        deliveryBoundary = stringResource(R.string.safety_message_delivery_boundary),
    )

    fun openAppSettings() {
        context.startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${context.packageName}"),
            ),
        )
    }

    fun openReminderSettings() {
        runCatching {
            context.startActivity(SafetyCheckInReminderScheduler.notificationSettingsIntent(context))
        }.onFailure {
            openAppSettings()
        }
    }

    fun captureLocation() {
        location = null
        locationState = SafetyLocationState.Requesting
        SafetyLocationCapture.request(context) { captured ->
            location = captured
            locationState = if (captured?.isUsable(System.currentTimeMillis() / 1_000L) == true) {
                SafetyLocationState.Ready
            } else {
                SafetyLocationState.Failed
            }
        }
    }

    val locationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { result ->
        if (result.values.any { it }) captureLocation() else locationState = SafetyLocationState.Denied
    }
    val sosLocationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) {
        locationPermissionRevision += 1
    }

    fun requestLocation() {
        val granted =
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        if (granted) {
            captureLocation()
        } else {
            locationPermissionLauncher.launch(
                arrayOf(
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                    Manifest.permission.ACCESS_FINE_LOCATION,
                ),
            )
        }
    }

    fun armCheckIn(option: CheckInPreset) {
        val startedAt = System.currentTimeMillis() / 1_000L
        val due = SafetyCheckInPolicy.dueAtUnix(startedAt, option.seconds)
        if (due == null) {
            offerNotificationSettings = false
            notice = scheduleFailure
            return
        }
        val availability = SafetyCheckInReminderScheduler.deliveryAvailability(context)
        if (availability != SafetyCheckInReminderScheduler.DeliveryAvailability.AVAILABLE) {
            offerNotificationSettings = true
            notice = when (availability) {
                SafetyCheckInReminderScheduler.DeliveryAvailability.CHANNEL_OFF ->
                    channelOffStart
                SafetyCheckInReminderScheduler.DeliveryAvailability.NOTIFICATIONS_OFF ->
                    notificationsOffStart
                SafetyCheckInReminderScheduler.DeliveryAvailability.AVAILABLE ->
                    scheduleFailure
            }
            return
        }
        if (!SafetyCheckInReminderScheduler.schedule(context, due)) {
            offerNotificationSettings = false
            notice = scheduleFailure
            return
        }
        dueAtUnix = due
        nowUnix = startedAt
        offerNotificationSettings = false
    }

    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val option = pendingPreset
        pendingPreset = null
        if (granted && option != null) armCheckIn(option)
        else {
            offerNotificationSettings = true
            notice = notificationsOffStart
        }
    }
    val sosNotificationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) {
        sosNotificationsAvailable = SafetyStatusNotifications.deliveryAvailable(context)
        val enabled = managedService.bandSosSetupReady()
        sosGestureEnabled = enabled
        SafetySosGesturePrefs.setEnabled(context, enabled)
        if (enabled) WhoopConnectionService.start(context)
    }

    fun startCheckIn() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingPreset = preset
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        armCheckIn(preset)
    }

    LaunchedEffect(Unit) {
        while (true) {
            nowUnix = System.currentTimeMillis() / 1_000L
            delay(1_000L)
        }
    }
    LaunchedEffect(managedService) {
        managedService.bootstrap()
        if (managedService.state.value.phase == ManagedCloudPhase.ENROLLED) {
            managedService.refreshSafety()
        }
    }
    LaunchedEffect(shouldDisableBandSos) {
        if (shouldDisableBandSos) {
            sosGestureEnabled = false
            SafetySosGesturePrefs.setEnabled(context, false)
        }
    }
    LaunchedEffect(pagingController) {
        while (true) {
            sosNotificationsAvailable =
                SafetyStatusNotifications.deliveryAvailable(context)
            pagingController.refreshLatestIncident()
            delay(5_000L)
        }
    }

    if (notice != null) {
        AlertDialog(
            onDismissRequest = { notice = null },
            title = { Text(stringResource(R.string.safety_reminder_alert_title)) },
            text = { Text(checkNotNull(notice)) },
            confirmButton = {
                TextButton(onClick = { notice = null }) {
                    Text(stringResource(R.string.safety_ok))
                }
            },
            dismissButton = if (offerNotificationSettings) {
                {
                    TextButton(
                        onClick = {
                            notice = null
                            openReminderSettings()
                        },
                    ) { Text(stringResource(R.string.safety_settings_open)) }
                }
            } else {
                null
            },
        )
    }

    if (confirmsContactPage) {
        AlertDialog(
            onDismissRequest = { confirmsContactPage = false },
            title = { Text(stringResource(R.string.safety_page_confirm_title)) },
            text = {
                Text(stringResource(R.string.safety_page_confirm_body))
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmsContactPage = false
                        scope.launch {
                            pagingController.pageAcceptedContacts(
                                shareDurationHours = shareDurationHours,
                            )
                        }
                    },
                ) {
                    Text(
                        stringResource(R.string.safety_page_confirm_action),
                        color = Palette.statusCritical,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmsContactPage = false }) {
                    Text(stringResource(R.string.safety_cancel))
                }
            },
        )
    }

    pendingIncidentAction?.let { action ->
        AlertDialog(
            onDismissRequest = { pendingIncidentAction = null },
            title = { Text(stringResource(R.string.safety_page_update_title)) },
            text = {
                Text(
                    if (action == SafetyIncidentAction.Resolve) {
                        stringResource(R.string.safety_page_resolve_guidance)
                    } else {
                        stringResource(R.string.safety_page_cancel_guidance)
                    },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val incident = pagingController.lastDispatch
                        pendingIncidentAction = null
                        if (incident != null) {
                            scope.launch {
                                if (action == SafetyIncidentAction.Resolve) {
                                    pagingController.resolve(incident)
                                } else {
                                    pagingController.cancel(incident)
                                }
                            }
                        }
                    },
                ) {
                    Text(
                        if (action == SafetyIncidentAction.Resolve) {
                            stringResource(R.string.safety_page_resolve_action)
                        } else {
                            stringResource(R.string.safety_page_cancel_action)
                        },
                        color = if (action == SafetyIncidentAction.Cancel) {
                            Palette.statusCritical
                        } else {
                            Palette.textPrimary
                        },
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingIncidentAction = null }) {
                    Text(stringResource(R.string.safety_page_keep_open))
                }
            },
        )
    }

    val state = SafetyCheckInPolicy.state(dueAtUnix.takeIf { it > 0L }, nowUnix)
    ScreenScaffold(
        title = stringResource(R.string.safety_title),
        subtitle = stringResource(R.string.safety_subtitle),
    ) {
        NoopCard(tint = Palette.statusCritical) {
            Row(
                modifier = Modifier.semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(Icons.Filled.Warning, contentDescription = null, tint = Palette.statusCritical)
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    Text(
                        stringResource(R.string.safety_emergency_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.safety_emergency_body),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            }
        }

        ManagedSafetySection(
            currentLocation = location,
            locationReady = locationIsReady,
            foregroundLocationReady = hasForegroundLocation,
            backgroundLocationReady = hasBackgroundLocation,
            onRequestLocation = ::requestLocation,
            onRequestBackgroundLocation = ::openAppSettings,
            durationHours = shareDurationHours,
            onDurationHoursChange = { hours ->
                shareDurationHours = if (hours == 12) 12 else 8
                SafetyPagingPrefs.setShareDurationHours(
                    context,
                    shareDurationHours,
                )
            },
        )

        SectionHeader(
            stringResource(R.string.managed_safety_fallback_title),
            overline = stringResource(R.string.managed_safety_fallback_overline),
        )
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
                Text(
                    stringResource(R.string.managed_safety_fallback_body),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
                SafetyContactsSetup(controller = pagingController)
            }
        }

        SectionHeader(
            stringResource(R.string.safety_page_section),
            overline = "SOS",
        )
        NoopCard(tint = Palette.statusCritical) {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                Row(
                    modifier = Modifier.semantics(mergeDescendants = true) {},
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        Icons.Filled.PhoneInTalk,
                        contentDescription = null,
                        tint = Palette.statusCritical,
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
                        Text(
                            stringResource(R.string.safety_page_title),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(R.string.safety_page_body),
                            style = NoopType.body,
                            color = Palette.textSecondary,
                        )
                    }
                }
                Text(
                    stringResource(R.string.safety_sos_duration_title),
                    style = NoopType.overline,
                    color = Palette.textTertiary,
                )
                SegmentedPillControl(
                    items = listOf(8, 12),
                    selection = shareDurationHours,
                    label = { if (it == 12) duration12Label else duration8Label },
                    accessibilityLabel = {
                        if (it == 12) duration12Label else duration8Label
                    },
                    onSelect = { hours ->
                        shareDurationHours = if (hours == 12) 12 else 8
                        SafetyPagingPrefs.setShareDurationHours(
                            context,
                            shareDurationHours,
                        )
                    },
                )
                Text(
                    stringResource(R.string.safety_sos_duration_help),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                HorizontalDivider(color = Palette.hairline)
                Row(
                    modifier = Modifier.semantics(mergeDescendants = true) {},
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        Icons.Filled.LocationOn,
                        contentDescription = null,
                        tint = if (sosLocationReady) {
                            Palette.statusPositive
                        } else {
                            Palette.statusWarning
                        },
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                    ) {
                        Text(
                            stringResource(R.string.safety_sos_location_title),
                            style = NoopType.body,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(
                                if (sosLocationReady) {
                                    R.string.safety_sos_location_ready
                                } else {
                                    R.string.safety_sos_location_permission
                                },
                            ),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                }
                if (!sosLocationReady) {
                    NoopButton(
                        text = stringResource(
                            if (hasForegroundLocation) {
                                R.string.safety_sos_location_settings
                            } else {
                                R.string.safety_sos_location_enable
                            },
                        ),
                        leadingIcon = Icons.Filled.MyLocation,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                    ) {
                        if (hasForegroundLocation) {
                            openAppSettings()
                        } else {
                            sosLocationPermissionLauncher.launch(
                                arrayOf(
                                    Manifest.permission.ACCESS_COARSE_LOCATION,
                                    Manifest.permission.ACCESS_FINE_LOCATION,
                                ),
                            )
                        }
                    }
                }
                Text(
                    stringResource(R.string.safety_sos_location_retention),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                NoopButton(
                    text = if (pagingController.isBusy) {
                        stringResource(R.string.safety_page_submitting)
                    } else {
                        stringResource(R.string.safety_page_submit)
                    },
                    leadingIcon = Icons.Filled.Warning,
                    kind = NoopButtonKind.Destructive,
                    fullWidth = true,
                    enabled = pagingController.canPage,
                ) {
                    confirmsContactPage = true
                }
                if (!pagingController.canPage) {
                    Text(
                        when {
                            pagingController.setupState != SafetyPagingSetupState.READY ->
                                stringResource(R.string.safety_page_disabled_setup)
                            !pagingController.pagingConfigured ||
                                pagingController.pagingEnabled == false ->
                                stringResource(R.string.safety_page_disabled_delivery)
                            pagingController.activeIncident != null ->
                                stringResource(R.string.safety_page_disabled_active)
                            else ->
                                stringResource(R.string.safety_page_disabled_contacts)
                        },
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                }
                pagingController.lastDispatch?.let { dispatch ->
                    val allContactsFailed = shouldShowAllContactsFailed(
                        dispatch.status,
                        dispatch.contactSummary,
                    )
                    val submitted = dispatch.deliveries.count {
                        it.status in setOf(
                            SafetyDeliveryStatus.QUEUED,
                            SafetyDeliveryStatus.SENT,
                            SafetyDeliveryStatus.DELIVERED,
                        )
                    }
                    val pending = dispatch.deliveries.count {
                        it.status in setOf(
                            SafetyDeliveryStatus.PENDING,
                            SafetyDeliveryStatus.SUBMITTING,
                            SafetyDeliveryStatus.LEASED,
                            SafetyDeliveryStatus.RETRY_WAIT,
                        )
                    }
                    val failed = dispatch.deliveries.count {
                        it.status in setOf(
                            SafetyDeliveryStatus.FAILED,
                            SafetyDeliveryStatus.UNKNOWN,
                        )
                    }
                    HorizontalDivider(color = Palette.hairline)
                    StatePill(
                        incidentStatusLabel(dispatch.status),
                        tone = incidentStatusTone(dispatch.status),
                    )
                    if (!allContactsFailed) {
                        Text(
                            incidentStatusDetail(
                                dispatch.status,
                                dispatch.acknowledgedContactDisplayName,
                            ),
                            style = NoopType.body,
                            color = Palette.textSecondary,
                        )
                    }
                    Text(
                        stringResource(R.string.safety_page_why_started),
                        style = NoopType.overline,
                        color = Palette.textTertiary,
                    )
                    Row(
                        modifier = Modifier.semantics(mergeDescendants = true) {},
                        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Icon(
                            when (dispatch.trigger) {
                                SafetyPageTrigger.BAND_SOS -> Icons.Filled.Shield
                                SafetyPageTrigger.VALIDATED_FALL -> Icons.Filled.Warning
                                SafetyPageTrigger.MANUAL_SOS -> Icons.Filled.PhoneInTalk
                            },
                            contentDescription = null,
                            tint = Palette.statusWarning,
                        )
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                        ) {
                            Text(
                                stringResource(
                                    when (dispatch.trigger) {
                                        SafetyPageTrigger.BAND_SOS ->
                                            R.string.safety_page_reason_band
                                        SafetyPageTrigger.VALIDATED_FALL ->
                                            R.string.safety_page_reason_fall
                                        SafetyPageTrigger.MANUAL_SOS ->
                                            R.string.safety_page_reason_app
                                    },
                                ),
                                style = NoopType.body,
                                color = Palette.textSecondary,
                            )
                            if (dispatch.trigger == SafetyPageTrigger.VALIDATED_FALL) {
                                Text(
                                    stringResource(
                                        R.string.safety_page_reason_observation,
                                    ),
                                    style = NoopType.caption,
                                    color = Palette.textTertiary,
                                )
                            }
                        }
                    }
                    dispatch.escalationRounds?.takeIf {
                        it > 1 &&
                            dispatch.status in setOf(
                                SafetyIncidentStatus.OPEN,
                                SafetyIncidentStatus.PENDING,
                            )
                    }?.let { rounds ->
                        Text(
                            stringResource(
                                R.string.safety_page_escalation_format,
                                rounds,
                            ),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                    dispatch.contactSummary?.let { summary ->
                        if (
                            summary.targeted > 0 &&
                            summary.reached in 0..summary.targeted
                        ) {
                            val reachedAt = summary.lastReachedAt
                                ?.let { runCatching { Instant.parse(it) }.getOrNull() }
                                ?.let {
                                    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
                                        .withZone(ZoneId.systemDefault())
                                        .format(it)
                                }
                            Text(
                                if (reachedAt == null) {
                                    stringResource(
                                        R.string.safety_page_contacts_reached_format,
                                        summary.reached,
                                        summary.targeted,
                                    )
                                } else {
                                    stringResource(
                                        R.string.safety_page_contacts_reached_at_format,
                                        summary.reached,
                                        summary.targeted,
                                        reachedAt,
                                    )
                                },
                                style = NoopType.body,
                                color = when {
                                    allContactsFailed -> Palette.statusCritical
                                    summary.reached > 0 -> Palette.statusPositive
                                    else -> Palette.textSecondary
                                },
                            )
                        }
                    }
                    if (allContactsFailed) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .background(Palette.statusCritical.copy(alpha = 0.12f))
                                .padding(Metrics.space12),
                            verticalArrangement = Arrangement.spacedBy(Metrics.space12),
                        ) {
                            Row(
                                modifier = Modifier.semantics(mergeDescendants = true) {},
                                horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                                verticalAlignment = Alignment.Top,
                            ) {
                                Icon(
                                    Icons.Filled.Warning,
                                    contentDescription = null,
                                    tint = Palette.statusCritical,
                                )
                                Column(
                                    modifier = Modifier.weight(1f),
                                    verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                                ) {
                                    Text(
                                        stringResource(
                                            R.string.safety_page_all_contacts_failed_title,
                                        ),
                                        style = NoopType.headline,
                                        color = Palette.statusCritical,
                                    )
                                    Text(
                                        stringResource(R.string.safety_page_detail_failed),
                                        style = NoopType.body,
                                        color = Palette.textPrimary,
                                    )
                                }
                            }
                            pagingController.contacts
                                .filter {
                                    it.status == SafetyContactStatus.ACCEPTED &&
                                        SafetyPagingController.isStrictE164(it.phoneE164)
                                }
                                .forEach { contact ->
                                    NoopButton(
                                        text = stringResource(
                                            R.string.safety_page_call_contact_format,
                                            contact.displayName,
                                        ),
                                        leadingIcon = Icons.Filled.PhoneInTalk,
                                        kind = NoopButtonKind.Secondary,
                                        fullWidth = true,
                                    ) {
                                        runCatching {
                                            context.startActivity(
                                                Intent(
                                                    Intent.ACTION_DIAL,
                                                    Uri.fromParts(
                                                        "tel",
                                                        contact.phoneE164,
                                                        null,
                                                    ),
                                                ),
                                            )
                                        }
                                    }
                                }
                        }
                    }
                    if (dispatch.contactSummary == null) {
                        val deliverySummary = stringResource(
                            R.string.safety_page_delivery_counts_format,
                            submitted,
                            pending,
                            failed,
                        )
                        val replaySummary = stringResource(R.string.safety_page_safe_retry)
                        Text(
                            if (dispatch.idempotentReplay) {
                                listOf(deliverySummary, replaySummary).joinToString(" · ")
                            } else {
                                deliverySummary
                            },
                            style = NoopType.caption,
                            color = if (failed == 0) {
                                Palette.textTertiary
                            } else {
                                Palette.statusWarning
                            },
                        )
                    } else if (dispatch.idempotentReplay) {
                        Text(
                            stringResource(R.string.safety_page_safe_retry),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                    if (dispatch.responses.isNotEmpty()) {
                        Text(
                            stringResource(R.string.safety_page_contact_responses),
                            style = NoopType.overline,
                            color = Palette.textTertiary,
                        )
                        dispatch.responses.forEach { response ->
                            Text(
                                if (response.decision == SafetyResponseDecision.RESPONDING) {
                                    stringResource(
                                        R.string.safety_page_responding_format,
                                        response.contactDisplayName,
                                    )
                                } else {
                                    stringResource(
                                        R.string.safety_page_cannot_respond_format,
                                        response.contactDisplayName,
                                    )
                                },
                                style = NoopType.footnote,
                                color = if (
                                    response.decision == SafetyResponseDecision.RESPONDING
                                ) {
                                    Palette.statusPositive
                                } else {
                                    Palette.textSecondary
                                },
                            )
                        }
                    }
                    dispatch.latestLocation?.let { latest ->
                        HorizontalDivider(color = Palette.hairline)
                        Row(
                            modifier = Modifier.semantics(mergeDescendants = true) {},
                            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Icon(
                                Icons.Filled.LocationOn,
                                contentDescription = null,
                                tint = Palette.statusPositive,
                            )
                            Column(
                                modifier = Modifier.weight(1f),
                                verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                            ) {
                                Text(
                                    stringResource(R.string.safety_sos_location_latest),
                                    style = NoopType.body,
                                    color = Palette.textPrimary,
                                )
                                latest.horizontalAccuracyMeters?.let { accuracy ->
                                    Text(
                                        stringResource(
                                            R.string.safety_sos_location_accuracy_format,
                                            accuracy.roundToInt(),
                                        ),
                                        style = NoopType.caption,
                                        color = Palette.textTertiary,
                                    )
                                }
                            }
                        }
                        NoopButton(
                            text = stringResource(R.string.safety_sos_location_open_maps),
                            leadingIcon = Icons.Filled.LocationOn,
                            kind = NoopButtonKind.Secondary,
                            fullWidth = true,
                        ) {
                            val coordinates = "${latest.latitude},${latest.longitude}"
                            val uri = Uri.parse(
                                "https://www.google.com/maps/search/?api=1&query=$coordinates",
                            )
                            runCatching {
                                context.startActivity(Intent(Intent.ACTION_VIEW, uri))
                            }
                        }
                    }
                    if (dispatch.status in setOf(
                            SafetyIncidentStatus.OPEN,
                            SafetyIncidentStatus.ACKNOWLEDGED,
                            SafetyIncidentStatus.PENDING,
                        )
                    ) {
                        NoopButton(
                            text = stringResource(R.string.safety_page_resolve_action),
                            leadingIcon = Icons.Filled.CheckCircle,
                            kind = NoopButtonKind.Primary,
                            fullWidth = true,
                            enabled = !pagingController.isBusy,
                        ) {
                            pendingIncidentAction = SafetyIncidentAction.Resolve
                        }
                        NoopButton(
                            text = stringResource(R.string.safety_page_cancel_action),
                            leadingIcon = Icons.Filled.Warning,
                            kind = NoopButtonKind.Secondary,
                            fullWidth = true,
                            enabled = !pagingController.isBusy,
                        ) {
                            pendingIncidentAction = SafetyIncidentAction.Cancel
                        }
                    }
                }

                HorizontalDivider(color = Palette.hairline)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .toggleable(
                            value = sosGestureEnabled,
                            enabled = bandSosReady || sosGestureEnabled,
                            role = Role.Switch,
                            onValueChange = { enabled ->
                                if (!enabled) {
                                    sosGestureEnabled = false
                                    SafetySosGesturePrefs.setEnabled(context, false)
                                } else if (
                                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                                    ContextCompat.checkSelfPermission(
                                        context,
                                        Manifest.permission.POST_NOTIFICATIONS,
                                    ) != PackageManager.PERMISSION_GRANTED
                                ) {
                                    sosNotificationPermissionLauncher.launch(
                                        Manifest.permission.POST_NOTIFICATIONS,
                                    )
                                } else if (managedService.bandSosSetupReady()) {
                                    sosNotificationsAvailable =
                                        SafetyStatusNotifications.deliveryAvailable(context)
                                    val allowed = true
                                    sosGestureEnabled = allowed
                                    SafetySosGesturePrefs.setEnabled(context, allowed)
                                    if (allowed) WhoopConnectionService.start(context)
                                }
                            },
                        )
                        .padding(vertical = Metrics.space4)
                        .semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                    ) {
                        Text(
                            stringResource(R.string.safety_sos_gesture_title),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(R.string.safety_sos_gesture_subtitle),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    Spacer(Modifier.width(Metrics.space12))
                    NoopToggleSwitch(
                        checked = sosGestureEnabled,
                        onCheckedChange = null,
                    )
                }
                if (!bandSosReady) {
                    Text(
                        managedService.bandSosSetupMessage(),
                        style = NoopType.caption,
                        color = Palette.statusWarning,
                    )
                }

                if (sosGestureEnabled) {
                    Text(
                        stringResource(R.string.safety_sos_gesture_repeats),
                        style = NoopType.overline,
                        color = Palette.textTertiary,
                    )
                    SegmentedPillControl(
                        items = listOf(3, 4),
                        selection = sosGestureEvents,
                        label = { if (it == 3) sosThreeLabel else sosFourLabel },
                        accessibilityLabel = {
                            if (it == 3) sosThreeLabel else sosFourLabel
                        },
                        onSelect = { count ->
                            sosGestureEvents = count
                            SafetySosGesturePrefs.setRequiredEvents(context, count)
                        },
                        adaptsToAvailableWidth = true,
                    )
                    Text(
                        stringResource(
                            R.string.safety_sos_gesture_help_format,
                            sosGestureEvents,
                        ),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                    Text(
                        stringResource(R.string.safety_sos_gesture_priority),
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .toggleable(
                                value = sosGestureSharesLocation,
                                role = Role.Switch,
                                onValueChange = { enabled ->
                                    sosGestureSharesLocation = enabled
                                    SafetySosGesturePrefs.setSharesLocation(context, enabled)
                                    if (enabled && !hasForegroundLocation) {
                                        sosLocationPermissionLauncher.launch(
                                            arrayOf(
                                                Manifest.permission.ACCESS_COARSE_LOCATION,
                                                Manifest.permission.ACCESS_FINE_LOCATION,
                                            ),
                                        )
                                    }
                                },
                            )
                            .padding(vertical = Metrics.space4)
                            .semantics(mergeDescendants = true) {},
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                        ) {
                            Text(
                                stringResource(R.string.safety_sos_location_title),
                                style = NoopType.body,
                                color = Palette.textPrimary,
                            )
                            if (sosGestureSharesLocation) {
                                Text(
                                    stringResource(
                                        if (sosLocationReady) {
                                            R.string.safety_sos_location_ready
                                        } else {
                                            R.string.safety_sos_location_permission
                                        },
                                    ),
                                    style = NoopType.caption,
                                    color = Palette.textTertiary,
                                )
                            }
                        }
                        Spacer(Modifier.width(Metrics.space12))
                        NoopToggleSwitch(
                            checked = sosGestureSharesLocation,
                            onCheckedChange = null,
                        )
                    }
                    if (sosGestureSharesLocation && !sosLocationReady) {
                        NoopButton(
                            text = stringResource(
                                if (hasForegroundLocation) {
                                    R.string.safety_sos_location_settings
                                } else {
                                    R.string.safety_sos_location_enable
                                },
                            ),
                            leadingIcon = Icons.Filled.MyLocation,
                            kind = NoopButtonKind.Secondary,
                            fullWidth = true,
                        ) {
                            if (hasForegroundLocation) {
                                openAppSettings()
                            } else {
                                sosLocationPermissionLauncher.launch(
                                    arrayOf(
                                        Manifest.permission.ACCESS_COARSE_LOCATION,
                                        Manifest.permission.ACCESS_FINE_LOCATION,
                                    ),
                                )
                            }
                        }
                    }
                    if (sosGestureSharesLocation) {
                        Text(
                            stringResource(R.string.safety_sos_location_retention),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }

                    HorizontalDivider(color = Palette.hairline)
                    Row(
                        modifier = Modifier.semantics(mergeDescendants = true) {},
                        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Icon(
                            if (sosNotificationsAvailable) {
                                Icons.Filled.Notifications
                            } else {
                                Icons.Filled.NotificationsOff
                            },
                            contentDescription = null,
                            tint = if (sosNotificationsAvailable) {
                                Palette.statusPositive
                            } else {
                                Palette.statusWarning
                            },
                        )
                        Text(
                            stringResource(
                                if (sosNotificationsAvailable) {
                                    R.string.safety_sos_notifications_ready
                                } else {
                                    R.string.safety_sos_notifications_off
                                },
                            ),
                            modifier = Modifier.weight(1f),
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                        )
                    }
                    if (!sosNotificationsAvailable) {
                        NoopButton(
                            text = stringResource(R.string.safety_settings_open_notifications),
                            leadingIcon = Icons.Filled.Settings,
                            kind = NoopButtonKind.Secondary,
                            fullWidth = true,
                            onClick = ::openAppSettings,
                        )
                    }

                }
                Text(
                    stringResource(R.string.safety_page_disclaimer),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }

        SectionHeader(
            stringResource(R.string.safety_share_title),
            overline = stringResource(R.string.safety_share_overline),
        )
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                Text(
                    stringResource(R.string.safety_message_purpose),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
                SegmentedPillControl(
                    items = SafetyShareIntent.entries.toList(),
                    selection = shareIntent,
                    label = {
                        when (it) {
                            SafetyShareIntent.FEEL_UNSAFE ->
                                context.getString(R.string.safety_intent_short_unsafe)
                            SafetyShareIntent.NEED_HELP_NOW ->
                                context.getString(R.string.safety_intent_short_help_now)
                            SafetyShareIntent.MISSED_CHECK_IN ->
                                context.getString(R.string.safety_intent_short_missed)
                        }
                    },
                    accessibilityLabel = {
                        when (it) {
                            SafetyShareIntent.FEEL_UNSAFE ->
                                context.getString(R.string.safety_intent_feel_unsafe)
                            SafetyShareIntent.NEED_HELP_NOW ->
                                context.getString(R.string.safety_intent_need_help_now)
                            SafetyShareIntent.MISSED_CHECK_IN ->
                                context.getString(R.string.safety_intent_missed_check_in)
                        }
                    },
                    onSelect = { shareIntent = it },
                    adaptsToAvailableWidth = true,
                )
                NoopButton(
                    text = if (detailsExpanded) {
                        stringResource(R.string.safety_details_hide)
                    } else {
                        stringResource(R.string.safety_details_add)
                    },
                    leadingIcon = Icons.Filled.Edit,
                    kind = NoopButtonKind.Tertiary,
                    fullWidth = true,
                ) { detailsExpanded = !detailsExpanded }
                if (detailsExpanded) {
                    OutlinedTextField(
                        value = displayName,
                        onValueChange = { displayName = it.take(SafetyShareMessage.MAX_NAME_CHARACTERS) },
                        label = { Text(stringResource(R.string.safety_name_optional)) },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        colors = safetyFieldColors(),
                    )
                    OutlinedTextField(
                        value = note,
                        onValueChange = { note = it.take(SafetyShareMessage.MAX_NOTE_CHARACTERS) },
                        label = { Text(stringResource(R.string.safety_note_optional)) },
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 2,
                        maxLines = 4,
                        colors = safetyFieldColors(),
                    )
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .toggleable(
                            value = includeLocation,
                            role = Role.Switch,
                            onValueChange = { includeLocation = it },
                        )
                        .padding(vertical = Metrics.space4)
                        .semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.safety_location_include),
                            style = NoopType.body,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(R.string.safety_location_one_shot),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Spacer(Modifier.width(Metrics.space12))
                    NoopToggleSwitch(checked = includeLocation, onCheckedChange = null)
                }

                if (includeLocation) {
                    when (locationState) {
                        SafetyLocationState.Idle -> NoopButton(
                            text = stringResource(R.string.safety_location_get),
                            leadingIcon = Icons.Filled.MyLocation,
                            kind = NoopButtonKind.Secondary,
                            fullWidth = true,
                            onClick = ::requestLocation,
                        )
                        SafetyLocationState.Requesting -> StatePill(
                            stringResource(R.string.safety_location_getting),
                            tone = StrandTone.Accent,
                            pulsing = true,
                        )
                        SafetyLocationState.Ready -> if (locationIsReady) {
                            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    StatePill(
                                        stringResource(R.string.safety_location_ready),
                                        tone = StrandTone.Positive,
                                    )
                                    Spacer(Modifier.weight(1f))
                                    NoopButton(
                                        text = stringResource(R.string.safety_refresh),
                                        leadingIcon = Icons.Filled.Refresh,
                                        kind = NoopButtonKind.Tertiary,
                                        onClick = ::requestLocation,
                                    )
                                }
                                location?.let { fix ->
                                    Text(
                                        locationDetail(fix),
                                        style = NoopType.caption,
                                        color = Palette.textTertiary,
                                    )
                                }
                            }
                        } else {
                            LocationStatus(
                                stringResource(R.string.safety_location_expired),
                            )
                            NoopButton(
                                text = stringResource(R.string.safety_location_refresh),
                                leadingIcon = Icons.Filled.Refresh,
                                kind = NoopButtonKind.Secondary,
                                fullWidth = true,
                                onClick = ::requestLocation,
                            )
                        }
                        SafetyLocationState.Denied -> {
                            LocationStatus(
                                stringResource(R.string.safety_location_permission_off),
                            )
                            NoopButton(
                                text = stringResource(R.string.safety_settings_open_app),
                                leadingIcon = Icons.Filled.Shield,
                                kind = NoopButtonKind.Secondary,
                                fullWidth = true,
                                onClick = ::openAppSettings,
                            )
                        }
                        SafetyLocationState.Failed -> {
                            LocationStatus(stringResource(R.string.safety_location_failed))
                            NoopButton(
                                text = stringResource(R.string.safety_location_retry),
                                leadingIcon = Icons.Filled.Refresh,
                                kind = NoopButtonKind.Secondary,
                                fullWidth = true,
                                onClick = ::requestLocation,
                            )
                        }
                    }
                    if (!locationIsReady) {
                        Text(
                            stringResource(R.string.safety_location_required),
                            style = NoopType.caption,
                            color = Palette.statusWarning,
                        )
                    }
                }

                NoopButton(
                    text = stringResource(R.string.safety_share_button),
                    leadingIcon = Icons.AutoMirrored.Filled.Send,
                    kind = NoopButtonKind.Primary,
                    fullWidth = true,
                    enabled = canSharePreparedMessage,
                ) {
                    val message = SafetyShareMessage.build(
                        intent = shareIntent,
                        displayName = displayName,
                        note = note,
                        location = location.takeIf { includeLocation },
                        preparedAtUnix = System.currentTimeMillis() / 1_000L,
                        copy = safetyShareCopy,
                    )
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(
                            Intent.EXTRA_SUBJECT,
                            context.getString(R.string.safety_share_subject),
                        )
                        putExtra(Intent.EXTRA_TEXT, message)
                    }
                    context.startActivity(
                        Intent.createChooser(
                            send,
                            context.getString(R.string.safety_share_button),
                        ),
                    )
                }
                Text(
                    stringResource(R.string.safety_share_disclaimer),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }

        SectionHeader(
            stringResource(R.string.safety_timer_title),
            overline = stringResource(R.string.safety_timer_overline),
        )
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                val pill = when (state) {
                    SafetyCheckInState.Inactive -> Triple(
                        stringResource(R.string.safety_timer_none),
                        StrandTone.Neutral,
                        false,
                    )
                    is SafetyCheckInState.Active -> Triple(
                        stringResource(R.string.safety_timer_active),
                        StrandTone.Positive,
                        true,
                    )
                    is SafetyCheckInState.DueSoon -> Triple(
                        stringResource(R.string.safety_timer_due_soon),
                        StrandTone.Warning,
                        true,
                    )
                    is SafetyCheckInState.Overdue -> Triple(
                        stringResource(R.string.safety_timer_overdue),
                        StrandTone.Critical,
                        true,
                    )
                }
                StatePill(pill.first, tone = pill.second, showsDot = pill.third)
                Text(
                    safetyStatusLabel(state),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                if (dueAtUnix > 0L) {
                    Text(
                        stringResource(
                            R.string.safety_timer_scheduled_format,
                            formatSafetyDueAt(dueAtUnix),
                        ),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                if (dueAtUnix > nowUnix &&
                    reminderAvailability !=
                    SafetyCheckInReminderScheduler.DeliveryAvailability.AVAILABLE
                ) {
                    val warning = when (reminderAvailability) {
                        SafetyCheckInReminderScheduler.DeliveryAvailability.CHANNEL_OFF ->
                            stringResource(R.string.safety_reminder_channel_off)
                        SafetyCheckInReminderScheduler.DeliveryAvailability.NOTIFICATIONS_OFF ->
                            stringResource(R.string.safety_reminder_notifications_off)
                        SafetyCheckInReminderScheduler.DeliveryAvailability.AVAILABLE -> ""
                    }
                    ReminderWarningStatus(warning)
                    NoopButton(
                        text = stringResource(R.string.safety_settings_open_reminder),
                        leadingIcon = Icons.Filled.Warning,
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        onClick = ::openReminderSettings,
                    )
                }

                if (state == SafetyCheckInState.Inactive) {
                    SegmentedPillControl(
                        items = CheckInPreset.entries.toList(),
                        selection = preset,
                        label = { context.getString(it.labelRes) },
                        accessibilityLabel = { context.getString(it.labelRes) },
                        onSelect = { preset = it },
                        adaptsToAvailableWidth = true,
                    )
                    NoopButton(
                        text = stringResource(R.string.safety_timer_start),
                        leadingIcon = Icons.Filled.Timer,
                        kind = NoopButtonKind.Primary,
                        fullWidth = true,
                        onClick = ::startCheckIn,
                    )
                } else {
                    NoopButton(
                        text = stringResource(R.string.safety_timer_end),
                        leadingIcon = Icons.Filled.CheckCircle,
                        kind = NoopButtonKind.Primary,
                        fullWidth = true,
                    ) {
                        SafetyCheckInReminderScheduler.cancel(context)
                        dueAtUnix = 0L
                    }
                }
                Text(
                    stringResource(R.string.safety_timer_disclaimer),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }

        NoopCard {
            Row(
                modifier = Modifier.semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(Icons.Filled.Shield, contentDescription = null, tint = Palette.textSecondary)
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    Text(
                        stringResource(R.string.safety_privacy_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.safety_privacy_body),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun LocationStatus(text: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Filled.LocationOn,
            contentDescription = null,
            tint = Palette.statusWarning,
            modifier = Modifier.size(18.dp),
        )
        Text(text, style = NoopType.footnote, color = Palette.textSecondary)
    }
}

@Composable
private fun ReminderWarningStatus(text: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
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
private fun safetyFieldColors() = OutlinedTextFieldDefaults.colors(
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

private fun formatSafetyDueAt(unix: Long): String =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
        .withZone(ZoneId.systemDefault())
        .format(Instant.ofEpochSecond(unix))

@Composable
private fun incidentStatusLabel(status: SafetyIncidentStatus): String = when (status) {
    SafetyIncidentStatus.OPEN,
    SafetyIncidentStatus.PENDING,
    -> stringResource(R.string.safety_page_status_open)
    SafetyIncidentStatus.ACKNOWLEDGED ->
        stringResource(R.string.safety_page_status_acknowledged)
    SafetyIncidentStatus.RESOLVED ->
        stringResource(R.string.safety_page_status_resolved)
    SafetyIncidentStatus.CANCELLED ->
        stringResource(R.string.safety_page_status_cancelled)
    SafetyIncidentStatus.EXPIRED ->
        stringResource(R.string.safety_page_status_expired)
    SafetyIncidentStatus.SUBMITTED ->
        stringResource(R.string.safety_page_status_submitted)
    SafetyIncidentStatus.PARTIAL_FAILURE ->
        stringResource(R.string.safety_page_status_partial_failure)
    SafetyIncidentStatus.FAILED ->
        stringResource(R.string.safety_page_status_failed)
}

private fun incidentStatusTone(status: SafetyIncidentStatus): StrandTone = when (status) {
    SafetyIncidentStatus.OPEN,
    SafetyIncidentStatus.PENDING,
    SafetyIncidentStatus.SUBMITTED,
    -> StrandTone.Warning
    SafetyIncidentStatus.ACKNOWLEDGED,
    SafetyIncidentStatus.RESOLVED,
    -> StrandTone.Positive
    SafetyIncidentStatus.PARTIAL_FAILURE,
    SafetyIncidentStatus.FAILED,
    -> StrandTone.Critical
    SafetyIncidentStatus.CANCELLED,
    SafetyIncidentStatus.EXPIRED,
    -> StrandTone.Neutral
}

@Composable
private fun incidentStatusDetail(
    status: SafetyIncidentStatus,
    acknowledgedContactName: String?,
): String = when (status) {
    SafetyIncidentStatus.OPEN,
    SafetyIncidentStatus.PENDING,
    -> stringResource(R.string.safety_page_detail_waiting)
    SafetyIncidentStatus.ACKNOWLEDGED -> acknowledgedContactName?.let {
        stringResource(R.string.safety_page_detail_acknowledged_format, it)
    } ?: stringResource(R.string.safety_page_detail_acknowledged)
    SafetyIncidentStatus.RESOLVED ->
        stringResource(R.string.safety_page_detail_resolved)
    SafetyIncidentStatus.CANCELLED ->
        stringResource(R.string.safety_page_detail_cancelled)
    SafetyIncidentStatus.EXPIRED ->
        stringResource(R.string.safety_page_detail_expired)
    SafetyIncidentStatus.SUBMITTED ->
        stringResource(R.string.safety_page_detail_submitted)
    SafetyIncidentStatus.PARTIAL_FAILURE ->
        stringResource(R.string.safety_page_detail_partial_failure)
    SafetyIncidentStatus.FAILED ->
        stringResource(R.string.safety_page_detail_failed)
}

@Composable
private fun safetyStatusLabel(state: SafetyCheckInState): String = when (state) {
    SafetyCheckInState.Inactive -> stringResource(R.string.safety_timer_status_inactive)
    is SafetyCheckInState.Active -> stringResource(
        R.string.safety_timer_status_active_format,
        safetyDurationLabel(state.remainingSeconds),
    )
    is SafetyCheckInState.DueSoon -> stringResource(
        R.string.safety_timer_status_due_soon_format,
        safetyDurationLabel(state.remainingSeconds),
    )
    is SafetyCheckInState.Overdue -> stringResource(
        R.string.safety_timer_status_overdue_format,
        safetyDurationLabel(state.elapsedSeconds),
    )
}

@Composable
private fun safetyDurationLabel(seconds: Long): String {
    val safe = seconds.coerceAtLeast(0L)
    return when {
        safe < 60L -> stringResource(R.string.safety_duration_seconds, safe)
        safe < 3_600L -> stringResource(R.string.safety_duration_minutes, safe / 60L)
        safe % 3_600L < 60L ->
            stringResource(R.string.safety_duration_hours, safe / 3_600L)
        else -> stringResource(
            R.string.safety_duration_hours_minutes,
            safe / 3_600L,
            (safe % 3_600L) / 60L,
        )
    }
}

@Composable
private fun locationDetail(location: SafetyLocation): String {
    val captured = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withZone(ZoneId.systemDefault())
        .format(Instant.ofEpochSecond(location.capturedAtUnix))
    val accuracy = location.horizontalAccuracyMeters
        ?.takeIf { it.isFinite() && it >= 0.0 }
        ?.roundToInt()
    return if (accuracy == null) {
        stringResource(R.string.safety_location_captured_format, captured)
    } else {
        stringResource(R.string.safety_location_accuracy_format, captured, accuracy)
    }
}
