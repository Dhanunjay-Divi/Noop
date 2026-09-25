package com.noop.ui

import com.noop.R
import com.noop.brand.CustomerFacingBrand
import androidx.compose.ui.res.stringResource
import android.app.DatePickerDialog
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoGraph
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.noop.ble.SourceCoordinator
import com.noop.data.DeviceStatus
import com.noop.data.ImportSummary
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import com.noop.ingest.AppleHealthImporter
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.HealthConnectReconciler
import com.noop.ingest.WhoopCsvImporter
import com.noop.notif.DailyReviewReminders
import com.noop.NoopApplication
import com.noop.ownership.NoopProductPlan
import com.noop.ownership.OwnershipConfiguration
import com.noop.ownership.OwnershipPhase
import com.noop.ownership.OwnershipService
import com.noop.safety.SafetyPagingController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Calendar
import kotlin.math.roundToInt

// MARK: - OnboardingScreen
//
// Android's first-run flow mirrors the macOS OnboardingWizard shape: a paged,
// full-screen sequence that sets expectations, scans/connects to the strap, captures
// the profile values that power zones/calories, imports history, and then hands off to
// the app shell. It uses the same AppViewModel/Repository/BLE client as the app itself.

@Composable
fun OnboardingScreen(viewModel: AppViewModel, onFinished: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember(context) { NoopPrefs.of(context) }
    val ownershipConfigured = remember { OwnershipConfiguration.load() != null }
    val supplierOnboardingAvailable = supplierBandOnboardingAvailable(
        adapterAvailable = viewModel.supplierBandAvailable,
        ownershipConfigured = ownershipConfigured,
    )
    val accountMode = onboardingAccountMode(ownershipConfigured)
    val accountCopy = onboardingAccountCopy(accountMode)
    val ownership = remember(context) {
        (context.applicationContext as? NoopApplication)?.ownership
            ?: OwnershipService.get(context)
    }
    val ownershipState by ownership.state.collectAsState()
    val pages = remember(ownershipConfigured) {
        onboardingPages(ownershipConfigured)
    }
    // Save the current schema's page through Activity recreation while retaining the versioned
    // preference checkpoint for process death. The schema input prevents an old flow's saved index
    // from being restored into a future page map.
    var savedPageIndex by rememberSaveable(
        ONBOARDING_PROGRESS_SCHEMA,
        ownershipConfigured,
    ) {
        val restored = prefs.getString(ONBOARDING_PROGRESS_KEY, null)
        mutableIntStateOf(
            restoredOnboardingPageIndex(
                storedPage = restored,
                pages = pages,
            ),
        )
    }
    val pageIndex = savedPageIndex.takeIf(pages.indices::contains) ?: 0
    val page = pages[pageIndex]
    var dailyReviewOptIn by rememberSaveable {
        mutableStateOf(DailyReviewReminders.isEnabled(context))
    }
    var selectedPlan by rememberSaveable {
        mutableStateOf(NoopProductPlan.stored(context))
    }
    var planSubmissionAttempted by rememberSaveable {
        mutableStateOf(false)
    }
    val scope = rememberCoroutineScope()
    var registrySetupSourceName by rememberSaveable {
        mutableStateOf<String?>(null)
    }
    val registrySetupSource = registrySetupSourceName?.let { stored ->
        SourceKind.entries.firstOrNull { it.name == stored }
    }
    var registrySetupReadComplete by remember { mutableStateOf(false) }
    var registrySetupReadFailed by remember { mutableStateOf(false) }
    var showAddDeviceWizard by rememberSaveable { mutableStateOf(false) }
    // A live bond is transient and can outlive a failed/absent registry write. Only an authoritative,
    // usable registered band may unlock post-setup onboarding or survive Activity/process recreation.
    val deviceSetupComplete = registrySetupSource != null
    val accountStepReady = accountStepCanContinue(
        ownershipConfigured = ownershipConfigured,
        reconciliationComplete = !ownershipState.busy,
        phase = ownershipState.phase,
    )
    val supplierClaimRequired = registrySetupSource == SourceKind.veepoo
    val ownershipClaimed =
        ownershipState.phase == OwnershipPhase.CLAIMED ||
            ownershipState.phase == OwnershipPhase.COMPLETE
    val claimStepReady = claimStepCanContinue(
        supplierClaimRequired = supplierClaimRequired,
        claimed = ownershipClaimed,
        reconciliationComplete = !ownershipState.busy,
    )
    val postClaimOwnershipReady = accountStepReady && claimStepReady

    fun moveTo(
        target: Int,
        direction: String,
        setupCompleteOverride: Boolean? = null,
        supplierClaimRequiredOverride: Boolean? = null,
    ) {
        if (!pages.indices.contains(target)) return
        val requested = pages[target]
        val next = resolvedOnboardingDestination(
            requested = requested,
            ownershipConfigured = ownershipConfigured,
            reconciliationComplete = !ownershipState.busy,
            phase = ownershipState.phase,
            deviceSetupComplete =
                setupCompleteOverride ?: deviceSetupComplete,
            supplierClaimRequired =
                supplierClaimRequiredOverride ?: supplierClaimRequired,
        ) ?: return
        val destination = pages.indexOf(next)
        if (destination < 0) return
        val effectiveDirection = if (next == requested) {
            direction
        } else {
            "reconciled"
        }
        prefs.edit()
            .putString(
                ONBOARDING_PROGRESS_KEY,
                encodedOnboardingProgress(next),
            )
            .apply()
        com.noop.AppDiagnosticsRecorder.record(
            "onboarding.progress",
            fields = mapOf(
                "step" to next.storageValue,
                "direction" to effectiveDirection,
            ),
        )
        savedPageIndex = destination
    }

    fun acceptDeviceSetupSource(
        source: SourceKind,
        recordOutcome: Boolean,
    ) {
        if (source == SourceKind.veepoo && !supplierOnboardingAvailable) {
            registrySetupSourceName = null
            if (recordOutcome) {
                com.noop.AppDiagnosticsRecorder.record(
                    "onboarding.device_setup",
                    fields = mapOf("outcome" to "dismissed"),
                )
            }
            return
        }
        registrySetupSourceName = source.name
        registrySetupReadComplete = true
        registrySetupReadFailed = false
        if (recordOutcome) {
            com.noop.AppDiagnosticsRecorder.record(
                "onboarding.device_setup",
                fields = mapOf(
                    "outcome" to "completed",
                    "source" to source.name,
                ),
            )
        }
        if (pages.getOrNull(pageIndex) == OnboardingPage.Connect) {
            moveTo(
                target = pages.indexOf(OnboardingPage.Ownership),
                direction = "automatic",
                setupCompleteOverride = true,
                supplierClaimRequiredOverride =
                    source == SourceKind.veepoo,
            )
        }
    }

    suspend fun refreshDeviceSetupSource(recordOutcome: Boolean) {
        val devicesResult = runCatching { viewModel.pairedDevices() }
        if (devicesResult.isFailure) {
            registrySetupSourceName = null
            registrySetupReadComplete = true
            registrySetupReadFailed = true
            com.noop.AppDiagnosticsRecorder.record(
                "onboarding.device_setup",
                fields = mapOf("outcome" to "read_failed"),
            )
            return
        }

        registrySetupReadFailed = false
        val source = onboardingCompletedDeviceSetupSource(
            devicesResult.getOrThrow(),
            supplierAvailable = supplierOnboardingAvailable,
            supplierRegistrationUsable =
                viewModel::supplierBandRegistrationUsable,
        )
        if (source != null) {
            acceptDeviceSetupSource(source, recordOutcome)
        } else {
            registrySetupSourceName = null
            registrySetupReadComplete = true
            if (!recordOutcome) return
            com.noop.AppDiagnosticsRecorder.record(
                "onboarding.device_setup",
                fields = mapOf("outcome" to "dismissed"),
            )
        }
    }

    LaunchedEffect(page) {
        if (onboardingNeedsDeviceSetupRead(page)) {
            refreshDeviceSetupSource(recordOutcome = false)
        }
    }
    LaunchedEffect(
        page,
        ownershipConfigured,
        ownershipState.phase,
        ownershipState.busy,
        deviceSetupComplete,
        supplierClaimRequired,
        registrySetupReadComplete,
    ) {
        if (
            onboardingNeedsDeviceSetupRead(page) &&
            !registrySetupReadComplete
        ) {
            return@LaunchedEffect
        }
        val destination = resolvedOnboardingDestination(
            requested = page,
            ownershipConfigured = ownershipConfigured,
            reconciliationComplete = !ownershipState.busy,
            phase = ownershipState.phase,
            deviceSetupComplete = deviceSetupComplete,
            supplierClaimRequired = supplierClaimRequired,
        )
        if (destination != null && destination != page) {
            moveTo(pages.indexOf(destination), "reconciled")
        }
    }

    fun complete() {
        val destination = resolvedOnboardingDestination(
            requested = OnboardingPage.Done,
            ownershipConfigured = ownershipConfigured,
            reconciliationComplete = !ownershipState.busy,
            phase = ownershipState.phase,
            deviceSetupComplete = deviceSetupComplete,
            supplierClaimRequired = supplierClaimRequired,
        )
        if (destination != OnboardingPage.Done) {
            destination?.let {
                moveTo(pages.indexOf(it), "reconciled")
            }
            return
        }
        // Onboarding deferred the foreground promotion; do it now if a strap is live.
        viewModel.promoteBackgroundConnectionIfActive()
        prefs.edit()
            .remove(ONBOARDING_PROGRESS_KEY)
            .remove(LEGACY_ONBOARDING_PROGRESS_KEY)
            .apply()
        com.noop.AppDiagnosticsRecorder.record(
            "onboarding.progress",
            fields = mapOf(
                "step" to "complete",
                "direction" to "finished",
            ),
        )
        onFinished()
    }

    // Each permission is requested as the user LEAVES the step that explains it — never on top of
    // the explaining screen, and never at launch: Bluetooth on the "before you connect" step,
    // notifications on the dedicated notifications step. We advance once the prompt is dismissed,
    // whatever the result. blePermissions() is the same shared source of truth Live/Settings use.
    val blePerms = remember { blePermissions() }
    val bleAdvanceLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { moveTo(pageIndex + 1, "forward") }
    val notifAdvanceLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        dailyReviewOptIn = dailyReviewOptIn && granted &&
            DailyReviewReminders.setEnabled(context, true)
        if (!dailyReviewOptIn) DailyReviewReminders.setEnabled(context, false)
        moveTo(pageIndex + 1, "forward")
    }

    fun advance() {
        val destination = resolvedOnboardingDestination(
            requested = page,
            ownershipConfigured = ownershipConfigured,
            reconciliationComplete = !ownershipState.busy,
            phase = ownershipState.phase,
            deviceSetupComplete = deviceSetupComplete,
            supplierClaimRequired = supplierClaimRequired,
        )
        if (destination != page) {
            destination?.let {
                moveTo(pages.indexOf(it), "reconciled")
            }
            return
        }
        if (page == OnboardingPage.Profile) {
            // Save & Continue explicitly accepts both visible inputs, including intentionally keeping
            // the seeded editor values. Until this tap, age-shaped estimates remain unavailable.
            ProfileStore.from(context).apply {
                confirmFitnessInputs()
                confirmBodyInputs()
            }
        }
        when (page) {
            OnboardingPage.Account -> {
                if (!accountStepReady) return
            }
            OnboardingPage.Plan -> {
                if (!postClaimOwnershipReady) {
                    moveTo(pageIndex, "reconciled")
                    return
                }
                val submittedPage = pageIndex
                planSubmissionAttempted = true
                scope.launch {
                    val saved = ownership.selectPlan(selectedPlan)
                    if (
                        saved &&
                        accountStepCanContinue(
                            ownershipConfigured = ownershipConfigured,
                            reconciliationComplete = !ownership.state.value.busy,
                            phase = ownership.state.value.phase,
                        ) &&
                        pageIndex == submittedPage &&
                        pages.getOrNull(pageIndex) == OnboardingPage.Plan
                    ) {
                        moveTo(submittedPage + 1, "forward")
                    } else if (
                        pageIndex == submittedPage &&
                        pages.getOrNull(pageIndex) == OnboardingPage.Plan &&
                        !accountStepCanContinue(
                            ownershipConfigured = ownershipConfigured,
                            reconciliationComplete = !ownership.state.value.busy,
                            phase = ownership.state.value.phase,
                        )
                    ) {
                        moveTo(
                            pages.indexOf(OnboardingPage.Account),
                            "reconciled",
                        )
                    }
                }
                return
            }
            OnboardingPage.Bluetooth -> {
                val granted = blePerms.all {
                    ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
                }
                if (!granted) { bleAdvanceLauncher.launch(blePerms); return }
            }
            OnboardingPage.Connect -> {
                if (!deviceSetupComplete) return
            }
            OnboardingPage.Ownership -> {
                if (!claimStepCanContinue(
                        supplierClaimRequired = supplierClaimRequired,
                        claimed = ownershipClaimed,
                        reconciliationComplete = !ownershipState.busy,
                    )
                ) {
                    return
                }
            }
            OnboardingPage.Notifications -> {
                val needsNotif = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                    PackageManager.PERMISSION_GRANTED
                if (needsNotif) { notifAdvanceLauncher.launch(Manifest.permission.POST_NOTIFICATIONS); return }
                dailyReviewOptIn = dailyReviewOptIn &&
                    DailyReviewReminders.setEnabled(context, true)
                if (!dailyReviewOptIn) DailyReviewReminders.setEnabled(context, false)
            }
            else -> {}
        }
        moveTo(pageIndex + 1, "forward")
    }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = Palette.surfaceBase,
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            OnboardingBackdrop()
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    // Edge-to-edge draws under the system bars; the wizard owns both insets.
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(horizontal = Metrics.screenPadding)
                    .padding(top = 10.dp, bottom = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val goBack = {
                    var target = pageIndex - 1
                    // Skip the setup celebration going back when no source completed setup.
                    if (
                        target >= 0 &&
                        pages[target] == OnboardingPage.Bonded &&
                        !deviceSetupComplete
                    ) {
                        target--
                    }
                    if (target >= 0) moveTo(target, "back")
                }
                OnboardingTopBar(
                    page = pageIndex + 1,
                    total = pages.size,
                    canGoBack = pageIndex > 0 && !ownershipState.busy,
                    onBack = goBack,
                )

                val onboardingPageLabel = stringResource(R.string.onboarding_page_animation_label)
                AnimatedContent(
                    targetState = page,
                    transitionSpec = {
                        (
                            fadeIn(tween(Motion.durationStandard)) +
                                slideInHorizontally(tween(Motion.durationStandard)) { it / 8 }
                            ).togetherWith(
                            fadeOut(tween(Motion.durationStandard)) +
                                slideOutHorizontally(tween(Motion.durationStandard)) { -it / 8 },
                        )
                    },
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .widthIn(max = 620.dp),
                    label = onboardingPageLabel,
                ) { targetPage ->
                    if (targetPage == OnboardingPage.Account && ownershipConfigured) {
                        OwnershipAccountScreen()
                    } else if (
                        targetPage == OnboardingPage.Ownership &&
                        supplierClaimRequired &&
                        ownershipConfigured
                    ) {
                        OwnershipAccountScreen()
                    } else {
                        Column(
                            modifier = Modifier
                                .fillMaxSize()
                                .verticalScroll(rememberScrollState())
                                .padding(top = 6.dp, bottom = 18.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            when (targetPage) {
                            OnboardingPage.Welcome -> WelcomeStep()
                            OnboardingPage.Account -> AccountAvailabilityStep()
                            OnboardingPage.WhatItDoes -> WhatItDoesStep(accountCopy)
                            OnboardingPage.Expectations -> ExpectationsStep()
                            OnboardingPage.Bluetooth -> BluetoothStep(accountCopy)
                            OnboardingPage.Wear -> WearStep()
                            OnboardingPage.Connect -> ConnectStep(
                                setupComplete = deviceSetupComplete,
                                setupReadFailed = registrySetupReadFailed,
                                canContinueWithoutBand = false,
                                requiresClaimEligibleBand = true,
                                onChooseDevice = {
                                    com.noop.AppDiagnosticsRecorder.record(
                                        "onboarding.device_setup",
                                        fields = mapOf("outcome" to "opened"),
                                    )
                                    showAddDeviceWizard = true
                                },
                                onRetrySetupRead = {
                                    scope.launch {
                                        refreshDeviceSetupSource(
                                            recordOutcome = false,
                                        )
                                    }
                                },
                            )
                            OnboardingPage.Bonded -> BondedStep()
                            OnboardingPage.Ownership -> if (supplierClaimRequired) {
                                AccountAvailabilityStep()
                            } else {
                                BondedStep()
                            }
                            OnboardingPage.Profile -> ProfileStep()
                            OnboardingPage.Import -> ImportStep(viewModel)
                            OnboardingPage.Notifications -> NotificationsStep(
                                dailyReviewOptIn = dailyReviewOptIn,
                                onDailyReviewOptIn = { dailyReviewOptIn = it },
                            )
                            OnboardingPage.SafetyContacts -> SafetyContactsStep()
                            OnboardingPage.Appearance -> AppearanceStep()
                            OnboardingPage.DailyRhythm -> DailyRhythmStep()
                            OnboardingPage.Plan -> ProductPlanStep(
                                selection = selectedPlan,
                                onSelection = { selectedPlan = it },
                                status = if (
                                    planSubmissionAttempted &&
                                    !ownershipState.busy
                                ) {
                                    ownershipState.status
                                } else {
                                    ""
                                },
                                busy = ownershipState.busy,
                            )
                            OnboardingPage.Done -> DoneStep()
                            }
                        }
                    }
                }

                val primaryEnabled = when (page) {
                    OnboardingPage.Account -> accountStepReady
                    OnboardingPage.Connect -> deviceSetupComplete
                    OnboardingPage.Ownership -> claimStepReady
                    OnboardingPage.Plan ->
                        !ownershipState.busy && postClaimOwnershipReady
                    else ->
                        resolvedOnboardingDestination(
                            requested = page,
                            ownershipConfigured = ownershipConfigured,
                            reconciliationComplete = !ownershipState.busy,
                            phase = ownershipState.phase,
                            deviceSetupComplete = deviceSetupComplete,
                            supplierClaimRequired = supplierClaimRequired,
                        ) == page
                }
                OnboardingFooter(
                    progress = if (pages.size <= 1) 1f else pageIndex.toFloat() / pages.lastIndex.toFloat(),
                    cta = when {
                        page == OnboardingPage.Plan && ownershipState.busy ->
                            stringResource(R.string.ownership_plan_saving)
                        page == OnboardingPage.Ownership &&
                            supplierClaimRequired &&
                            !ownershipClaimed ->
                            stringResource(R.string.ownership_onboarding_continue_locked)
                        page != OnboardingPage.Plan -> page.cta
                        selectedPlan == NoopProductPlan.NOOP ->
                            stringResource(R.string.ownership_plan_continue_noop)
                        else -> stringResource(R.string.ownership_plan_save_plus)
                    },
                    enabled = primaryEnabled,
                    onNext = {
                        if (pageIndex == pages.lastIndex) {
                            complete()
                        } else {
                            advance()
                        }
                    },
                )
            }
        }
    }

    if (showAddDeviceWizard) {
        AddDeviceWizard(
            viewModel = viewModel,
            selectionScope = AddDeviceSelectionScope.ClaimEligibleBands,
            allowSupplierBand = supplierOnboardingAvailable,
            onUseFileImport = {
                showAddDeviceWizard = false
                scope.launch {
                    refreshDeviceSetupSource(recordOutcome = true)
                }
            },
            onClose = {
                showAddDeviceWizard = false
                scope.launch {
                    refreshDeviceSetupSource(recordOutcome = true)
                }
            },
        )
    }
}

