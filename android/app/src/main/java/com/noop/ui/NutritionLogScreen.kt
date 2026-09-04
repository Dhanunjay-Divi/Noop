package com.noop.ui

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import com.noop.R
import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.noop.data.NutritionBarcodeLookupException
import com.noop.data.NutritionBarcodeLookupFailure
import com.noop.data.NutritionCatalogContract
import com.noop.data.NutritionCatalogItemRow
import com.noop.data.NutritionDailyTotals
import com.noop.data.NutritionEntryRow
import com.noop.data.NutritionLogContract
import com.noop.data.LabMarkerRow
import java.text.NumberFormat
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import java.util.UUID
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.coroutines.launch

private data class NutritionEditorContext(
    val entry: NutritionEntryRow?,
    val day: LocalDate,
    val catalogItem: NutritionCatalogItemRow? = null,
)

private data class NutritionScreenSnapshot(
    val entries: List<NutritionEntryRow>,
    val totals: NutritionDailyTotals,
    val recentEntries: List<NutritionEntryRow>,
    val fastingGlucose: LabMarkerRow?,
)

internal object NutritionSummaryContract {
    const val FASTING_GLUCOSE_KEY = "fasting_glucose"
    const val LAB_BOOK_DEVICE_ID = "my-whoop"
    const val MACRO_DOT_CAPACITY = 24

    fun latestFastingGlucose(rows: List<LabMarkerRow>, throughDay: String): LabMarkerRow? =
        rows.asSequence()
            .filter {
                it.markerKey == FASTING_GLUCOSE_KEY &&
                    it.day <= throughDay &&
                    it.value?.isFinite() == true
            }
            .maxWithOrNull(compareBy<LabMarkerRow> { it.takenAt }.thenBy { it.id })

    fun bestEffortLatestFastingGlucose(
        rows: List<LabMarkerRow>?,
        throughDay: String,
    ): LabMarkerRow? = rows?.let { latestFastingGlucose(it, throughDay) }

    fun relativeMacroDotCount(
        value: Double?,
        values: List<Double?>,
        capacity: Int = MACRO_DOT_CAPACITY,
    ): Int {
        if (capacity <= 0 || value == null || !value.isFinite() || value <= 0.0) return 0
        val maximum = values.filterNotNull().filter { it.isFinite() && it > 0.0 }.maxOrNull() ?: 0.0
        if (maximum <= 0.0) return 0
        return ceil(value / maximum * capacity.toDouble()).toInt().coerceIn(1, capacity)
    }
}

private enum class NutritionMeal(val storage: String, @StringRes val labelRes: Int) {
    Breakfast("breakfast", R.string.nutrition_meal_breakfast),
    Lunch("lunch", R.string.nutrition_meal_lunch),
    Dinner("dinner", R.string.nutrition_meal_dinner),
    Snack("snack", R.string.nutrition_meal_snack),
    Other("other", R.string.nutrition_meal_other);

    companion object {
        fun fromStorage(value: String?): NutritionMeal =
            entries.firstOrNull { it.storage == value } ?: Other
    }
}

