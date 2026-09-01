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
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
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
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
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
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.noop.ble.WhoopModel
import com.noop.data.ImportSummary
import com.noop.ingest.AppleHealthImporter
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.WhoopCsvImporter
import com.noop.notif.DailyReviewReminders
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
    val pages = remember { OnboardingPage.entries }
    // rememberSaveable so a config change (rotation, dark-mode, font-scale, locale,
    // multi-window) doesn't recreate the Activity and throw the user back to page 1.
    var pageIndex by rememberSaveable { mutableIntStateOf(0) }
    val page = pages[pageIndex]
    var dailyReviewOptIn by rememberSaveable {
        mutableStateOf(DailyReviewReminders.isEnabled(context))
    }
    // Onboarding can compose while Activity attachment is still wiring its lifecycle owner.
    // These are cheap hot StateFlows, so avoid the lifecycle-owner-dependent collector here.
    val live by viewModel.live.collectAsState()

    // The bonded celebration only makes sense once a strap is actually bonded. Auto-advance to it
    // the moment that happens on the Connect step (mirrors macOS's scan → celebration), and skip
    // it in both directions when nothing is bonded so it never shows a false "You're connected".
    LaunchedEffect(live.bonded) {
        if (live.bonded && page == OnboardingPage.Connect) pageIndex++
    }

    fun complete() {
        // Onboarding deferred the foreground promotion; do it now if a strap is live.
        viewModel.promoteBackgroundConnectionIfActive()
        onFinished()
    }

    // Each permission is requested as the user LEAVES the step that explains it — never on top of
    // the explaining screen, and never at launch: Bluetooth on the "before you connect" step,
    // notifications on the dedicated notifications step. We advance once the prompt is dismissed,
    // whatever the result. blePermissions() is the same shared source of truth Live/Settings use.
    val blePerms = remember { blePermissions() }
    val bleAdvanceLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { pageIndex++ }
    val notifAdvanceLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        dailyReviewOptIn = dailyReviewOptIn && granted &&
            DailyReviewReminders.setEnabled(context, true)
        if (!dailyReviewOptIn) DailyReviewReminders.setEnabled(context, false)
        pageIndex++
    }

    fun advance() {
        if (page == OnboardingPage.Profile) {
            // Save & Continue explicitly accepts both visible inputs, including intentionally keeping
            // the seeded editor values. Until this tap, age-shaped estimates remain unavailable.
            ProfileStore.from(context).confirmFitnessInputs()
        }
        when (page) {
            OnboardingPage.Bluetooth -> {
                val granted = blePerms.all {
                    ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
                }
                if (!granted) { bleAdvanceLauncher.launch(blePerms); return }
            }
            OnboardingPage.Connect -> {
                // No strap bonded → skip the celebration and go straight to Profile.
                if (!live.bonded) { pageIndex = pages.indexOf(OnboardingPage.Profile); return }
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
        pageIndex++
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
                    // Skip the bonded celebration going back when nothing is bonded.
                    if (target >= 0 && pages[target] == OnboardingPage.Bonded && !live.bonded) target--
                    if (target >= 0) pageIndex = target
                }
                OnboardingTopBar(
                    page = pageIndex + 1,
                    total = pages.size,
                    canGoBack = pageIndex > 0,
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
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(top = 6.dp, bottom = 18.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        when (targetPage) {
                            OnboardingPage.Welcome -> WelcomeStep()
                            OnboardingPage.WhatItDoes -> WhatItDoesStep()
                            OnboardingPage.Expectations -> ExpectationsStep()
                            OnboardingPage.Bluetooth -> BluetoothStep()
                            OnboardingPage.Wear -> WearStep()
                            OnboardingPage.Connect -> ConnectStep(viewModel)
                            OnboardingPage.Bonded -> BondedStep(viewModel)
                            OnboardingPage.Profile -> ProfileStep()
                            OnboardingPage.Import -> ImportStep(viewModel)
                            OnboardingPage.Notifications -> NotificationsStep(
                                dailyReviewOptIn = dailyReviewOptIn,
                                onDailyReviewOptIn = { dailyReviewOptIn = it },
                            )
                            OnboardingPage.SafetyContacts -> SafetyContactsStep()
                            OnboardingPage.Appearance -> AppearanceStep()
                            OnboardingPage.DailyRhythm -> DailyRhythmStep()
                            OnboardingPage.Done -> DoneStep()
                        }
                    }
                }

                OnboardingFooter(
                    progress = if (pages.size <= 1) 1f else pageIndex.toFloat() / pages.lastIndex.toFloat(),
                    cta = page.cta,
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
}

private enum class OnboardingPage(val cta: String) {
    Welcome("Get Started"),
    WhatItDoes("Continue"),
    Expectations("I understand"),
    Bluetooth("Continue"),
    Wear("I'm wearing it"),
    Connect("Continue"),
    Bonded("Continue"),
    Profile("Save & Continue"),
    Import("Continue"),
    Notifications("Continue"),
    SafetyContacts("Finish later"),
    Appearance("Continue"),
    DailyRhythm("Continue"),
    Done("Enter NOOP");
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
    onNext: () -> Unit,
) {
    val animated by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        animationSpec = tween(Motion.durationStandard),
        label = uiString(R.string.l10n_onboarding_screen_onboardingprogress_6e1e5c29),
    )
    val pulseTransition = rememberInfiniteTransition(label = "onboarding thread pulse")
    val pulsePhase by pulseTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2_400, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "onboarding thread pulse phase",
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
                .height(3.dp),
        ) {
            val radius = size.height / 2f
            drawRoundRect(
                color = Palette.hairline,
                size = size,
                cornerRadius = CornerRadius(radius, radius),
            )
            val fillWidth = (size.width * animated).coerceAtLeast(size.height)
            drawRoundRect(
                brush = Brush.horizontalGradient(
                    colors = listOf(
                        Palette.statusCritical,
                        Palette.statusWarning,
                        Palette.statusPositive,
                    ),
                    endX = size.width,
                ),
                size = Size(fillWidth, size.height),
                cornerRadius = CornerRadius(radius, radius),
            )
            val pulseWidth = minOf(72.dp.toPx(), maxOf(size.height, fillWidth * 0.55f))
            val pulseStart = pulsePhase * (fillWidth - pulseWidth).coerceAtLeast(0f)
            drawRect(
                brush = Brush.horizontalGradient(
                    colors = listOf(
                        Color.Transparent,
                        Color.White.copy(alpha = 0.68f),
                        Color.Transparent,
                    ),
                    startX = pulseStart,
                    endX = pulseStart + pulseWidth,
                ),
                topLeft = Offset(pulseStart, 0f),
                size = Size(pulseWidth, size.height),
            )
        }
        Button(
            onClick = onNext,
            colors = ButtonDefaults.buttonColors(
                containerColor = Palette.accent,
                contentColor = Palette.surfaceBase,
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
private fun WhatItDoesStep() {
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
                title = uiString(R.string.l10n_onboarding_screen_own_your_data_offline_997fe15e),
                body = "Everything starts on this phone. No account or cloud is required. Data leaves only when you explicitly share it, use Coach, or enable your own self-hosted sync.",
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
private fun BluetoothStep() {
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
                message = "NOOP talks straight to Noop Band over Bluetooth Low Energy, with no project server in the middle. Readings stay on this phone unless you later enable an optional destination such as your own self-hosted server.",
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
private fun ConnectStep(viewModel: AppViewModel) {
    val context = LocalContext.current
    val live by viewModel.live.collectAsState()

    val blePerms = remember { blePermissions() }
    // The Scan button goes through the same shared gate as Live/Settings (requests the permission
    // if missing, then connects). Onboarding connects without promoting the foreground service —
    // OnboardingScreen promotes it on completion. See AppViewModel.connect(promoteService).
    val requestConnect = rememberRequestScan { viewModel.connect(promoteService = false) }
    var autoConnectStarted by rememberSaveable { mutableStateOf(false) }

    val bleGranted = blePerms.all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

    LaunchedEffect(Unit) {
        if (!autoConnectStarted && !live.bonded && !live.connected && !live.scanning) {
            autoConnectStarted = true
            // Only auto-scan if permission is already in hand (granted on the Bluetooth step). We
            // never raise the OS prompt here — that would land on top of this step's own content.
            if (bleGranted) viewModel.connect(promoteService = false)
        }
    }

    StepShell(
        title = uiString(R.string.l10n_onboarding_screen_find_your_strap_fe460461),
        subtitle = when {
            live.bonded -> "Bonded. You can keep going."
            bleGranted -> "NOOP starts looking as soon as this step appears. You can keep going while it bonds."
            else -> "Allow Bluetooth and tap Scan to find Noop Band, or keep going and connect later."
        },
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            IconBadge(
                icon = if (live.bonded) Icons.Filled.CheckCircle else Icons.Filled.Bluetooth,
                tint = if (live.bonded) Palette.statusPositive else Palette.accent,
                size = 92,
            )

            val (label, tone, pulsing) = when {
                live.encryptedBond -> Triple("Bonded · streaming", StrandTone.Positive, true)
                live.bonded -> Triple("Live HR · not fully paired", StrandTone.Warning, true)
                live.connected -> Triple("Connected · pairing", StrandTone.Warning, true)
                live.scanning -> Triple("Searching", StrandTone.Accent, true)
                else -> Triple("Ready to scan", StrandTone.Neutral, false)
            }
            StatePill(label, tone = tone, pulsing = pulsing, showsDot = true)

            live.statusNote?.let {
                Text(
                    CustomerFacingBrand.text(it),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }

            if (!live.bonded) {
                NoopCard(padding = 16.dp) {
                    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Icon(
                                Icons.Filled.Watch,
                                contentDescription = null,
                                tint = Palette.accent,
                                modifier = Modifier.size(20.dp),
                            )
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    WhoopModel.CUSTOMER_NAME,
                                    style = NoopType.subhead,
                                    color = Palette.textPrimary,
                                )
                                Text(
                                    "Compatible hardware is detected automatically.",
                                    style = NoopType.footnote,
                                    color = Palette.textTertiary,
                                )
                            }
                        }

                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            Button(
                                onClick = { requestConnect() },
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = Palette.accent,
                                    contentColor = Palette.surfaceBase,
                                ),
                                modifier = Modifier.weight(1f),
                            ) {
                                Icon(Icons.Filled.Bluetooth, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(if (live.connected || live.scanning) "Re-scan" else "Scan again", style = NoopType.body)
                            }
                            OutlinedButton(
                                onClick = { viewModel.disconnect() },
                                enabled = live.connected || live.scanning,
                                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.statusCritical),
                                modifier = Modifier.weight(1f),
                            ) {
                                Text(uiString(R.string.l10n_onboarding_screen_stop_9e253470), style = NoopType.body)
                            }
                        }
                    }
                }
            }

            InfoCard(
                icon = Icons.Filled.Lock,
                tint = Palette.statusPositive,
                title = uiString(R.string.l10n_onboarding_screen_this_can_run_while_you_finish_cd7ef783),
                message = "If the strap is nearby, NOOP will keep the BLE link alive in the background. You can continue through profile and import while it bonds.",
            )

            // WHOOP is NOOP's primary band, so onboarding leads with it — but it isn't required.
            // Make that obvious so a non-WHOOP user doesn't feel stuck on this step (#415-adjacent):
            // they can continue now and pair a heart-rate strap or import data afterwards.
            if (!live.bonded) {
                Text(
                    "No Noop Band? You can still continue. Pair another heart-rate strap, watch, ring, " +
                        "or gym machine under Devices, or import a wearable export, Apple Health, Oura, Fitbit, Garmin " +
                        "and more under Data Sources. You can do either any time.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

// A short celebration once the strap bonds — the Connect step auto-advances here on bond, and
// the nav skips it entirely when nothing is bonded (mirrors the macOS scan → bonded moment).
@Composable
private fun BondedStep(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsState()
    StepShell {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 430.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Box(contentAlignment = Alignment.Center) {
                RecoveryRing(score = 100.0, diameter = 200.dp, lineWidth = 14.dp, showsLabel = false)
                Icon(
                    Icons.Filled.Check,
                    contentDescription = null,
                    tint = Palette.statusPositive,
                    modifier = Modifier.size(54.dp),
                )
            }
            Spacer(Modifier.height(24.dp))
            Text(
                uiString(R.string.l10n_onboarding_screen_you_re_connected_7e06aee0),
                style = NoopType.title1,
                color = Palette.textPrimary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(10.dp))
            Text(
                live.batteryPct?.let { "Noop Band is paired · ${it.toInt()}% battery." }
                    ?: "Noop Band is paired and ready to stream.",
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
                    HealthConnectImporter.import(
                        context,
                        viewModel.repo,
                        ProfileStore.from(context).heightCm,
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
                runImport { HealthConnectImporter.import(context, viewModel.repo, ProfileStore.from(context).heightCm) }
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
        subtitle = "NOOP keeps Noop Band connected in the background. When you continue, allow notifications so it can show that link and reach your wrist.",
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
                message = "NOOP holds the Bluetooth link open in the background so your data stays current. One low-priority notification shows it's connected. Nothing noisy.",
            )
            Checkline("Wrist alerts (strain nudges and your smart alarm) arrive as notifications too.")
            Checkline("When Android asks, allow notifications so NOOP can keep you informed.")
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
                    Switch(
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
            contentColor = Palette.surfaceBase,
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