internal fun onboardingPages(
    @Suppress("UNUSED_PARAMETER") ownershipConfigured: Boolean,
): List<OnboardingPage> = listOf(
    OnboardingPage.Welcome,
    OnboardingPage.Account,
    OnboardingPage.Bluetooth,
    OnboardingPage.Connect,
    OnboardingPage.Ownership,
    OnboardingPage.Profile,
    OnboardingPage.Plan,
    OnboardingPage.Done,
)

internal fun onboardingCompletedDeviceSetupSource(
    devices: List<PairedDeviceRow>,
    supplierAvailable: Boolean,
    supplierRegistrationUsable: (String) -> Boolean,
): SourceKind? {
    fun eligibleSource(device: PairedDeviceRow): SourceKind? {
        if (
            device.status != DeviceStatus.active.name &&
            device.status != DeviceStatus.paired.name
        ) {
            return null
        }
        val source = SourceKind.entries.firstOrNull {
            it.name == device.sourceKind
        } ?: return null
        if (
            source == SourceKind.cloudImport ||
            source == SourceKind.fileImport ||
            source == SourceKind.activityFile
        ) {
            return null
        }
        if (device.id == "my-whoop" && device.peripheralId.isNullOrBlank()) {
            return null
        }
        if (source == SourceKind.veepoo && !supplierAvailable) {
            return null
        }
        if (device.peripheralId.isNullOrBlank()) {
            return null
        }
        val isWhoopTransport =
            source == SourceKind.liveBLE || source == SourceKind.historyBLE
        val isEligibleWhoop =
            SourceCoordinator.isWhoop(device) && isWhoopTransport
        val isEligibleSupplier =
            supplierAvailable &&
                source == SourceKind.veepoo &&
                supplierRegistrationUsable(device.id)
        if (!isEligibleWhoop && !isEligibleSupplier) {
            return null
        }
        return source
    }

    val active = devices.firstOrNull {
        it.status == DeviceStatus.active.name
    }
    if (active != null) {
        eligibleSource(active)?.let { return it }
        // An unavailable supplier row is ownership authority and must fail closed. An empty legacy
        // seed row is not authority, so a newly paired compatible band remains eligible.
        if (active.sourceKind == SourceKind.veepoo.name) return null
    }

    return devices
        .asSequence()
        .filter { it.status == DeviceStatus.paired.name }
        .sortedWith(
            compareByDescending<PairedDeviceRow> { it.lastSeenAt }
                .thenByDescending { it.addedAt },
        )
        .mapNotNull(::eligibleSource)
        .firstOrNull()
}