/** Local-first editable meals plus clearly labeled imported daily summaries. */
@Composable
fun NutritionLogScreen(vm: AppViewModel) {
    val appContext = LocalContext.current
    val scope = rememberCoroutineScope()
    val today = LocalDate.now()
    var selectedDay by remember { mutableStateOf(today) }
    var entries by remember { mutableStateOf<List<NutritionEntryRow>>(emptyList()) }
    var recentEntries by remember { mutableStateOf<List<NutritionEntryRow>>(emptyList()) }
    var totals by remember {
        mutableStateOf(NutritionDailyTotals(null, null, null, null))
    }
    var fastingGlucose by remember { mutableStateOf<LabMarkerRow?>(null) }
    var loading by remember { mutableStateOf(true) }
    var reloadToken by remember { mutableIntStateOf(0) }
    var editor by remember { mutableStateOf<NutritionEditorContext?>(null) }
    var saving by remember { mutableStateOf(false) }
    var deleteCandidate by remember { mutableStateOf<NutritionEntryRow?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var quickSavingId by remember { mutableStateOf<String?>(null) }
    var showBarcodeLookup by remember { mutableStateOf(false) }
    var barcodeInput by remember { mutableStateOf("") }
    var barcodeToLookup by remember { mutableStateOf<String?>(null) }
    var barcodeLoading by remember { mutableStateOf(false) }
    var showLibrary by remember { mutableStateOf(false) }
    var libraryItems by remember { mutableStateOf<List<NutritionCatalogItemRow>>(emptyList()) }
    var libraryLoading by remember { mutableStateOf(false) }
    var libraryReloadToken by remember { mutableIntStateOf(0) }
    var deletingLibraryId by remember { mutableStateOf<String?>(null) }

    val barcodeScanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.takeIf { it.isNotBlank() }?.let {
            barcodeInput = it
            barcodeToLookup = it
        }
    }

    LaunchedEffect(barcodeToLookup) {
        val requested = barcodeToLookup ?: return@LaunchedEffect
        barcodeLoading = true
        runCatching { vm.repo.lookupNutritionBarcode(requested) }
            .onSuccess { item ->
                showBarcodeLookup = false
                editor = NutritionEditorContext(null, selectedDay, item)
            }
            .onFailure { errorMessage = it.userFacingNutritionMessage(appContext) }
        barcodeLoading = false
        barcodeToLookup = null
    }

    LaunchedEffect(showLibrary, libraryReloadToken) {
        if (!showLibrary) return@LaunchedEffect
        libraryLoading = true
        runCatching { vm.repo.nutritionCatalogItems(savedOnly = true) }
            .onSuccess { libraryItems = it }
            .onFailure { errorMessage = it.userFacingNutritionMessage(appContext) }
        libraryLoading = false
    }

    if (showBarcodeLookup) {
        NutritionBarcodeLookupDialog(
            barcode = barcodeInput,
            loading = barcodeLoading,
            onBarcodeChange = { barcodeInput = it },
            onDismiss = { if (!barcodeLoading) showBarcodeLookup = false },
            onScan = {
                barcodeScanner.launch(
                    ScanOptions()
                        .setDesiredBarcodeFormats(ScanOptions.PRODUCT_CODE_TYPES)
                        .setPrompt("")
                        .setBeepEnabled(false)
                        .setOrientationLocked(false),
                )
            },
            onLookup = { barcodeToLookup = barcodeInput },
        )
    }

    if (showLibrary) {
        NutritionLibraryDialog(
            items = libraryItems,
            loading = libraryLoading,
            deletingId = deletingLibraryId,
            onDismiss = { showLibrary = false },
            onSelect = {
                showLibrary = false
                editor = NutritionEditorContext(null, selectedDay, it)
            },
            onDelete = { item ->
                if (deletingLibraryId == null) {
                    deletingLibraryId = item.id
                    scope.launch {
                        runCatching { vm.repo.deleteNutritionCatalogItem(item.id) }
                            .onSuccess { libraryReloadToken += 1 }
                            .onFailure {
                                errorMessage = it.userFacingNutritionMessage(appContext)
                            }
                        deletingLibraryId = null
                    }
                }
            },
        )
    }

    LaunchedEffect(selectedDay, reloadToken) {
        val requested = selectedDay
        loading = true
        runCatching {
            val glucoseRows = runCatching {
                vm.repo.labMarkersByKey(
                    NutritionSummaryContract.LAB_BOOK_DEVICE_ID,
                    NutritionSummaryContract.FASTING_GLUCOSE_KEY,
                )
            }.getOrNull()
            NutritionScreenSnapshot(
                entries = vm.repo.nutritionEntries(requested.toString(), requested.toString()),
                totals = vm.repo.nutritionTotals(requested.toString()),
                recentEntries = vm.repo.recentManualNutritionEntries(
                    requested.toString(),
                    limit = 4,
                ),
                fastingGlucose = NutritionSummaryContract.bestEffortLatestFastingGlucose(
                    glucoseRows,
                    throughDay = requested.toString(),
                ),
            )
        }.onSuccess { snapshot ->
            if (selectedDay == requested) {
                entries = snapshot.entries
                totals = snapshot.totals
                recentEntries = snapshot.recentEntries
                fastingGlucose = snapshot.fastingGlucose
            }
        }.onFailure {
            if (selectedDay == requested) {
                entries = emptyList()
                recentEntries = emptyList()
                totals = NutritionDailyTotals(null, null, null, null)
                fastingGlucose = null
                errorMessage = it.userFacingNutritionMessage(appContext)
            }
        }
        if (selectedDay == requested) loading = false
    }

    editor?.let { context ->
        NutritionEntryDialog(
            entry = context.entry,
            day = context.day,
            catalogItem = context.catalogItem,
            saving = saving,
            onDismiss = { if (!saving) editor = null },
            onSave = { row, catalogItem ->
                if (!saving) {
                    saving = true
                    scope.launch {
                        runCatching {
                            vm.repo.upsertNutritionEntries(listOf(row))
                            if (catalogItem != null) {
                                vm.repo.upsertNutritionCatalogItems(listOf(catalogItem))
                            }
                            context.catalogItem?.let {
                                vm.repo.markNutritionCatalogItemUsed(
                                    it.id,
                                    System.currentTimeMillis() / 1_000L,
                                )
                            }
                        }
                            .onSuccess {
                                editor = null
                                reloadToken += 1
                            }
                            .onFailure { errorMessage = it.userFacingNutritionMessage(appContext) }
                        saving = false
                    }
                }
            },
        )
    }

    deleteCandidate?.let { candidate ->
        AlertDialog(
            onDismissRequest = { deleteCandidate = null },
            containerColor = Palette.surfaceOverlay,
            title = { Text(uiString(R.string.nutrition_delete_title), style = NoopType.title2) },
            text = {
                Text(
                    if (candidate.origin == NutritionLogContract.CSV_ORIGIN) {
                        uiString(R.string.nutrition_delete_imported_body)
                    } else {
                        uiString(R.string.nutrition_delete_manual_body)
                    },
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        deleteCandidate = null
                        scope.launch {
                            runCatching { vm.repo.deleteNutritionEntry(candidate.id) }
                                .onSuccess { reloadToken += 1 }
                                .onFailure { errorMessage = it.userFacingNutritionMessage(appContext) }
                        }
                    },
                ) { Text(uiString(R.string.nutrition_delete_action), color = Palette.statusCritical) }
            },
            dismissButton = {
                TextButton(onClick = { deleteCandidate = null }) {
                    Text(uiString(R.string.nutrition_cancel), color = Palette.textSecondary)
                }
            },
        )
    }

    errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { errorMessage = null },
            containerColor = Palette.surfaceOverlay,
            title = { Text(uiString(R.string.nutrition_alert_title), style = NoopType.title2) },
            text = { Text(message, style = NoopType.body, color = Palette.textSecondary) },
            confirmButton = {
                TextButton(onClick = { errorMessage = null }) {
                    Text(uiString(R.string.nutrition_ok), color = Palette.accent)
                }
            },
        )
    }

    ScreenScaffold(
        title = uiString(R.string.nutrition_title),
        subtitle = uiString(R.string.nutrition_subtitle),
        topBackground = { LiquidScreenSky() },
    ) {
        NutritionDateNavigator(
            selectedDay = selectedDay,
            today = today,
            onSelect = { selectedDay = it.coerceAtMost(today) },
        )
        NutritionTotalsCard(
            day = selectedDay,
            totals = totals,
            fastingGlucose = fastingGlucose,
            loading = loading,
            onAdd = { editor = NutritionEditorContext(null, selectedDay) },
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SectionHeader(
                uiString(R.string.nutrition_entries_title),
                overline = uiString(R.string.nutrition_entries_overline),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(Metrics.space12))
            IconButton(onClick = { showBarcodeLookup = true }) {
                Icon(
                    Icons.Filled.QrCodeScanner,
                    contentDescription = uiString(R.string.nutrition_actions_scan),
                    tint = Palette.accent,
                )
            }
            IconButton(onClick = { showLibrary = true }) {
                Icon(
                    Icons.Filled.Bookmarks,
                    contentDescription = uiString(R.string.nutrition_actions_library),
                    tint = Palette.accent,
                )
            }
            NoopButton(
                text = uiString(R.string.nutrition_entries_add),
                leadingIcon = Icons.Filled.Add,
                kind = NoopButtonKind.Secondary,
            ) { editor = NutritionEditorContext(null, selectedDay) }
        }

        if (recentEntries.isNotEmpty()) {
            NutritionQuickRepeat(
                entries = recentEntries,
                savingId = quickSavingId,
                onRepeat = { source ->
                    if (quickSavingId == null) {
                        quickSavingId = source.id
                        scope.launch {
                            val now = System.currentTimeMillis() / 1_000L
                            runCatching {
                                NutritionLogContract.repeatedManualEntry(
                                    source = source,
                                    id = UUID.randomUUID().toString(),
                                    day = selectedDay.toString(),
                                    occurredAt = repeatedNutritionOccurrence(selectedDay, source),
                                    timestamp = now,
                                )
                            }.mapCatching { repeated ->
                                vm.repo.upsertNutritionEntries(listOf(repeated))
                            }.onSuccess {
                                reloadToken += 1
                            }.onFailure {
                                errorMessage = it.userFacingNutritionMessage(appContext)
                            }
                            quickSavingId = null
                        }
                    }
                },
            )
        }

        if (recentEntries.isNotEmpty() && entries.isNotEmpty()) {
            Text(
                uiString(R.string.nutrition_entries_saved_title),
                style = NoopType.headline,
                color = Palette.textPrimary,
                modifier = Modifier.semantics { heading() },
            )
        }

        when {
            loading && entries.isEmpty() -> ScreenStateCard(
                kind = ScreenStateKind.Loading,
                title = uiString(R.string.nutrition_state_loading_title),
                body = uiString(R.string.nutrition_state_loading_body),
            )
            entries.isEmpty() -> ScreenStateCard(
                kind = ScreenStateKind.Empty,
                title = uiString(R.string.nutrition_state_empty_title),
                body = uiString(R.string.nutrition_state_empty_body),
            )
            else -> NoopCard(padding = 0.dp) {
                Column {
                    entries.forEachIndexed { index, entry ->
                        NutritionEntryListRow(
                            entry = entry,
                            onEdit = {
                                if (entry.origin != NutritionLogContract.CSV_ORIGIN) {
                                    editor = NutritionEditorContext(entry, selectedDay)
                                }
                            },
                            onDelete = { deleteCandidate = entry },
                        )
                        if (index < entries.lastIndex) {
                            HorizontalDivider(
                                color = Palette.hairline,
                                modifier = Modifier.padding(start = 58.dp),
                            )
                        }
                    }
                }
            }
        }

        NoopCard {
            Row(
                horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    Icons.Filled.Lock,
                    contentDescription = null,
                    tint = Palette.textSecondary,
                    modifier = Modifier.size(21.dp),
                )
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    Text(
                        uiString(R.string.nutrition_privacy_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        uiString(R.string.nutrition_privacy_body),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun NutritionDateNavigator(
    selectedDay: LocalDate,
    today: LocalDate,
    onSelect: (LocalDate) -> Unit,
) {
    val context = LocalContext.current
    NoopCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { onSelect(selectedDay.minusDays(1)) }) {
                Icon(
                    Icons.Filled.ChevronLeft,
                    contentDescription = uiString(R.string.nutrition_date_previous),
                    tint = Palette.accent,
                )
            }
            val pickDateLabel = uiString(R.string.nutrition_date_pick)
            Column(
                modifier = Modifier
                    .weight(1f)
                    .background(Palette.surfaceInset, RoundedCornerShape(Metrics.cornerSm))
                    .clickable(onClickLabel = pickDateLabel) {
                        DatePickerDialog(
                            context,
                            { _, year, month, day ->
                                onSelect(LocalDate.of(year, month + 1, day))
                            },
                            selectedDay.year,
                            selectedDay.monthValue - 1,
                            selectedDay.dayOfMonth,
                        ).apply {
                            datePicker.maxDate = System.currentTimeMillis()
                        }.show()
                    }
                    .padding(horizontal = Metrics.space12, vertical = Metrics.space8),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    when {
                        selectedDay == today -> uiString(R.string.nutrition_date_today)
                        selectedDay == today.minusDays(1) -> uiString(R.string.nutrition_date_yesterday)
                        else -> selectedDay.format(
                            DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM),
                        )
                    },
                    style = NoopType.caption,
                    color = Palette.textPrimary,
                )
                Text(
                    selectedDay.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)),
                    style = NoopType.captionNumber,
                    color = Palette.accent,
                )
            }
            IconButton(
                onClick = { onSelect(selectedDay.plusDays(1)) },
                enabled = selectedDay < today,
            ) {
                Icon(
                    Icons.Filled.ChevronRight,
                    contentDescription = uiString(R.string.nutrition_date_next),
                    tint = if (selectedDay < today) Palette.accent else Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun NutritionTotalsCard(
    day: LocalDate,
    totals: NutritionDailyTotals,
    fastingGlucose: LabMarkerRow?,
    loading: Boolean,
    onAdd: () -> Unit,
) {
    val shownTotals = if (loading) NutritionDailyTotals(null, null, null, null) else totals
    val shownGlucose = if (loading) null else fastingGlucose
    val accessibilityText = LocalDensity.current.fontScale > 1.3f

    NoopCard(tint = Palette.statusPositive) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    if (day == LocalDate.now()) {
                        uiString(R.string.nutrition_summary_today_foods)
                    } else {
                        day.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
                    },
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(Metrics.space12))
                IconButton(
                    onClick = onAdd,
                    modifier = Modifier
                        .size(36.dp)
                        .background(Palette.surfaceInset, CircleShape),
                ) {
                    Icon(
                        Icons.Filled.Add,
                        contentDescription = uiString(R.string.nutrition_entries_add_accessibility),
                        tint = Palette.accent,
                        modifier = Modifier.size(19.dp),
                    )
                }
            }

            BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
                if (!accessibilityText && maxWidth >= 282.dp) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        NutritionCalorieDial(shownTotals.caloriesKcal)
                        Spacer(Modifier.width(Metrics.space16))
                        NutritionMacroSummaryRow(
                            totals = shownTotals,
                            modifier = Modifier.weight(1f),
                        )
                    }
                } else {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(Metrics.space16),
                    ) {
                        NutritionCalorieDial(shownTotals.caloriesKcal)
                        if (accessibilityText) {
                            NutritionMacroSummaryColumn(
                                totals = shownTotals,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        } else {
                            NutritionMacroSummaryRow(
                                totals = shownTotals,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
            }

            HorizontalDivider(color = Palette.hairline)
            NutritionGlucoseSummary(shownGlucose)

            Text(
                nutritionTotalsExplanation(shownTotals),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun NutritionCalorieDial(value: Double?) {
    val hasValue = value != null
    val tint = if (hasValue) Palette.statusPositive else Palette.textTertiary
    val valueText = formatNutritionNumber(value, 0)
    val spoken = if (hasValue) {
        "${uiString(R.string.nutrition_nutrient_calories)}, $valueText kcal"
    } else {
        "${uiString(R.string.nutrition_nutrient_calories)}, " +
            uiString(R.string.nutrition_intake_no_calories)
    }
    val dialDiameter = (94f * LocalDensity.current.fontScale.coerceIn(1f, 2f)).dp

    Box(
        modifier = Modifier
            .size(dialDiameter)
            .semantics(mergeDescendants = true) { contentDescription = spoken },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val center = Offset(size.width / 2f, size.height / 2f)
            val tickRadius = size.minDimension / 2f - 2.dp.toPx()
            for (index in 0 until 48) {
                val angle = -PI / 2.0 + index * (2.0 * PI / 48.0)
                val point = Offset(
                    x = center.x + (cos(angle) * tickRadius).toFloat(),
                    y = center.y + (sin(angle) * tickRadius).toFloat(),
                )
                drawCircle(
                    color = tint.copy(alpha = if (hasValue) 0.42f else 0.18f),
                    radius = (if (index % 4 == 0) 1.25.dp else 0.8.dp).toPx(),
                    center = point,
                )
            }

            val ringRadius = size.minDimension / 2f - 15.dp.toPx()
            drawCircle(
                color = Palette.textPrimary.copy(alpha = 0.08f),
                radius = ringRadius,
                style = Stroke(width = 7.dp.toPx()),
            )
            drawCircle(
                color = tint.copy(alpha = if (hasValue) 0.9f else 0.28f),
                radius = ringRadius,
                style = Stroke(width = 5.dp.toPx()),
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                valueText,
                style = NoopType.number(21f).copy(fontWeight = FontWeight.Bold),
                color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
                maxLines = 1,
            )
            Text("kcal", style = NoopType.caption, color = Palette.textTertiary)
        }
    }
}

@Composable
private fun NutritionMacroSummaryRow(
    totals: NutritionDailyTotals,
    modifier: Modifier = Modifier,
) {
    val values = listOf(totals.proteinG, totals.carbsG, totals.fatG)
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        verticalAlignment = Alignment.Top,
    ) {
        NutritionMacroSummary(
            label = uiString(R.string.nutrition_nutrient_protein),
            value = totals.proteinG,
            tint = Palette.statusPositive,
            values = values,
            modifier = Modifier.weight(1f),
        )
        NutritionMacroSummary(
            label = uiString(R.string.nutrition_nutrient_carbs),
            value = totals.carbsG,
            tint = Palette.metricCyan,
            values = values,
            modifier = Modifier.weight(1f),
        )
        NutritionMacroSummary(
            label = uiString(R.string.nutrition_nutrient_fat),
            value = totals.fatG,
            tint = Palette.metricAmber,
            values = values,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun NutritionMacroSummaryColumn(
    totals: NutritionDailyTotals,
    modifier: Modifier = Modifier,
) {
    val values = listOf(totals.proteinG, totals.carbsG, totals.fatG)
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(Metrics.space16),
    ) {
        NutritionMacroSummary(
            label = uiString(R.string.nutrition_nutrient_protein),
            value = totals.proteinG,
            tint = Palette.statusPositive,
            values = values,
            modifier = Modifier.fillMaxWidth(),
        )
        NutritionMacroSummary(
            label = uiString(R.string.nutrition_nutrient_carbs),
            value = totals.carbsG,
            tint = Palette.metricCyan,
            values = values,
            modifier = Modifier.fillMaxWidth(),
        )
        NutritionMacroSummary(
            label = uiString(R.string.nutrition_nutrient_fat),
            value = totals.fatG,
            tint = Palette.metricAmber,
            values = values,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun NutritionMacroSummary(
    label: String,
    value: Double?,
    tint: Color,
    values: List<Double?>,
    modifier: Modifier,
) {
    Column(
        modifier = modifier.semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(
            label,
            style = NoopType.caption,
            color = Palette.textTertiary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.heightIn(min = 32.dp),
        )
        Text(
            value?.let {
                stringResource(
                    R.string.appwide_unit_grams_format,
                    formatNutritionNumber(it, 1),
                )
            } ?: "-",
            style = NoopType.headline.copy(fontWeight = FontWeight.SemiBold),
            color = if (value == null) Palette.textTertiary else tint,
            maxLines = 1,
        )
        NutritionMacroDots(
            filledDots = NutritionSummaryContract.relativeMacroDotCount(value, values),
            tint = tint,
        )
    }
}

@Composable
private fun NutritionMacroDots(
    filledDots: Int,
    tint: Color,
) {
    Canvas(
        modifier = Modifier.size(width = 48.dp, height = 30.dp),
    ) {
        val columns = 6
        val rows = 4
        val xStep = size.width / columns
        val yStep = size.height / rows
        val radius = minOf(xStep, yStep) * 0.24f

        for (row in 0 until rows) {
            for (column in 0 until columns) {
                val fillIndex = (rows - 1 - row) * columns + column
                drawCircle(
                    color = if (fillIndex < filledDots) {
                        tint.copy(alpha = 0.86f)
                    } else {
                        Palette.textPrimary.copy(alpha = 0.08f)
                    },
                    radius = radius,
                    center = Offset(
                        x = (column + 0.5f) * xStep,
                        y = (row + 0.5f) * yStep,
                    ),
                )
            }
        }
    }
}

@Composable
private fun NutritionGlucoseSummary(row: LabMarkerRow?) {
    val valueLabel = row?.value?.let {
        val number = formatNutritionNumber(it, 1)
        if (row.unit.isBlank()) number else "$number ${row.unit}"
    } ?: "-"
    val caption = row?.let {
        uiString(
            R.string.nutrition_glucose_recorded_format,
            formatNutritionDayKey(it.day),
        )
    } ?: uiString(R.string.nutrition_glucose_none)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(9.dp)
                .background(
                    if (row == null) {
                        Palette.textTertiary.copy(alpha = 0.35f)
                    } else {
                        Palette.metricCyan
                    },
                    CircleShape,
                ),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(Metrics.space2),
        ) {
            Text(
                uiString(R.string.nutrition_glucose_title),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            Text(caption, style = NoopType.caption, color = Palette.textTertiary)
        }
        Text(
            valueLabel,
            style = NoopType.headline,
            color = if (row?.value == null) Palette.textTertiary else Palette.textPrimary,
            maxLines = 1,
        )
    }
}

private fun formatNutritionDayKey(day: String): String =
    runCatching {
        LocalDate.parse(day).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
    }.getOrDefault(day)

@Composable
private fun NutritionQuickRepeat(
    entries: List<NutritionEntryRow>,
    savingId: String?,
    onRepeat: (NutritionEntryRow) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                uiString(R.string.nutrition_repeat_title),
                style = NoopType.headline,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Overline(uiString(R.string.nutrition_repeat_overline))
        }
        Text(
            uiString(R.string.nutrition_repeat_body),
            style = NoopType.caption,
            color = Palette.textTertiary,
        )
        LazyRow(horizontalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            items(entries, key = { it.id }) { entry ->
                val title = nutritionEntryTitle(entry)
                val repeatLabel = uiString(R.string.nutrition_repeat_action_format, title)
                Column(
                    modifier = Modifier
                        .width(170.dp)
                        .heightIn(min = 96.dp)
                        .background(Palette.surfaceInset, RoundedCornerShape(14.dp))
                        .clickable(
                            enabled = savingId == null,
                            onClickLabel = repeatLabel,
                        ) { onRepeat(entry) }
                        .padding(Metrics.space12),
                    verticalArrangement = Arrangement.spacedBy(Metrics.space8),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Filled.Restaurant,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(19.dp),
                        )
                        Spacer(Modifier.weight(1f))
                        if (savingId == entry.id) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                strokeWidth = 2.dp,
                                color = Palette.accent,
                            )
                        } else {
                            Icon(
                                Icons.Filled.Add,
                                contentDescription = null,
                                tint = Palette.accent,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                    Text(
                        title,
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                        maxLines = 1,
                    )
                    Text(
                        nutritionRepeatDetail(entry),
                        style = NoopType.caption,
                        color = Palette.textSecondary,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

@Composable
private fun NutritionEntryListRow(
    entry: NutritionEntryRow,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val imported = entry.origin == NutritionLogContract.CSV_ORIGIN
    val title = nutritionEntryTitle(entry)
    val editLabel = uiString(R.string.nutrition_entry_edit_hint)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !imported, onClickLabel = editLabel, onClick = onEdit)
            .padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
    ) {
        Icon(
            if (imported) Icons.Filled.Download else Icons.Filled.Restaurant,
            contentDescription = null,
            tint = if (imported) Palette.textSecondary else Palette.accent,
            modifier = Modifier
                .size(34.dp)
                .background(Palette.surfaceInset, CircleShape)
                .padding(8.dp),
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    title,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (imported) {
                    Spacer(Modifier.width(Metrics.space8))
                    Text(
                        uiString(R.string.nutrition_entry_imported_badge),
                        style = NoopType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = Palette.textSecondary,
                        modifier = Modifier
                            .background(Palette.surfaceInset, RoundedCornerShape(50))
                            .padding(horizontal = 7.dp, vertical = 3.dp),
                    )
                }
            }
            Text(
                nutritionEntryDetail(entry),
                style = NoopType.footnote,
                color = Palette.textSecondary,
                maxLines = 2,
            )
        }
        IconButton(onClick = onDelete) {
            Icon(
                Icons.Filled.Delete,
                contentDescription = uiString(R.string.nutrition_entry_delete_format, title),
                tint = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun NutritionBarcodeLookupDialog(
    barcode: String,
    loading: Boolean,
    onBarcodeChange: (String) -> Unit,
    onDismiss: () -> Unit,
    onScan: () -> Unit,
    onLookup: () -> Unit,
) {
    val uriHandler = LocalUriHandler.current
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = {
            Text(
                uiString(R.string.nutrition_barcode_title),
                style = NoopType.title2,
                color = Palette.textPrimary,
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
                OutlinedTextField(
                    value = barcode,
                    onValueChange = { onBarcodeChange(it.take(40)) },
                    label = { Text(uiString(R.string.nutrition_barcode_manual_label)) },
                    singleLine = true,
                    enabled = !loading,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                    colors = nutritionFieldColors(),
                )
                NoopButton(
                    text = uiString(R.string.nutrition_barcode_scan),
                    leadingIcon = Icons.Filled.QrCodeScanner,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = !loading,
                    onClick = onScan,
                )
                TextButton(
                    onClick = {
                        uriHandler.openUri("https://world.openfoodfacts.org")
                    },
                ) {
                    Text(
                        uiString(R.string.nutrition_barcode_attribution),
                        style = NoopType.headline,
                        color = Palette.accent,
                    )
                }
                Text(
                    uiString(R.string.nutrition_barcode_verify),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = onLookup,
                enabled = !loading &&
                    NutritionCatalogContract.normalizedBarcode(barcode) != null,
            ) {
                if (loading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = Palette.accent,
                    )
                    Spacer(Modifier.width(Metrics.space8))
                }
                Text(
                    if (loading) {
                        uiString(R.string.nutrition_barcode_looking_up)
                    } else {
                        uiString(R.string.nutrition_barcode_lookup)
                    },
                    color = Palette.accent,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !loading) {
                Text(uiString(R.string.nutrition_cancel), color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun NutritionLibraryDialog(
    items: List<NutritionCatalogItemRow>,
    loading: Boolean,
    deletingId: String?,
    onDismiss: () -> Unit,
    onSelect: (NutritionCatalogItemRow) -> Unit,
    onDelete: (NutritionCatalogItemRow) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = {
            Text(
                uiString(R.string.nutrition_library_title),
                style = NoopType.title2,
                color = Palette.textPrimary,
            )
        },
        text = {
            Column(
                modifier = Modifier
                    .heightIn(max = 520.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                when {
                    loading -> {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = Metrics.space24),
                            horizontalArrangement = Arrangement.Center,
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(24.dp),
                                strokeWidth = 2.dp,
                                color = Palette.accent,
                            )
                        }
                    }
                    items.isEmpty() -> {
                        Text(
                            uiString(R.string.nutrition_library_empty_title),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        Text(
                            uiString(R.string.nutrition_library_empty_body),
                            style = NoopType.body,
                            color = Palette.textSecondary,
                            modifier = Modifier.padding(top = Metrics.space8),
                        )
                    }
                    else -> items.forEachIndexed { index, item ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable(
                                    enabled = deletingId == null,
                                    onClickLabel = uiString(R.string.nutrition_library_log_hint),
                                ) { onSelect(item) }
                                .padding(vertical = Metrics.space8),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                        ) {
                            Icon(
                                Icons.Filled.Restaurant,
                                contentDescription = null,
                                tint = Palette.accent,
                                modifier = Modifier
                                    .size(34.dp)
                                    .background(Palette.surfaceInset, CircleShape)
                                    .padding(8.dp),
                            )
                            Column(
                                modifier = Modifier.weight(1f),
                                verticalArrangement = Arrangement.spacedBy(Metrics.space2),
                            ) {
                                Text(
                                    item.name,
                                    style = NoopType.headline,
                                    color = Palette.textPrimary,
                                    maxLines = 1,
                                )
                                Text(
                                    nutritionCatalogDetail(item),
                                    style = NoopType.footnote,
                                    color = Palette.textSecondary,
                                    maxLines = 1,
                                )
                            }
                            IconButton(
                                onClick = { onDelete(item) },
                                enabled = deletingId == null,
                            ) {
                                if (deletingId == item.id) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(18.dp),
                                        strokeWidth = 2.dp,
                                        color = Palette.accent,
                                    )
                                } else {
                                    Icon(
                                        Icons.Filled.Delete,
                                        contentDescription = uiString(
                                            R.string.nutrition_library_delete_format,
                                            item.name,
                                        ),
                                        tint = Palette.textTertiary,
                                    )
                                }
                            }
                        }
                        if (index < items.lastIndex) {
                            HorizontalDivider(color = Palette.hairline)
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.nutrition_cancel), color = Palette.accent)
            }
        },
    )
}

@Composable
private fun nutritionCatalogDetail(item: NutritionCatalogItemRow): String {
    val pieces = mutableListOf<String>()
    item.brand?.takeIf(String::isNotBlank)?.let(pieces::add)
    item.caloriesKcal?.let {
        pieces += uiString(
            R.string.nutrition_library_calories_format,
            formatNutritionNumber(it, 0),
        )
    }
    if (item.servingQuantity != null && item.servingUnit != null) {
        pieces += uiString(
            R.string.nutrition_library_serving_format,
            formatNutritionNumber(item.servingQuantity, 2),
            item.servingUnit,
        )
    }
    return pieces.takeIf { it.isNotEmpty() }?.joinToString(" · ")
        ?: uiString(R.string.nutrition_library_saved_item)
}

@Composable
private fun NutritionEntryDialog(
    entry: NutritionEntryRow?,
    day: LocalDate,
    catalogItem: NutritionCatalogItemRow?,
    saving: Boolean,
    onDismiss: () -> Unit,
    onSave: (NutritionEntryRow, NutritionCatalogItemRow?) -> Unit,
) {
    val context = LocalContext.current
    var meal by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf(NutritionMeal.fromStorage(entry?.mealType ?: catalogItem?.mealType))
    }
    var time by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf(
            entry?.let {
                Instant.ofEpochSecond(it.occurredAt).atZone(ZoneId.systemDefault()).toLocalTime()
            } ?: LocalTime.now().withSecond(0).withNano(0)
        )
    }
    var label by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf(entry?.label ?: catalogItem?.name.orEmpty())
    }
    var calories by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf(nutritionFieldText(entry?.caloriesKcal ?: catalogItem?.caloriesKcal))
    }
    var protein by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf(nutritionFieldText(entry?.proteinG ?: catalogItem?.proteinG))
    }
    var carbs by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf(nutritionFieldText(entry?.carbsG ?: catalogItem?.carbsG))
    }
    var fat by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf(nutritionFieldText(entry?.fatG ?: catalogItem?.fatG))
    }
    var note by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf(entry?.note.orEmpty())
    }
    var saveToLibrary by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf(false)
    }
    var validationMessage by remember(entry?.id, catalogItem?.id, day) {
        mutableStateOf<String?>(null)
    }
    val caloriesLabel = uiString(R.string.nutrition_nutrient_calories)
    val proteinLabel = uiString(R.string.nutrition_nutrient_protein)
    val carbsLabel = uiString(R.string.nutrition_nutrient_carbs)
    val fatLabel = uiString(R.string.nutrition_nutrient_fat)
    val invalidNumberFormat = uiString(R.string.nutrition_editor_invalid_number_format)

    fun buildRow(): NutritionEntryRow? {
        val parsedCalories = parseNutritionField(calories, caloriesLabel, invalidNumberFormat)
        val parsedProtein = parseNutritionField(protein, proteinLabel, invalidNumberFormat)
        val parsedCarbs = parseNutritionField(carbs, carbsLabel, invalidNumberFormat)
        val parsedFat = parseNutritionField(fat, fatLabel, invalidNumberFormat)
        val firstError = listOf(parsedCalories, parsedProtein, parsedCarbs, parsedFat)
            .firstOrNull { it.error != null }?.error
        if (firstError != null) {
            validationMessage = firstError
            return null
        }
        val now = System.currentTimeMillis() / 1_000L
        val row = NutritionEntryRow(
            id = entry?.id ?: UUID.randomUUID().toString(),
            origin = NutritionLogContract.MANUAL_ORIGIN,
            day = day.toString(),
            occurredAt = day.atTime(time).atZone(ZoneId.systemDefault()).toEpochSecond(),
            mealType = meal.storage,
            label = label,
            caloriesKcal = parsedCalories.value,
            proteinG = parsedProtein.value,
            carbsG = parsedCarbs.value,
            fatG = parsedFat.value,
            note = note,
            createdAt = entry?.createdAt ?: now,
            updatedAt = maxOf(now, entry?.createdAt ?: now),
        )
        return runCatching { NutritionLogContract.validated(row) }
            .onFailure { validationMessage = it.userFacingNutritionMessage(context) }
            .getOrNull()
    }

    fun buildCatalogItem(row: NutritionEntryRow): NutritionCatalogItemRow? {
        if (entry != null || !saveToLibrary) return null
        val now = System.currentTimeMillis() / 1_000L
        val candidate = catalogItem?.copy(
            name = row.label ?: catalogItem.name,
            caloriesKcal = row.caloriesKcal,
            proteinG = row.proteinG,
            carbsG = row.carbsG,
            fatG = row.fatG,
            mealType = row.mealType,
            isSaved = true,
            lastUsedAt = now,
            updatedAt = maxOf(now, catalogItem.createdAt),
        ) ?: NutritionCatalogItemRow(
            id = "meal:${UUID.randomUUID()}",
            kind = NutritionCatalogContract.MEAL_KIND,
            name = row.label.orEmpty(),
            caloriesKcal = row.caloriesKcal,
            proteinG = row.proteinG,
            carbsG = row.carbsG,
            fatG = row.fatG,
            mealType = row.mealType,
            source = NutritionCatalogContract.MANUAL_SOURCE,
            isSaved = true,
            lastUsedAt = now,
            createdAt = now,
            updatedAt = now,
        )
        return runCatching { NutritionCatalogContract.validated(candidate) }
            .onFailure { validationMessage = it.userFacingNutritionMessage(context) }
            .getOrNull()
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = {
            Text(
                if (entry == null) {
                    uiString(R.string.nutrition_editor_add)
                } else {
                    uiString(R.string.nutrition_editor_edit)
                },
                style = NoopType.title2,
                color = Palette.textPrimary,
            )
        },
        text = {
            Column(
                modifier = Modifier
                    .heightIn(max = 520.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Metrics.space12),
            ) {
                Text(
                    uiString(R.string.nutrition_editor_meal),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                ) {
                    NutritionMeal.entries.forEach { option ->
                        FilterChip(
                            selected = meal == option,
                            onClick = { meal = option },
                            label = { Text(uiString(option.labelRes)) },
                        )
                    }
                }
                OutlinedTextField(
                    value = label,
                    onValueChange = { label = it.take(NutritionLogContract.MAX_LABEL_CHARACTERS) },
                    label = { Text(uiString(R.string.nutrition_editor_name_optional)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    colors = nutritionFieldColors(),
                )
                NoopButton(
                    text = time.format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)),
                    leadingIcon = Icons.Filled.Edit,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                ) {
                    TimePickerDialog(
                        context,
                        { _, hour, minute -> time = LocalTime.of(hour, minute) },
                        time.hour,
                        time.minute,
                        android.text.format.DateFormat.is24HourFormat(context),
                    ).show()
                }

                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    NutritionNumberField(
                        label = caloriesLabel,
                        unit = "kcal",
                        value = calories,
                        onValueChange = { calories = it },
                        modifier = Modifier.weight(1f),
                    )
                    NutritionNumberField(
                        label = proteinLabel,
                        unit = "g",
                        value = protein,
                        onValueChange = { protein = it },
                        modifier = Modifier.weight(1f),
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    NutritionNumberField(
                        label = carbsLabel,
                        unit = "g",
                        value = carbs,
                        onValueChange = { carbs = it },
                        modifier = Modifier.weight(1f),
                    )
                    NutritionNumberField(
                        label = fatLabel,
                        unit = "g",
                        value = fat,
                        onValueChange = { fat = it },
                        modifier = Modifier.weight(1f),
                    )
                }
                Text(
                    uiString(R.string.nutrition_editor_unknown_body),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it.take(NutritionLogContract.MAX_NOTE_CHARACTERS) },
                    label = { Text(uiString(R.string.nutrition_editor_notes_optional)) },
                    minLines = 2,
                    maxLines = 4,
                    modifier = Modifier.fillMaxWidth(),
                    colors = nutritionFieldColors(),
                )
                if (entry == null && catalogItem?.isSaved != true) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { saveToLibrary = !saveToLibrary },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                    ) {
                        Text(
                            if (catalogItem == null) {
                                uiString(R.string.nutrition_editor_save_library)
                            } else {
                                uiString(R.string.nutrition_editor_save_food_library)
                            },
                            style = NoopType.body,
                            color = Palette.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        NoopToggleSwitch(
                            checked = saveToLibrary,
                            onCheckedChange = { saveToLibrary = it },
                        )
                    }
                }
                validationMessage?.let {
                    Text(it, style = NoopType.footnote, color = Palette.statusWarning)
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    buildRow()?.let { row ->
                        val catalog = buildCatalogItem(row)
                        if (!saveToLibrary || catalog != null) {
                            onSave(row, catalog)
                        }
                    }
                },
                enabled = !saving,
            ) {
                Text(
                    if (saving) {
                        uiString(R.string.nutrition_editor_saving)
                    } else {
                        uiString(R.string.nutrition_editor_save)
                    },
                    color = Palette.accent,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !saving) {
                Text(uiString(R.string.nutrition_cancel), color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun NutritionNumberField(
    label: String,
    unit: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier,
) {
    OutlinedTextField(
        value = value,
        onValueChange = { raw ->
            onValueChange(raw.filter { it.isDigit() || it == '.' || it == ',' }.take(10))
        },
        label = {
            Text(stringResource(R.string.appwide_field_label_unit_format, label, unit))
        },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        modifier = modifier,
        colors = nutritionFieldColors(),
    )
}

@Composable
private fun nutritionFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedLabelColor = Palette.accent,
    unfocusedLabelColor = Palette.textSecondary,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)

private data class ParsedNutritionField(val value: Double?, val error: String?)

private fun parseNutritionField(
    text: String,
    label: String,
    invalidNumberFormat: String,
): ParsedNutritionField {
    val clean = text.trim()
    if (clean.isEmpty()) return ParsedNutritionField(null, null)
    val value = NutritionLogContract.parseUserNumber(clean)
    return if (value == null || !value.isFinite() || value < 0.0) {
        ParsedNutritionField(
            null,
            String.format(Locale.getDefault(), invalidNumberFormat, label),
        )
    } else {
        ParsedNutritionField(value, null)
    }
}

@Composable
private fun nutritionTotalsExplanation(totals: NutritionDailyTotals): String = when {
    totals.hasMixedSources ->
        uiString(R.string.nutrition_totals_mixed)
    totals.hasImportedSummary ->
        uiString(R.string.nutrition_totals_imported)
    totals.hasManualEntries ->
        uiString(R.string.nutrition_totals_manual)
    else -> uiString(R.string.nutrition_totals_empty)
}

@Composable
private fun nutritionRepeatDetail(entry: NutritionEntryRow): String {
    val pieces = mutableListOf<String>()
    entry.caloriesKcal?.let { pieces += "${formatNutritionNumber(it, 0)} kcal" }
    entry.proteinG?.let {
        pieces += "${uiString(R.string.nutrition_nutrient_protein)} ${formatNutritionNumber(it, 1)} g"
    }
    return pieces.takeIf { it.isNotEmpty() }?.joinToString(" · ")
        ?: uiString(NutritionMeal.fromStorage(entry.mealType).labelRes)
}

private fun repeatedNutritionOccurrence(
    day: LocalDate,
    source: NutritionEntryRow,
): Long {
    val zone = ZoneId.systemDefault()
    if (day == LocalDate.now()) return Instant.now().epochSecond
    val sourceTime = Instant.ofEpochSecond(source.occurredAt).atZone(zone).toLocalTime()
    return day.atTime(sourceTime).atZone(zone).toEpochSecond()
}

@Composable
private fun nutritionEntryTitle(entry: NutritionEntryRow): String =
    entry.label?.takeIf { it.isNotBlank() }
        ?: if (entry.mealType == "daily_total") {
            uiString(R.string.nutrition_entry_imported_total)
        } else {
            uiString(NutritionMeal.fromStorage(entry.mealType).labelRes)
        }

@Composable
private fun nutritionEntryDetail(entry: NutritionEntryRow): String {
    val pieces = mutableListOf<String>()
    if (entry.mealType != "daily_total") {
        pieces += Instant.ofEpochSecond(entry.occurredAt)
            .atZone(ZoneId.systemDefault())
            .format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))
    }
    entry.caloriesKcal?.let { pieces += "${formatNutritionNumber(it, 0)} kcal" }
    entry.proteinG?.let {
        pieces += "${uiString(R.string.nutrition_nutrient_protein)} ${formatNutritionNumber(it, 1)} g"
    }
    entry.carbsG?.let {
        pieces += "${uiString(R.string.nutrition_nutrient_carbs)} ${formatNutritionNumber(it, 1)} g"
    }
    entry.fatG?.let {
        pieces += "${uiString(R.string.nutrition_nutrient_fat)} ${formatNutritionNumber(it, 1)} g"
    }
    if (pieces.isEmpty()) {
        pieces += entry.note?.takeIf { it.isNotBlank() }
            ?: uiString(R.string.nutrition_entry_no_values)
    }
    return pieces.joinToString(" · ")
}

private fun nutritionFieldText(value: Double?): String =
    value?.let { formatNutritionNumber(it, 2) }.orEmpty()

private fun formatNutritionNumber(value: Double?, maximumFractionDigits: Int): String =
    value?.let { formatNutritionNumber(it, maximumFractionDigits) } ?: "-"

private fun formatNutritionNumber(value: Double, maximumFractionDigits: Int): String =
    NumberFormat.getNumberInstance().apply {
        minimumFractionDigits = 0
        this.maximumFractionDigits = maximumFractionDigits
        isGroupingUsed = true
    }.format(value)

private fun Throwable.userFacingNutritionMessage(context: Context): String {
    if (this is NutritionBarcodeLookupException) {
        return when (failure) {
            NutritionBarcodeLookupFailure.InvalidBarcode ->
                context.getString(R.string.nutrition_barcode_error_invalid)
            NutritionBarcodeLookupFailure.ProductNotFound ->
                context.getString(R.string.nutrition_barcode_error_not_found)
            NutritionBarcodeLookupFailure.InvalidResponse ->
                context.getString(R.string.nutrition_barcode_error_invalid_response)
            NutritionBarcodeLookupFailure.ServiceBusy ->
                context.getString(R.string.nutrition_barcode_error_rate_limited)
            NutritionBarcodeLookupFailure.RequestFailed ->
                context.getString(R.string.nutrition_barcode_error_network)
        }
    }
    val raw = message.orEmpty()
    return when {
        raw.contains("empty nutrition entry", ignoreCase = true) ->
            context.getString(R.string.nutrition_error_empty)
        raw.contains("invalid nutrition nutrient", ignoreCase = true) ||
            raw.contains("invalid nutrition catalog nutrient", ignoreCase = true) ->
            context.getString(R.string.nutrition_error_range)
        raw.contains("nutrition catalog name is required", ignoreCase = true) ->
            context.getString(R.string.nutrition_error_empty)
        raw.isNotBlank() -> raw
        else -> context.getString(R.string.nutrition_error_generic)
    }
}