internal fun onboardingNeedsDeviceSetupRead(page: OnboardingPage): Boolean =
    page == OnboardingPage.Connect ||
        page == OnboardingPage.Ownership ||
        page == OnboardingPage.Profile ||
        page == OnboardingPage.Plan ||
        page == OnboardingPage.Done

internal enum class OnboardingAccountMode {
    CONFIGURED,
    EXPLORATION,
}

internal data class OnboardingAccountCopy(
    val dataBoundaryTitle: Int,
    val dataBoundaryBody: Int,
    val bluetoothBoundaryBody: Int,
)

internal fun onboardingAccountMode(
    ownershipConfigured: Boolean,
): OnboardingAccountMode = if (ownershipConfigured) {
    OnboardingAccountMode.CONFIGURED
} else {
    OnboardingAccountMode.EXPLORATION
}

internal fun onboardingAccountCopy(
    mode: OnboardingAccountMode,
): OnboardingAccountCopy = when (mode) {
    OnboardingAccountMode.CONFIGURED -> OnboardingAccountCopy(
        dataBoundaryTitle = R.string.onboarding_data_boundary_configured_title,
        dataBoundaryBody = R.string.onboarding_data_boundary_configured_body,
        bluetoothBoundaryBody = R.string.onboarding_bluetooth_boundary_configured,
    )
    OnboardingAccountMode.EXPLORATION -> OnboardingAccountCopy(
        dataBoundaryTitle = R.string.onboarding_data_boundary_exploration_title,
        dataBoundaryBody = R.string.onboarding_data_boundary_exploration_body,
        bluetoothBoundaryBody = R.string.onboarding_bluetooth_boundary_exploration,
    )
}

internal fun supplierBandOnboardingAvailable(
    adapterAvailable: Boolean,
    ownershipConfigured: Boolean,
): Boolean = adapterAvailable && ownershipConfigured

internal fun accountStepCanContinue(
    ownershipConfigured: Boolean,
    reconciliationComplete: Boolean,
    phase: OwnershipPhase,
): Boolean {
    if (!ownershipConfigured) return true
    if (!reconciliationComplete) return false
    return phase == OwnershipPhase.ACCOUNT_READY ||
        phase == OwnershipPhase.POSSESSION_UNAVAILABLE ||
        phase == OwnershipPhase.CLAIMING ||
        phase == OwnershipPhase.CLAIMED ||
        phase == OwnershipPhase.COMPLETE ||
        phase == OwnershipPhase.REPLACEMENT_REQUIRED ||
        phase == OwnershipPhase.AUTHORIZING_REPLACEMENT
}

internal fun claimStepCanContinue(
    supplierClaimRequired: Boolean,
    claimed: Boolean,
    reconciliationComplete: Boolean,
): Boolean = !supplierClaimRequired || (claimed && reconciliationComplete)

internal fun resolvedOnboardingDestination(
    requested: OnboardingPage,
    ownershipConfigured: Boolean,
    reconciliationComplete: Boolean,
    phase: OwnershipPhase,
    deviceSetupComplete: Boolean,
    supplierClaimRequired: Boolean,
): OnboardingPage? {
    if (requested == OnboardingPage.Welcome || requested == OnboardingPage.Account) {
        return requested
    }
    if (ownershipConfigured && !reconciliationComplete) {
        return null
    }
    if (!accountStepCanContinue(
            ownershipConfigured = ownershipConfigured,
            reconciliationComplete = reconciliationComplete,
            phase = phase,
        )
    ) {
        return OnboardingPage.Account
    }
    val requiresBand = requested == OnboardingPage.Ownership ||
        requested == OnboardingPage.Profile ||
        requested == OnboardingPage.Plan ||
        requested == OnboardingPage.Done
    if (requiresBand && !deviceSetupComplete) {
        return OnboardingPage.Connect
    }
    val requiresClaim = requested == OnboardingPage.Profile ||
        requested == OnboardingPage.Plan ||
        requested == OnboardingPage.Done
    if (
        requiresClaim &&
        !claimStepCanContinue(
            supplierClaimRequired = supplierClaimRequired,
            claimed = phase == OwnershipPhase.CLAIMED ||
                phase == OwnershipPhase.COMPLETE,
            reconciliationComplete = reconciliationComplete,
        )
    ) {
        return OnboardingPage.Ownership
    }
    return requested
}

internal fun restoredOnboardingPageIndex(
    storedPage: String?,
    pages: List<OnboardingPage>,
): Int {
    val prefix = "$ONBOARDING_PROGRESS_SCHEMA:"
    if (storedPage?.startsWith(prefix) != true) {
        return pages.indexOf(OnboardingPage.Welcome).coerceAtLeast(0)
    }
    val storedValue = storedPage.removePrefix(prefix)
    val restoredPage = OnboardingPage.entries.firstOrNull {
        it.storageValue == storedValue
    } ?: return pages.indexOf(OnboardingPage.Welcome).coerceAtLeast(0)
    val restoredIndex = pages.indexOf(restoredPage)
    if (restoredIndex >= 0) return restoredIndex
    return pages.indexOf(OnboardingPage.Welcome).coerceAtLeast(0)
}

internal enum class OnboardingPage(val cta: String) {
    Welcome("Get Started"),
    Account("Continue"),
    WhatItDoes("Continue"),
    Expectations("I understand"),
    Bluetooth("Continue"),
    Wear("I'm wearing it"),
    Connect("Continue"),
    Bonded("Continue"),
    Ownership("Continue"),
    Profile("Save & Continue"),
    Import("Continue"),
    Notifications("Continue"),
    SafetyContacts("Finish later"),
    Appearance("Continue"),
    DailyRhythm("Continue"),
    Plan("Continue"),
    Done("Enter NOOP");

    val storageValue: String
        get() = when (this) {
            Welcome -> "welcome"
            Account -> "account"
            WhatItDoes -> "what"
            Expectations -> "expectations"
            Bluetooth -> "bluetooth"
            Wear -> "wear"
            Connect -> "scan"
            Bonded -> "bonded"
            Ownership -> "ownership"
            Profile -> "profile"
            Import -> "import"
            Notifications -> "notifications"
            SafetyContacts -> "safety_contacts"
            Appearance -> "appearance"
            DailyRhythm -> "daily_rhythm"
            Plan -> "plan"
            Done -> "done"
        }
}

internal const val ONBOARDING_PROGRESS_SCHEMA = 2

internal fun encodedOnboardingProgress(page: OnboardingPage): String =
    "$ONBOARDING_PROGRESS_SCHEMA:${page.storageValue}"

private const val ONBOARDING_PROGRESS_KEY = "noop.onboarding.progress.v2"
private const val LEGACY_ONBOARDING_PROGRESS_KEY = "noop.onboarding.progress.v1"

@Composable
private fun AccountAvailabilityStep() {
    val footer = stringResource(
        R.string.appwide_onboarding_account_unconfigured_footer,
    )
    StepShell(
        title = stringResource(
            R.string.appwide_onboarding_account_unconfigured_title,
        ),
        subtitle = stringResource(
            R.string.appwide_onboarding_account_unconfigured_subtitle,
        ),
    ) {
        InfoCard(
            icon = Icons.Filled.Lock,
            tint = Palette.accent,
            title = stringResource(
                R.string.appwide_onboarding_account_release_title,
            ),
            message = stringResource(
                R.string.appwide_onboarding_account_release_body,
            ),
        )
        InfoCard(
            icon = Icons.Filled.Smartphone,
            tint = Palette.statusPositive,
            title = stringResource(
                R.string.appwide_onboarding_account_local_title,
            ),
            message = stringResource(
                R.string.appwide_onboarding_account_local_body,
            ),
        )
        Text(
            footer,
            style = NoopType.caption,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .widthIn(max = 460.dp)
                .semantics {
                    contentDescription = footer
                },
        )
    }
}

@Composable
private fun ProductPlanStep(
    selection: NoopProductPlan,
    onSelection: (NoopProductPlan) -> Unit,
    status: String,
    busy: Boolean,
) {
    StepShell {
        Spacer(Modifier.height(12.dp))
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = Palette.textPrimary,
            modifier = Modifier.size(38.dp),
        )
        Text(
            stringResource(R.string.ownership_plan_title),
            style = NoopType.title1,
            color = Palette.textPrimary,
            textAlign = TextAlign.Center,
        )
        Text(
            stringResource(R.string.ownership_plan_detail),
            style = NoopType.body,
            color = Palette.textSecondary,
            textAlign = TextAlign.Center,
        )
        ProductPlanChoice(
            selected = selection == NoopProductPlan.NOOP,
            icon = Icons.Filled.Smartphone,
            title = stringResource(R.string.ownership_plan_noop_title),
            subtitle = stringResource(R.string.ownership_plan_noop_subtitle),
            detail = stringResource(R.string.ownership_plan_noop_detail),
            tint = Palette.textPrimary,
            enabled = !busy,
            onClick = { onSelection(NoopProductPlan.NOOP) },
        )
        ProductPlanChoice(
            selected = selection == NoopProductPlan.NOOP_PLUS,
            icon = Icons.Filled.Star,
            title = stringResource(R.string.ownership_plan_plus_title),
            subtitle = stringResource(R.string.ownership_plan_plus_subtitle),
            detail = stringResource(R.string.ownership_plan_plus_detail),
            tint = Palette.metricAmber,
            enabled = !busy,
            onClick = { onSelection(NoopProductPlan.NOOP_PLUS) },
        )
        Text(
            stringResource(R.string.ownership_plan_notice),
            style = NoopType.caption,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
        )
        if (status.isNotBlank()) {
            Text(
                text = status,
                style = NoopType.caption,
                color = Palette.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics {
                    contentDescription = status
                },
            )
        }
    }
}

@Composable
private fun ProductPlanChoice(
    selected: Boolean,
    icon: ImageVector,
    title: String,
    subtitle: String,
    detail: String,
    tint: Color,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val choiceDescription = stringResource(
        R.string.ownership_plan_choice_description,
        title,
        subtitle,
        detail,
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.surfaceRaised)
            .border(
                width = if (selected) 1.5.dp else 1.dp,
                color = if (selected) tint else Palette.hairline,
                shape = RoundedCornerShape(8.dp),
            )
            .clickable(
                enabled = enabled,
                role = Role.RadioButton,
                onClick = onClick,
            )
            .semantics {
                this.selected = selected
                contentDescription = choiceDescription
            }
            .padding(16.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(38.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(tint.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(19.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(
                    title,
                    style = NoopType.headline,
                    color = tint,
                )
                Text(
                    subtitle,
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
            Text(
                detail,
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        }
        Icon(
            if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (selected) tint else Palette.textTertiary,
            modifier = Modifier.size(20.dp),
        )
    }
}

// MARK: - Shell

@Composable
private fun OnboardingBackdrop() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.radialGradient(
                    colors = listOf(
                        Palette.glowAmbient.copy(alpha = 0.07f),
                        Color.Transparent,
                    ),
                    radius = 1_400f,
                ),
            ),
    )
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    colors = listOf(
                        Palette.accentMuted.copy(alpha = 0.20f),
                        Color.Transparent,
                    ),
                    endY = 900f,
                ),
            ),
    )
}

@Composable
private fun OnboardingTopBar(
    page: Int,
    total: Int,
    canGoBack: Boolean,
    onBack: () -> Unit,
) {
    val backLabel = stringResource(R.string.l10n_onboarding_screen_back_b52b36b7)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .widthIn(max = 620.dp)
            .heightIn(min = 28.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (canGoBack) {
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = onBack)
                    .padding(horizontal = 2.dp, vertical = 4.dp)
                    .semantics { contentDescription = backLabel },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Icon(
                    Icons.Filled.ChevronLeft,
                    contentDescription = null,
                    tint = Palette.textSecondary,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    backLabel,
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }
        } else {
            Spacer(Modifier.width(64.dp))
        }
        Spacer(Modifier.weight(1f))
        Text(
            uiString(R.string.l10n_onboarding_screen_page_total_50b38f9a, page, total),
            style = NoopType.captionNumber,
            color = Palette.textTertiary,
        )
    }
}

@Composable
private fun OnboardingFooter(
    progress: Float,
    cta: String,
    enabled: Boolean,
    onNext: () -> Unit,
) {
    val reduceMotion = rememberReduceMotion()
    val animated by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        animationSpec = if (reduceMotion) snap() else tween(Motion.durationStandard),
        label = uiString(R.string.l10n_onboarding_screen_onboardingprogress_6e1e5c29),
    )
    val pulseTransition = rememberInfiniteTransition(
        label = uiString(R.string.l10n_onboarding_screen_onboardingprogress_6e1e5c29),
    )
    val pulsePhase by pulseTransition.animateFloat(
        initialValue = if (reduceMotion) 0.35f else 0f,
        targetValue = if (reduceMotion) 0.35f else 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = 900,
                easing = CubicBezierEasing(0.37f, 0f, 0.63f, 1f),
            ),
            repeatMode = RepeatMode.Reverse,
        ),
        label = uiString(R.string.l10n_onboarding_screen_onboardingprogress_6e1e5c29),
    )

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .widthIn(max = 620.dp)
            .padding(top = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Canvas(
            modifier = Modifier
                .fillMaxWidth()
                .height(8.dp),
        ) {
            val trackHeight = 3.dp.toPx()
            val trackTop = (size.height - trackHeight) / 2f
            val radius = trackHeight / 2f
            drawRoundRect(
                color = Palette.hairline,
                topLeft = Offset(0f, trackTop),
                size = Size(size.width, trackHeight),
                cornerRadius = CornerRadius(radius, radius),
            )
            val fillWidth = (size.width * animated).coerceAtLeast(6.dp.toPx())
            val activeHeight = 3.dp.toPx() + pulsePhase * 2.5.dp.toPx()
            val activeTop = (size.height - activeHeight) / 2f
            val activeBrush = Brush.horizontalGradient(
                colors = listOf(
                    Palette.statusCritical,
                    Palette.statusWarning,
                    Palette.statusPositive,
                ),
                endX = fillWidth,
            )
            val glowHeight = activeHeight + 2.dp.toPx() + pulsePhase * 2.dp.toPx()
            drawRoundRect(
                brush = activeBrush,
                topLeft = Offset(0f, (size.height - glowHeight) / 2f),
                size = Size(fillWidth, glowHeight),
                cornerRadius = CornerRadius(glowHeight / 2f, glowHeight / 2f),
                alpha = 0.08f + pulsePhase * 0.12f,
            )
            drawRoundRect(
                brush = activeBrush,
                topLeft = Offset(0f, activeTop),
                size = Size(fillWidth, activeHeight),
                cornerRadius = CornerRadius(activeHeight / 2f, activeHeight / 2f),
            )
        }
        Button(
            onClick = onNext,
            enabled = enabled,
            colors = ButtonDefaults.buttonColors(
                containerColor = Palette.accent,
                contentColor = Palette.accentInk,
            ),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 50.dp),
            shape = RoundedCornerShape(14.dp),
        ) {
            Text(cta, style = NoopType.headline)
        }
    }
}

@Composable
private fun StepShell(
    title: String? = null,
    subtitle: String? = null,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        if (title != null || subtitle != null) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                title?.let {
                    // Big SF-Rounded hero headline — the onboarding's first-impression voice.
                    Text(
                        it,
                        style = NoopType.display(30f),
                        color = Palette.textPrimary,
                        textAlign = TextAlign.Center,
                    )
                }
                subtitle?.let {
                    Text(
                        it,
                        style = NoopType.body,
                        color = Palette.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
        content()
    }
}

// MARK: - Steps

@Composable
private fun WelcomeStep() {
    StepShell {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 430.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            BrandMark(size = 120.dp)
            Spacer(Modifier.height(24.dp))
            Text(
                uiString(R.string.l10n_onboarding_screen_all_your_data_none_of_the_6fc6f26d),
                style = NoopType.title2,
                color = Palette.textSecondary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                uiString(R.string.l10n_onboarding_screen_a_private_window_into_your_recovery_b8dd2ff2),
                style = NoopType.body,
                color = Palette.textTertiary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun WhatItDoesStep(accountCopy: OnboardingAccountCopy) {
    StepShell(
        title = uiString(R.string.l10n_onboarding_screen_what_noop_does_b25b362d),
        subtitle = "Three quiet promises.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            FeatureRow(
                icon = Icons.Filled.AutoGraph,
                tint = Palette.accent,
                title = uiString(R.string.l10n_onboarding_screen_see_recovery_clearly_d8db34a9),
                body = "A signature ring distils HRV, resting heart rate and sleep into one calm read on whether to push or rest.",
            )
            FeatureRow(
                icon = Icons.Filled.MonitorHeart,
                tint = Palette.accent,
                title = uiString(R.string.l10n_onboarding_screen_watch_your_heart_live_8c9c1267),
                body = "Connect Noop Band, a heart-rate strap, or a gym machine and watch each beat in real time: heart rate, variability, and zones as they happen. Already have history elsewhere? Import a wearable export, or use Health Connect, Apple Health, Oura, Fitbit, or Garmin.",
            )
            FeatureRow(
                icon = Icons.Filled.Lock,
                tint = Palette.statusPositive,
                title = stringResource(accountCopy.dataBoundaryTitle),
                body = stringResource(accountCopy.dataBoundaryBody),
            )
        }
    }
}

@Composable
private fun ExpectationsStep() {
    StepShell(
        title = uiString(R.string.l10n_onboarding_screen_what_to_expect_ed98f851),
        subtitle = "A few honest words, so nothing's a surprise.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            AppChangelog.expectations.forEach { e ->
                ExpectationCard(e)
            }
        }
    }
}

@Composable
private fun BluetoothStep(accountCopy: OnboardingAccountCopy) {
    StepShell(
        title = uiString(R.string.l10n_onboarding_screen_a_quick_word_before_you_connect_5a29015a),
        subtitle = "Android will ask for Bluetooth in a moment.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            IconBadge(icon = Icons.Filled.Bluetooth, tint = Palette.accent, size = 86)
            InfoCard(
                icon = Icons.Filled.Lock,
                tint = Palette.statusPositive,
                title = stringResource(R.string.onboarding_direct_local_bluetooth),
                message = stringResource(accountCopy.bluetoothBoundaryBody),
            )
            Text(
                stringResource(R.string.onboarding_bluetooth_permission_prompt),
                style = NoopType.subhead,
                color = Palette.textTertiary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun WearStep() {
    StepShell(
        title = uiString(R.string.l10n_onboarding_screen_put_your_strap_on_031d4807),
        subtitle = "And make sure it's charged.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            IconBadge(icon = Icons.Filled.Watch, tint = Palette.accent, size = 86)
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Checkline("Wear it snug on your wrist or bicep, sensor against skin.")
                    Checkline("Give it a few minutes of charge if the battery is low.")
                    Checkline("Keep it within about a metre of this phone.")
                }
            }
        }
    }
}

@Composable
private fun ConnectStep(
    setupComplete: Boolean,
    setupReadFailed: Boolean,
    canContinueWithoutBand: Boolean,
    requiresClaimEligibleBand: Boolean,
    onChooseDevice: () -> Unit,
    onRetrySetupRead: () -> Unit,
) {
    val title = stringResource(R.string.appwide_onboarding_device_setup_title)
    val body = stringResource(
        if (requiresClaimEligibleBand) {
            R.string.appwide_onboarding_claim_band_setup_body
        } else {
            R.string.appwide_onboarding_device_setup_body
        },
    )
    val action = stringResource(R.string.appwide_onboarding_device_setup_action)
    StepShell(
        title = title,
        subtitle = body,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            IconBadge(
                icon = if (setupComplete) {
                    Icons.Filled.CheckCircle
                } else {
                    Icons.Filled.AddCircle
                },
                tint = if (setupComplete) {
                    Palette.statusPositive
                } else {
                    Palette.accent
                },
                size = 92,
            )

            if (setupComplete) {
                StatePill(
                    stringResource(
                        R.string.appwide_onboarding_device_ready_title,
                    ),
                    tone = StrandTone.Positive,
                    pulsing = false,
                    showsDot = true,
                )
            }

            Button(
                onClick = onChooseDevice,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Palette.accent,
                    contentColor = Palette.accentInk,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = action },
            ) {
                Icon(
                    Icons.Filled.AddCircle,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(action, style = NoopType.body)
            }

            if (setupReadFailed) {
                Text(
                    stringResource(
                        R.string.appwide_onboarding_device_setup_read_failed,
                    ),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                    textAlign = TextAlign.Center,
                )
                Button(
                    onClick = onRetrySetupRead,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.surfaceRaised,
                        contentColor = Palette.textPrimary,
                    ),
                ) {
                    Text(
                        stringResource(R.string.appwide_trends_retry),
                        style = NoopType.body,
                    )
                }
            }

            if (canContinueWithoutBand && !setupComplete) {
                Text(
                    stringResource(
                        R.string.appwide_onboarding_continue_without_band,
                    ),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

// A short celebration after a real device source is saved. This intentionally avoids claiming a
// current physical connection because supplier setup completion is registry-backed, not live.bonded.
@Composable
private fun BondedStep() {
    StepShell {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 430.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            IconBadge(
                icon = Icons.Filled.Check,
                tint = Palette.statusPositive,
                size = 160,
            )
            Spacer(Modifier.height(24.dp))
            Text(
                stringResource(
                    R.string.appwide_onboarding_device_ready_title,
                ),
                style = NoopType.title1,
                color = Palette.textPrimary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(10.dp))
            Text(
                stringResource(
                    R.string.appwide_onboarding_device_ready_body,
                ),
                style = NoopType.body,
                color = Palette.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun ProfileStep() {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context.applicationContext) }
    // Weight and height are independent display choices. The stored profile always stays kg/cm; each
    // wheel converts its selected display value back to SI. Reading these also migrates an existing
    // combined Metric/Imperial preference once, so upgrades retain the exact presentation users had.
    var massUnit by remember { mutableStateOf(UnitPrefs.mass(context)) }
    var heightUnit by remember { mutableStateOf(UnitPrefs.height(context)) }
    var rev by remember { mutableIntStateOf(0) }
    fun mutate(block: () -> Unit) {
        block()
        rev++
    }
    @Suppress("UNUSED_VARIABLE") val tick = rev

    val zone = remember { ZoneId.systemDefault() }
    val today = LocalDate.now(zone)
    val minimumBirthDate = remember(today) { today.minusYears(100) }
    val maximumBirthDate = remember(today) { today.minusYears(13) }
    val birthDate = remember(rev, profile.dateOfBirthMillis) {
        Instant.ofEpochMilli(profile.dateOfBirthMillis)
            .atZone(zone)
            .toLocalDate()
            .coerceIn(minimumBirthDate, maximumBirthDate)
    }
    val birthDateLabel = remember(birthDate) {
        birthDate.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
    }
    fun pickBirthDate() {
        DatePickerDialog(
            context,
            { _, year, month, day ->
                val selected = LocalDate.of(year, month + 1, day)
                    .coerceIn(minimumBirthDate, maximumBirthDate)
                mutate {
                    profile.dateOfBirthMillis = selected
                        .atStartOfDay(zone)
                        .toInstant()
                        .toEpochMilli()
                }
            },
            birthDate.year,
            birthDate.monthValue - 1,
            birthDate.dayOfMonth,
        ).apply {
            datePicker.minDate = minimumBirthDate.atStartOfDay(zone).toInstant().toEpochMilli()
            datePicker.maxDate = maximumBirthDate.atStartOfDay(zone).toInstant().toEpochMilli()
        }.show()
    }

    // Wheel-picker option lists keep storage in SI while the independent display choices can be mixed.
    val weightStepsKg = remember(massUnit) {
        when (massUnit) {
            MassUnit.KILOGRAMS -> generateSequence(30.0) { it + 0.5 }
                .takeWhile { it <= 250.0001 }
                .toList()
            MassUnit.POUNDS -> (66..551).map { UnitFormatter.poundsToKg(it.toDouble()) }
        }
    }
    val heightStepsCm = remember(heightUnit) {
        when (heightUnit) {
            HeightUnit.CENTIMETERS -> (120..230).map(Int::toDouble)
            HeightUnit.FEET_INCHES -> (47..91).map { UnitFormatter.inchesToCm(it.toDouble()) }
        }
    }
    val weightOptions = remember(massUnit, weightStepsKg) {
        when (massUnit) {
            MassUnit.KILOGRAMS -> weightStepsKg.map { UnitFormatter.massFromKilograms(it, massUnit) }
            MassUnit.POUNDS -> weightStepsKg.map { "${UnitFormatter.kgToPounds(it).roundToInt()} lb" }
        }
    }
    val heightOptions = remember(heightUnit, heightStepsCm) {
        heightStepsCm.map { UnitFormatter.heightFromCentimeters(it, heightUnit) }
    }

    StepShell(
        title = uiString(R.string.l10n_onboarding_screen_about_you_5c4698b6),
        subtitle = "So your zones, calories and baselines are accurate.",
    ) {
        NoopCard(padding = 18.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(onClickLabel = "Choose date of birth", onClick = ::pickBirthDate)
                        .padding(horizontal = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(
                        stringResource(R.string.onboarding_date_of_birth),
                        style = NoopType.body,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Column(horizontalAlignment = Alignment.End) {
                        Text(birthDateLabel, style = NoopType.bodyNumber, color = Palette.textPrimary)
                        Text(
                            stringResource(R.string.onboarding_age_years, profile.age),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                }
                ThinDivider()
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Sex", color = Palette.textTertiary)
                    SegmentedPillControl(
                        items = ONBOARDING_SEX_OPTIONS,
                        selection = ONBOARDING_SEX_OPTIONS.firstOrNull { it.tag == profile.sex }
                            ?: ONBOARDING_SEX_OPTIONS[0],
                        label = { it.label },
                        onSelect = { mutate { profile.sex = it.tag } },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                ThinDivider()
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Overline("Weight", modifier = Modifier.weight(1f), color = Palette.textTertiary)
                        Box(modifier = Modifier.width(132.dp)) {
                            SegmentedPillControl(
                                items = listOf(MassUnit.KILOGRAMS, MassUnit.POUNDS),
                                selection = massUnit,
                                label = { if (it == MassUnit.KILOGRAMS) "kg" else "lb" },
                                onSelect = {
                                    massUnit = it
                                    NoopPrefs.setMassUnit(context, it)
                                },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        WheelPickerField(
                            value = UnitFormatter.massFromKilograms(profile.weightKg, massUnit),
                            accessibility = "Weight",
                            options = weightOptions,
                            selectedIndex = weightStepsKg.indices.minByOrNull {
                                kotlin.math.abs(weightStepsKg[it] - profile.weightKg)
                            } ?: 0,
                            dialogTitle = "Weight",
                            onSelected = { mutate { profile.weightKg = weightStepsKg[it] } },
                        )
                    }
                }
                ThinDivider()
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Overline("Height", modifier = Modifier.weight(1f), color = Palette.textTertiary)
                        Box(modifier = Modifier.width(144.dp)) {
                            SegmentedPillControl(
                                items = listOf(HeightUnit.CENTIMETERS, HeightUnit.FEET_INCHES),
                                selection = heightUnit,
                                label = { if (it == HeightUnit.CENTIMETERS) "cm" else "ft / in" },
                                onSelect = {
                                    heightUnit = it
                                    NoopPrefs.setHeightUnit(context, it)
                                },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        WheelPickerField(
                            value = UnitFormatter.heightFromCentimeters(profile.heightCm, heightUnit),
                            accessibility = "Height",
                            options = heightOptions,
                            selectedIndex = heightStepsCm.indices.minByOrNull {
                                kotlin.math.abs(heightStepsCm[it] - profile.heightCm)
                            } ?: 0,
                            dialogTitle = "Height",
                            onSelected = { mutate { profile.heightCm = heightStepsCm[it] } },
                        )
                    }
                }
            }
        }

        Text(
            stringResource(R.string.onboarding_units_independent),
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
        )

        Row(
            modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_onboarding_screen_estimated_max_heart_rate_profile_hrmax_622da889, profile.hrMax) },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.FavoriteBorder, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(17.dp))
            Text(
                uiString(R.string.l10n_onboarding_screen_estimated_max_heart_rate_profile_hrmax_06356290, profile.hrMax),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun ImportStep(viewModel: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // busy stays transient: a config change / process death cancels the import coroutine,
    // so a persisted busy=true would strand the buttons disabled with nothing running.
    var busy by remember { mutableStateOf(false) }
    var status by rememberSaveable { mutableStateOf<String?>(null) }

    fun runImport(block: suspend () -> ImportSummary) {
        busy = true
        status = "Importing…"
        scope.launch {
            val summary = withContext(Dispatchers.IO) {
                runCatching { block() }.getOrElse { ImportSummary.failure("Import", it.message ?: "failed") }
            }
            // Import & Data Ingest test mode (Test Centre): emit the parser / per-stage / day-delta trace,
            // tagged IMPORT, iff the mode is on. Gated zero-cost when off; shared with the Data Sources flow.
            emitImportTrace(context, viewModel, summary)
            busy = false
            val visibleMessage = CustomerFacingBrand.text(summary.message)
            status = visibleMessage
            Toast.makeText(context, visibleMessage, Toast.LENGTH_LONG).show()
        }
    }

    val whoopImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { WhoopCsvImporter.importZip(context, uri, viewModel.repo) } }

    val appleImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { AppleHealthImporter.importExport(context, uri, viewModel.repo) } }

    val hcPermissionLauncher = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) {
        scope.launch {
            // The contract may return only the scopes requested in this launch. Re-read the complete
            // grant set so an existing partial grant still imports after a newly added scope is declined.
            val granted = runCatching {
                HealthConnectImporter.client(context).permissionController.getGrantedPermissions()
            }.getOrDefault(emptySet())
            if (granted.any { it in HealthConnectImporter.PERMISSIONS }) {
                runImport {
                    HealthConnectReconciler.importNow(
                        context = context,
                        repository = viewModel.repo,
                        currentHeightCm = {
                            ProfileStore.from(context).bodyCompositionImportHeightCm
                        },
                    )
                }
            } else {
                val message = "Health Connect access not granted."
                status = message
                Toast.makeText(context, message, Toast.LENGTH_LONG).show()
            }
        }
    }

    val healthConnectAvailable = remember {
        HealthConnectImporter.sdkStatus(context) == HealthConnectClient.SDK_AVAILABLE
    }

    fun startHealthConnect() {
        scope.launch {
            val granted = runCatching {
                HealthConnectImporter.client(context).permissionController.getGrantedPermissions()
            }.getOrDefault(emptySet())
            val missing = HealthConnectImporter.missingReadPermissions(granted)
            if (missing.isEmpty()) {
                runImport {
                    HealthConnectReconciler.importNow(
                        context = context,
                        repository = viewModel.repo,
                        currentHeightCm = {
                            ProfileStore.from(context).bodyCompositionImportHeightCm
                        },
                    )
                }
            } else {
                hcPermissionLauncher.launch(missing)
            }
        }
    }

    StepShell(
        title = uiString(R.string.l10n_onboarding_screen_bring_your_history_5b8775c9),
        subtitle = "Optional: import now, or skip and return to Data Sources later.",
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            IconBadge(icon = Icons.Filled.Storage, tint = Palette.accent, size = 82)
            InfoCard(
                icon = Icons.Filled.AutoGraph,
                tint = Palette.accent,
                title = uiString(R.string.l10n_onboarding_screen_history_fills_the_dashboard_immediately_9728dde5),
                message = "A wearable export backfills recovery, strain, sleep and workouts. Health Connect can add steps, HR, HRV, sleep, absolute body temperature and weight from Android sources.",
            )

            NoopCard(padding = 16.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OnboardingActionButton(
                        label = uiString(R.string.l10n_onboarding_screen_import_whoop_export_zip_16f4176b),
                        icon = Icons.Filled.FileUpload,
                        enabled = !busy,
                    ) { whoopImportLauncher.launch(arrayOf("*/*")) }
                    OnboardingActionButton(
                        label = uiString(R.string.l10n_onboarding_screen_import_from_health_connect_35d55e21),
                        icon = Icons.Filled.MonitorHeart,
                        enabled = !busy && healthConnectAvailable,
                    ) { startHealthConnect() }
                    OnboardingActionButton(
                        label = uiString(R.string.l10n_onboarding_screen_import_apple_health_export_077b5624),
                        icon = Icons.Filled.FavoriteBorder,
                        enabled = !busy,
                    ) { appleImportLauncher.launch(arrayOf("*/*")) }
                }
            }

            if (!healthConnectAvailable) {
                Text(
                    uiString(R.string.l10n_onboarding_screen_health_connect_is_not_available_on_0336b16d),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
            status?.let {
                Text(
                    it,
                    style = NoopType.footnote,
                    color = if (busy) Palette.accent else Palette.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun NotificationsStep(
    dailyReviewOptIn: Boolean,
    onDailyReviewOptIn: (Boolean) -> Unit,
) {
    StepShell(
        title = uiString(R.string.l10n_onboarding_screen_stay_in_the_loop_f54254af),
        subtitle = uiString(
            R.string.appwide_onboarding_notifications_background_status_subtitle,
        ),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            IconBadge(icon = Icons.Filled.Notifications, tint = Palette.accent, size = 86)
            InfoCard(
                icon = Icons.Filled.Bluetooth,
                tint = Palette.statusPositive,
                title = uiString(R.string.l10n_onboarding_screen_a_quiet_ongoing_status_97bf2a44),
                message = uiString(
                    R.string.appwide_onboarding_notifications_background_status_body,
                ),
            )
            Checkline(
                uiString(R.string.appwide_onboarding_notifications_wrist_alerts),
            )
            Checkline(
                uiString(R.string.appwide_onboarding_notifications_permission_help),
            )
            NoopCard(padding = 18.dp) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            stringResource(R.string.daily_review_onboarding_label),
                            style = NoopType.body,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(R.string.daily_review_onboarding_help),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    NoopToggleSwitch(
                        checked = dailyReviewOptIn,
                        onCheckedChange = onDailyReviewOptIn,
                    )
                }
            }
        }
    }
}

@Composable
private fun SafetyContactsStep() {
    val context = LocalContext.current
    val controller = remember(context) { SafetyPagingController(context) }

    StepShell(
        title = stringResource(R.string.safety_onboarding_title),
        subtitle = stringResource(R.string.safety_onboarding_subtitle),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Metrics.space16),
        ) {
            IconBadge(icon = Icons.Filled.Shield, tint = Palette.statusPositive, size = 86)
            NoopCard(padding = 18.dp) {
                SafetyContactsSetup(controller = controller)
            }
            Text(
                stringResource(R.string.safety_onboarding_pending_body),
                style = NoopType.footnote,
                color = Palette.textTertiary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

// A late step that tells new users NOOP's look is theirs to set — the same System / Light / Dark / Black
// choice that lives in Settings → Appearance, with a live preview. Writing the choice flips the whole
// app immediately (AppearancePrefs.mode is snapshot state; Palette re-resolves live), so the picker
// IS the preview — and three mini swatches show Light, dimensional Dark, and true OLED Black.
@Composable
private fun AppearanceStep() {
    val context = LocalContext.current
    var mode by remember { mutableStateOf(AppearancePrefs.mode) }

    StepShell(
        title = uiString(R.string.l10n_onboarding_screen_make_it_yours_54135155),
        subtitle = uiString(R.string.appearance_onboarding_subtitle),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            // Three mini look-swatches so the choice is concrete: warm-paper Light, dark blue-grey,
            // and true OLED Black.
            // An explicit choice carries the neutral accent rim. System leaves all three previews
            // unselected so it never appears as two simultaneous choices.
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                ThemeSwatch(
                    title = uiString(AppearanceMode.LIGHT.labelRes),
                    tokens = LightTokens,
                    selected = isAppearancePreviewSelected(mode, AppearanceMode.LIGHT),
                    modifier = Modifier.weight(1f),
                )
                ThemeSwatch(
                    title = uiString(AppearanceMode.DARK.labelRes),
                    tokens = DarkTokens,
                    selected = isAppearancePreviewSelected(mode, AppearanceMode.DARK),
                    modifier = Modifier.weight(1f),
                )
                ThemeSwatch(
                    title = uiString(AppearanceMode.BLACK.labelRes),
                    tokens = BlackTokens,
                    selected = isAppearancePreviewSelected(mode, AppearanceMode.BLACK),
                    modifier = Modifier.weight(1f),
                )
            }

            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(
                        uiString(R.string.l10n_onboarding_screen_theme_a797e309),
                        style = NoopType.body,
                        color = Palette.textPrimary,
                    )
                    SegmentedPillControl(
                        items = AppearanceMode.entries,
                        selection = mode,
                        label = { uiString(it.labelRes) },
                        onSelect = {
                            mode = it
                            // Persist + flip live — the rest of the onboarding (and the app) re-themes
                            // instantly, so the user sees their choice land before tapping Continue.
                            AppearancePrefs.set(context, it)
                        },
                        adaptsToAvailableWidth = true,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.Filled.Palette,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(17.dp),
                        )
                        Text(
                            uiString(mode.detailRes),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                }
            }
        }
    }
}

/**
 * A compact map of the real app shell just before hand-off. Optional automations remain untouched;
 * this page only shows where everyday reviews, logs, and controls live.
 */
@Composable
private fun DailyRhythmStep() {
    StepShell(
        title = stringResource(R.string.onboarding_rhythm_title),
        subtitle = stringResource(R.string.onboarding_rhythm_subtitle),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            FeatureRow(
                icon = Icons.Filled.WbSunny,
                tint = Palette.statusWarning,
                title = stringResource(R.string.onboarding_rhythm_morning_title),
                body = stringResource(R.string.onboarding_rhythm_morning_body),
            )
            FeatureRow(
                icon = Icons.Filled.AddCircle,
                tint = Palette.metricCyan,
                title = stringResource(R.string.onboarding_rhythm_quick_title),
                body = stringResource(R.string.onboarding_rhythm_quick_body),
            )
            FeatureRow(
                icon = Icons.Filled.Edit,
                tint = Palette.accent,
                title = stringResource(R.string.onboarding_rhythm_journal_title),
                body = stringResource(R.string.onboarding_rhythm_journal_body),
            )
            FeatureRow(
                icon = Icons.Filled.Bolt,
                tint = Palette.statusPositive,
                title = stringResource(R.string.onboarding_rhythm_automations_title),
                body = stringResource(R.string.onboarding_rhythm_automations_body),
            )
        }
    }
}

/** A small fixed-palette look-swatch (a surface chip + accent ring + hairline) so the user can see a
 *  theme without switching to it. Uses the passed token set directly (not the live Palette) so each
 *  finish stays visible whatever the current theme. */
@Composable
private fun ThemeSwatch(
    title: String,
    tokens: PaletteTokens,
    selected: Boolean,
    modifier: Modifier = Modifier,
) {
    val previewAccent = themeSwatchAccent(tokens)
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(76.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(tokens.surfaceBase)
                .border(
                    width = if (selected) 2.dp else 1.dp,
                    color = if (selected) previewAccent else tokens.hairline,
                    shape = RoundedCornerShape(14.dp),
                )
                .padding(12.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                // A mini score bead in this PREVIEW's accent, not the currently selected app accent.
                Box(
                    modifier = Modifier
                        .size(24.dp)
                        .clip(CircleShape)
                        .background(previewAccent),
                )
                Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Box(
                        modifier = Modifier
                            .width(30.dp)
                            .height(7.dp)
                            .clip(RoundedCornerShape(50))
                            .background(tokens.surfaceRaised),
                    )
                    Box(
                        modifier = Modifier
                            .width(20.dp)
                            .height(7.dp)
                            .clip(RoundedCornerShape(50))
                            .background(tokens.hairlineStrong),
                    )
                }
            }
        }
        Text(
            title,
            style = NoopType.footnote,
            color = if (selected) Palette.accent else Palette.textTertiary,
        )
    }
}

@Composable
private fun DoneStep() {
    StepShell {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 430.dp)
                .padding(horizontal = 4.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                uiString(R.string.l10n_onboarding_screen_your_thread_starts_here_acdccf92),
                style = NoopType.title1,
                color = Palette.textPrimary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                uiString(R.string.l10n_onboarding_screen_every_beat_every_night_every_day_ab536123),
                style = NoopType.body,
                color = Palette.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

// MARK: - Pieces

@Composable
private fun FeatureRow(icon: ImageVector, tint: Color, title: String, body: String) {
    NoopCard(padding = 16.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            IconSquare(icon = icon, tint = tint)
            Column(verticalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.weight(1f)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(body, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun ExpectationCard(e: AppChangelog.Expectation) {
    NoopCard(padding = 14.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(e.icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(22.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(CustomerFacingBrand.text(e.title), style = NoopType.headline, color = Palette.textPrimary)
                Text(CustomerFacingBrand.text(e.body), style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun InfoCard(icon: ImageVector, tint: Color, title: String, message: String) {
    NoopCard(padding = 16.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            IconSquare(icon = icon, tint = tint)
            Column(verticalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.weight(1f)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(message, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun OnboardingActionButton(
    label: String,
    icon: ImageVector,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
        colors = ButtonDefaults.buttonColors(
            containerColor = Palette.accent,
            contentColor = Palette.accentInk,
            disabledContainerColor = Palette.surfaceInset,
            disabledContentColor = Palette.textTertiary,
        ),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, style = NoopType.body)
    }
}

@Composable
private fun Checkline(text: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Check, contentDescription = null, tint = Palette.statusPositive, modifier = Modifier.size(17.dp))
        Text(text, style = NoopType.subhead, color = Palette.textSecondary, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun IconBadge(icon: ImageVector, tint: Color, size: Int) {
    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.13f))
            .border(1.dp, tint.copy(alpha = 0.28f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size((size * 0.42f).dp))
    }
}

@Composable
private fun IconSquare(icon: ImageVector, tint: Color) {
    Box(
        modifier = Modifier
            .size(42.dp)
            .clip(RoundedCornerShape(11.dp))
            .background(tint.copy(alpha = 0.13f))
            .border(1.dp, tint.copy(alpha = 0.22f), RoundedCornerShape(11.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
    }
}

/** Label-left, control-right form row — mirrors Settings' FormRow so profile editors match. */
@Composable
private fun ProfileFieldRow(label: String, control: @Composable () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(label, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        control()
    }
}

@Composable
private fun ThinDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}

private data class OnboardingSexOption(val tag: String, val label: String)

private val ONBOARDING_SEX_OPTIONS = listOf(
    OnboardingSexOption("male", "Male"),
    OnboardingSexOption("female", "Female"),
    OnboardingSexOption("nonbinary", "Other"),
)
