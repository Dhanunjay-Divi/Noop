package com.noop.ingest

import com.noop.data.DailyMetric
import com.noop.data.DailyHrvMethod
import com.noop.data.JournalEntry
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ui.AutoWorkoutPrefs
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.zip.ZipInputStream

/**
 * The round-trip contract, Android side: serialize with WhoopCsvExporter, re-parse the bytes with
 * the REAL CsvTable parser (the same one WhoopCsvImporter feeds), and assert the normalized columns
 * the importer reads carry the original values back. This proves the exported zip is re-importable
 * by NOOP itself; the macOS suite mirrors it through the full WhoopExportImporter parse functions.
 *
 * Stage/zone fidelity is checked through the exporter's own tolerant decoders, which the importer's
 * persisted JSON shapes also feed — so a decode here is the same decode the dashboards rely on.
 */
class WhoopCsvExporterTest {

    @Test
    fun dailyExportSelectsWholeRowsWithoutPromotingComputedFieldsToImport() {
        val computedActive = DailyMetric(
            deviceId = "active-noop",
            day = "2026-06-02",
            totalSleepMin = 420.0,
            recovery = 61.0,
        )
        val computedCanonical = DailyMetric(
            deviceId = "my-whoop-noop",
            day = "2026-06-02",
            efficiency = 0.88,
            avgHrv = 55.0,
        )
        val importedActive = DailyMetric(
            deviceId = "active",
            day = "2026-06-02",
            recovery = 79.0,
        )
        val importedCanonical = DailyMetric(
            deviceId = "my-whoop",
            day = "2026-06-02",
            totalSleepMin = 390.0,
            restingHr = 52,
        )
        val computedOnly = DailyMetric(
            deviceId = "active-noop",
            day = "2026-06-01",
            totalSleepMin = 400.0,
        )

        val selected = WhoopCsvExporter.selectDailyRowsForExport(
            importedBySource = listOf(listOf(importedActive), listOf(importedCanonical)),
            computedBySource = listOf(
                listOf(computedActive, computedOnly),
                listOf(computedCanonical),
            ),
        )

        assertEquals(listOf("2026-06-01", "2026-06-02"), selected.map { it.metric.day })
        assertEquals("noop (APPROXIMATE)", selected[0].source)
        assertEquals(computedOnly, selected[0].metric)
        assertEquals("import", selected[1].source)
        assertEquals(importedActive, selected[1].metric)
        assertNull(selected[1].metric.totalSleepMin)
        assertNull(selected[1].metric.efficiency)
        assertNull(selected[1].metric.avgHrv)
    }

    @Test
    fun cyclesRoundTripThroughRealParser() {
        val daily = listOf(
            DailyMetric(
                deviceId = "my-whoop", day = "2026-06-01", totalSleepMin = 420.0, efficiency = 0.923,
                deepMin = 95.0, remMin = 115.0, lightMin = 210.0, disturbances = 35, restingHr = 52,
                avgHrv = 68.4, recovery = 72.0, strain = 12.5, exerciseCount = null,
                spo2Pct = 96.0, skinTempDevC = 33.1, respRateBpm = 14.2,
                hrvMethod = DailyHrvMethod.SDNN,
            ),
        )
        val series = mapOf(
            "2026-06-01" to mapOf(
                "sleep_performance" to 85.0, "sleep_consistency" to 88.0,
                "sleep_need_min" to 480.0, "sleep_debt_min" to 60.0,
            ),
        )
        val csv = WhoopCsvExporter.cyclesCsv(daily, series, mapOf("2026-06-01" to "import"))
        val table = CsvTable.fromData(csv.toByteArray())
        assertEquals(1, table.rows.size)
        val row = table.rows[0]
        // The normalized keys the importer's parseCycles reads must carry the values back.
        assertEquals("72", row["recovery_score_pct"])
        assertEquals("52", row["resting_heart_rate_bpm"])
        assertEquals("68.4", row["heart_rate_variability_ms"])
        assertEquals("SDNN", row["hrv_method"])
        assertEquals("33.1", row["skin_temp_celsius"])
        assertEquals("96", row["blood_oxygen_pct"])
        // CSV is WHOOP 0–21 scale: 12.5 Effort × 21/100 = 2.625 (re-import scales back up).
        assertEquals("2.625", row["day_strain"])
        assertEquals("14.2", row["respiratory_rate_rpm"])
        assertEquals("420", row["asleep_duration_min"])
        assertEquals("210", row["light_sleep_duration_min"])
        assertEquals("95", row["deep_sws_duration_min"])
        assertEquals("115", row["rem_duration_min"])
        // Awake duration is MINUTES and the Android daily row doesn't carry it — the cell must be
        // EMPTY, not the disturbance count (a wrong unit that round-tripped on reimport; PR #97
        // review, tigercraft4).
        assertEquals("", row["awake_duration_min"].orEmpty())
        assertEquals("92.3", row["sleep_efficiency_pct"])
        // Source column is present but ignored on import.
        assertEquals("import", row["source"])
        // The complete cycle projection re-parses, including these four figures and canonical
        // fractional efficiency.
        val s = WhoopCsvImporter.parseCycleSeries(table, "my-whoop").associate { it.key to it.value }
        assertEquals(85.0, s.getValue("sleep_performance"), 1e-9)
        assertEquals(88.0, s.getValue("sleep_consistency"), 1e-9)
        assertEquals(480.0, s.getValue("sleep_need_min"), 1e-9)
        assertEquals(60.0, s.getValue("sleep_debt_min"), 1e-9)
        assertEquals(0.923, s.getValue("sleep_efficiency"), 1e-9)
        val imported = WhoopCsvImporter.parseCycles(table, "my-whoop").single()
        assertEquals(DailyHrvMethod.SDNN, imported.hrvMethod)
    }

    @Test
    fun cyclesWithholdDetailedLocalStagesButKeepSleepTotal() {
        val daily = DailyMetric(
            deviceId = "my-whoop-noop",
            day = "2026-06-01",
            totalSleepMin = 420.0,
            efficiency = 0.9,
            deepMin = 95.0,
            remMin = 115.0,
            lightMin = 210.0,
        )
        val table = CsvTable.fromData(
            WhoopCsvExporter.cyclesCsv(
                daily = listOf(daily),
                seriesByDay = emptyMap(),
                sourceByDay = mapOf(daily.day to "noop (APPROXIMATE)"),
                publishDetailedSleepStages = { false },
            ).toByteArray(),
        )
        val row = table.rows.single()

        assertEquals("420", row["asleep_duration_min"])
        assertEquals("", row["light_sleep_duration_min"].orEmpty())
        assertEquals("", row["deep_sws_duration_min"].orEmpty())
        assertEquals("", row["rem_duration_min"].orEmpty())
        assertEquals("", row["awake_duration_min"].orEmpty())
        assertEquals("noop (APPROXIMATE)", row["source"])
    }

    @Test
    fun workoutSportWithCommaQuoteNewlineSurvives() {
        val w = WorkoutRow(
            deviceId = "my-whoop", startTs = 1_750_000_000L, endTs = 1_750_003_600L,
            sport = "Run, \"tempo\"\nintervals", source = "my-whoop", durationS = 3600.0,
            energyKcal = 540.0, avgHr = 158, maxHr = 182, strain = 11.2, distanceM = 8000.0,
            zonesJSON = """{"zone1":10.0,"zone2":20.0,"zone3":40.0,"zone4":20.0,"zone5":10.0}""",
            notes = null,
        )
        val table = CsvTable.fromData(WhoopCsvExporter.workoutsCsv(listOf(w)).toByteArray())
        assertEquals(1, table.rows.size)
        val row = table.rows[0]
        // The quoted activity name with comma/quote/newline must survive RFC-4180 round-trip.
        assertEquals("Run, \"tempo\"\nintervals", row["activity_name"])
        // CSV is WHOOP 0–21 scale: 11.2 Effort × 21/100 = 2.352.
        assertEquals("2.352", row["activity_strain"])
        assertEquals("540", row["energy_burned_cal"])
        assertEquals("158", row["average_hr_bpm"])
        assertEquals("182", row["max_hr_bpm"])
        assertEquals("40", row["hr_zone_3_pct"])
        assertEquals("8000", row["distance_meters"])
        // Timestamps re-parse to the same epoch (UTC encoding).
        assertEquals(1_750_000_000L, WhoopTime.parseEpochSeconds(row.cell("workout_start_time"), 0))
        assertEquals(1_750_003_600L, WhoopTime.parseEpochSeconds(row.cell("workout_end_time"), 0))
    }

    @Test
    fun sleepsRoundTripBothStageShapes() {
        // Android-import shape [{stage,min}] — minutes survive exactly.
        val imported = SleepSession(
            deviceId = "my-whoop", startTs = 1_750_000_000L, endTs = 1_750_030_000L,
            efficiency = 0.91, restingHr = null, avgHrv = null,
            stagesJSON = """[{"stage":"light","min":210.0},{"stage":"deep","min":95.0},""" +
                """{"stage":"rem","min":115.0},{"stage":"awake","min":35.0}]""",
        )
        // On-device stager shape [{start,end,stage}] — minutes derived from the spans.
        val computed = SleepSession(
            deviceId = "my-whoop-noop", startTs = 2_000_000_000L, endTs = 2_000_007_200L,
            efficiency = null, restingHr = null, avgHrv = null,
            stagesJSON = """[{"start":2000000000,"end":2000003600,"stage":"light"},""" +
                """{"start":2000003600,"end":2000007200,"stage":"deep"}]""",
        )
        val table = CsvTable.fromData(
            WhoopCsvExporter.sleepsCsv(
                listOf(imported, computed),
                cycleStart = { com.noop.analytics.AnalyticsEngine.dayString(it.endTs, 0L) + " 00:00:00" },
            ).toByteArray(),
        )
        val byStart = table.rows.sortedBy { it["sleep_onset"] }
        assertEquals(2, byStart.size)
        // First night: explicit per-stage minutes.
        assertEquals("210", byStart[0]["light_sleep_duration_min"])
        assertEquals("95", byStart[0]["deep_sws_duration_min"])
        assertEquals("115", byStart[0]["rem_duration_min"])
        assertEquals("35", byStart[0]["awake_duration_min"])
        assertEquals("420", byStart[0]["asleep_duration_min"])  // 210+95+115
        assertEquals("false", byStart[0]["nap"])
        // Second night: stager spans → 60 + 60 minutes.
        assertEquals("60", byStart[1]["light_sleep_duration_min"])
        assertEquals("60", byStart[1]["deep_sws_duration_min"])
        assertEquals(2_000_007_200L, WhoopTime.parseEpochSeconds(byStart[1].cell("wake_onset"), 0))
    }

    @Test
    fun sleepsWithholdDetailedLocalStagesWithoutMutatingRawSession() {
        val rawStages = """[{"start":2000000000,"end":2000003600,"stage":"light"},""" +
            """{"start":2000003600,"end":2000007200,"stage":"deep"}]"""
        val local = SleepSession(
            deviceId = "my-whoop-noop",
            startTs = 2_000_000_000L,
            endTs = 2_000_007_200L,
            efficiency = 0.9,
            stagesJSON = rawStages,
        )
        val table = CsvTable.fromData(
            WhoopCsvExporter.sleepsCsv(
                sessions = listOf(local),
                cycleStart = { "2033-05-18 00:00:00" },
                publishDetailedStages = { false },
                sourceBySession = { "noop (APPROXIMATE)" },
            ).toByteArray(),
        )
        val row = table.rows.single()

        assertEquals("120", row["in_bed_duration_min"])
        assertEquals("", row["asleep_duration_min"].orEmpty())
        assertEquals("", row["light_sleep_duration_min"].orEmpty())
        assertEquals("", row["deep_sws_duration_min"].orEmpty())
        assertEquals("", row["rem_duration_min"].orEmpty())
        assertEquals("", row["awake_duration_min"].orEmpty())
        assertEquals("noop (APPROXIMATE)", row["source"])
        assertEquals(rawStages, local.stagesJSON)
    }

    @Test
    fun sleepsAttributeCrossMidnightFragmentsToFinalWakeCycle() {
        val midnight = 1_767_312_000L
        val first = SleepSession(
            deviceId = "my-whoop-noop",
            startTs = midnight - 4 * 3_600,
            endTs = midnight - 300,
        )
        val second = SleepSession(
            deviceId = "my-whoop-noop",
            startTs = midnight + 300,
            endTs = midnight + 4 * 3_600,
        )
        val sessions = listOf(first, second)
        val wakeDays = WhoopRepository.wakeDayBySession(sessions) { 0L }

        val table = CsvTable.fromData(
            WhoopCsvExporter.sleepsCsv(
                sessions = sessions,
                cycleStart = {
                    wakeDays.getValue(it.deviceId to it.startTs) + " 00:00:00"
                },
            ).toByteArray(),
        )

        assertEquals(2, table.rows.size)
        assertEquals(
            setOf("2026-01-02 00:00:00"),
            table.rows.map { it["cycle_start_time"] }.toSet(),
        )
    }

    @Test
    fun journalRoundTripIncludingFalseAnswersAndCommaNotes() {
        val rows = listOf(
            JournalEntry(deviceId = "my-whoop", day = "2026-06-01",
                question = "Any alcohol?", answeredYes = false, notes = null),
            JournalEntry(deviceId = "my-whoop", day = "2026-06-01",
                question = "Caffeine, after 4pm?", answeredYes = true, notes = "one, big \"mug\""),
        )
        val table = CsvTable.fromData(WhoopCsvExporter.journalCsv(rows).toByteArray())
        val byQuestion = table.rows.sortedBy { it["question_text"] }
        assertEquals(2, byQuestion.size)
        assertEquals("Any alcohol?", byQuestion[0]["question_text"])
        // The importer reads "true"/"false" via parseYesNo — the literal must be exact.
        assertEquals("false", byQuestion[0]["answered_yes_no"])
        assertEquals("2026-06-01 00:00:00", byQuestion[0]["cycle_start_time"])
        assertEquals("Caffeine, after 4pm?", byQuestion[1]["question_text"])
        assertEquals("true", byQuestion[1]["answered_yes_no"])
        assertEquals("one, big \"mug\"", byQuestion[1]["notes"])
    }

    @Test
    fun stageMinutesDecodesAllPersistedShapes() {
        // Dict shape (macOS import).
        val dict = WhoopCsvExporter.stageMinutes("""{"light":210,"deep":95,"rem":115,"awake":35}""")
        assertEquals(210.0, dict.light!!, 1e-9)
        assertEquals(420.0, dict.asleep!!, 1e-9)
        // Segment shape with "wake" alias → awake.
        val seg = WhoopCsvExporter.stageMinutes(
            """[{"start":0,"end":3600,"stage":"light"},{"start":3600,"end":5400,"stage":"wake"}]""",
        )
        assertEquals(60.0, seg.light!!, 1e-9)
        assertEquals(30.0, seg.awake!!, 1e-9)
        // Junk → all-null so the column exports blank.
        val none = WhoopCsvExporter.stageMinutes("not json")
        assertNull(none.light)
        assertNull(none.asleep)
    }

    @Test
    fun zonePercentsDecodesBothKeyShapes() {
        assertEquals(
            listOf(5.0, 20.0, 40.0, 30.0, 5.0),
            WhoopCsvExporter.zonePercents("""{"z1":5,"z2":20,"z3":40,"z4":30,"z5":5}"""),
        )
        assertEquals(
            listOf(10.0, 20.0, 40.0, 20.0, 10.0),
            WhoopCsvExporter.zonePercents("""{"zone1":10,"zone2":20,"zone3":40,"zone4":20,"zone5":10}"""),
        )
        assertNull(WhoopCsvExporter.zonePercents(null))
        assertNull(WhoopCsvExporter.zonePercents("""{"z1":0,"z2":0,"z3":0,"z4":0,"z5":0}"""))
    }

    @Test
    fun utcTimestampParsesBackToSameEpoch() {
        val ts = 1_751_234_567L
        assertEquals(ts, WhoopTime.parseEpochSeconds(WhoopCsvExporter.utc(ts), 0))
    }

    @Test
    fun numbersAreLocaleProof() {
        assertEquals("72", WhoopCsvExporter.num(72.0))
        assertEquals("68.4", WhoopCsvExporter.num(68.4))
        assertEquals("", WhoopCsvExporter.num(null as Double?))
        assertTrue(!WhoopCsvExporter.num(12345.678).contains(","))
    }

    @Test
    fun metricSeriesJsonIsSortedAndComplete() {
        val json = WhoopCsvExporter.metricSeriesJson(
            listOf(
                MetricSeriesRow("my-whoop-noop", "2026-06-02", "recovery", 60.0),
                MetricSeriesRow("my-whoop-noop", "2026-06-02", "sleep_deep_min", 95.0),
                MetricSeriesRow("my-whoop-noop", "2026-06-02", "rest_evidence_flags", 3.0),
                MetricSeriesRow("my-whoop", "2026-06-01", "strain", 12.5),
            ),
        )
        // Sorted by (deviceId, day, key): "my-whoop" sorts before "my-whoop-noop".
        assertTrue(json.indexOf("\"my-whoop\"") < json.indexOf("\"my-whoop-noop\""))
        assertTrue(json.contains("\"strain\""))
        assertTrue(json.contains("\"recovery\""))
        assertTrue(json.contains("\"sleep_deep_min\""))
        assertTrue(json.contains("\"rest_evidence_flags\""))
    }

    @Test
    fun comparisonSidecarsAreSourceSeparatedAndIdentifierFree() {
        val importedDay = DailyMetric(
            deviceId = "provider-device-secret",
            day = "2026-06-01",
            totalSleepMin = 420.0,
            efficiency = 0.92,
            deepMin = 95.0,
            remMin = 115.0,
            lightMin = 210.0,
            disturbances = 5,
            restingHr = 52,
            avgHrv = 68.4,
            recovery = 72.0,
            strain = 45.0,
            exerciseCount = 1,
            spo2Pct = 96.0,
            skinTempDevC = 33.1,
            respRateBpm = 14.2,
            steps = 6_000,
            activeKcalEst = 350.0,
            hrvMethod = DailyHrvMethod.SDNN,
        )
        val computedDay = DailyMetric(
            deviceId = "noop-device-secret",
            day = "2026-06-01",
            totalSleepMin = 400.0,
            efficiency = 0.9,
            deepMin = 80.0,
            remMin = 100.0,
            lightMin = 220.0,
            disturbances = 3,
            restingHr = 55,
            avgHrv = 42.0,
            recovery = 61.0,
            strain = 42.0,
            exerciseCount = 1,
            skinTempDevC = 0.2,
            respRateBpm = 15.2,
            steps = 5_000,
            activeKcalEst = 300.0,
            spo2Red = 10,
            spo2Ir = 20,
            hrvMethod = DailyHrvMethod.RMSSD,
        )
        val sleep = SleepSession(
            deviceId = "noop-device-secret",
            startTs = 0,
            endTs = 3_600,
            efficiency = 0.8,
            restingHr = 54,
            avgHrv = 50.0,
            stagesJSON = """{"light":30,"deep":10,"rem":8,"awake":12}""",
            userEdited = true,
            rrEligibleWindowCount = 10,
            rrValidWindowCount = 8,
        )
        val workout = WorkoutRow(
            deviceId = "noop-device-secret",
            startTs = 0,
            endTs = 1_800,
            sport = "=private formula",
            source = "noop-device-secret",
            durationS = 1_800.0,
            energyKcal = 220.0,
            avgHr = 145,
            maxHr = 172,
            strain = 37.5,
            distanceM = 5_000.0,
            zonesJSON = """{"z1":5,"z2":15,"z3":40,"z4":30,"z5":10}""",
            notes = "private note",
            routePolyline = "private route",
            steps = 4_200,
        )
        val entries = WhoopCsvExporter.comparisonEntries(
            context = WhoopCsvExporter.ComparisonContext(
                generatedAtUtc = "2026-08-28T12:00:00Z",
                platform = "Android",
                appVersion = "9.2.0",
            ),
            daily = listOf(
                WhoopCsvExporter.ComparisonDailyRow(
                    WhoopCsvExporter.ComparisonSource.WEARABLE_IMPORT,
                    importedDay,
                    true,
                ),
                WhoopCsvExporter.ComparisonDailyRow(
                    WhoopCsvExporter.ComparisonSource.NOOP_COMPUTED,
                    computedDay,
                    false,
                ),
            ),
            sleeps = listOf(
                WhoopCsvExporter.ComparisonSleepRow(
                    WhoopCsvExporter.ComparisonSource.NOOP_COMPUTED,
                    sleep,
                    true,
                ),
            ),
            workouts = listOf(
                WhoopCsvExporter.ComparisonWorkoutRow(
                    WhoopCsvExporter.ComparisonSource.NOOP_COMPUTED,
                    workout,
                ),
            ),
            metricSeries = listOf(
                WhoopCsvExporter.ComparisonMetricRow(
                    WhoopCsvExporter.ComparisonSource.WEARABLE_IMPORT,
                    "2026-06-01",
                    "recovery",
                    72.0,
                ),
                WhoopCsvExporter.ComparisonMetricRow(
                    WhoopCsvExporter.ComparisonSource.NOOP_COMPUTED,
                    "2026-06-01",
                    "skin_temp",
                    0.2,
                ),
            ),
            detectorDecisions = listOf(
                AutoWorkoutPrefs.DecisionRecord(
                    candidateStartSec = 60,
                    candidateEndSec = 1_860,
                    recordedAtSec = 2_000,
                    action = AutoWorkoutPrefs.DecisionAction.ACCEPTED,
                    actor = AutoWorkoutPrefs.DecisionActor.USER,
                    activityName = "Running",
                    detectorVersion = com.noop.analytics.AutoWorkoutDetector.detectorVersion,
                    averageBpm = 145,
                    peakBpm = 172,
                    eventConfidence = null,
                    confidenceStatus = "uncalibrated",
                    evidenceProvenance = "heart_rate_and_motion",
                    suggestedClass = "run",
                    suggestionConfidence = 0.8,
                    origin = "recorded_event",
                ),
                AutoWorkoutPrefs.DecisionRecord(
                    candidateStartSec = 3_000,
                    candidateEndSec = null,
                    recordedAtSec = null,
                    action = AutoWorkoutPrefs.DecisionAction.DISMISSED,
                    actor = AutoWorkoutPrefs.DecisionActor.USER,
                    activityName = null,
                    detectorVersion = null,
                    averageBpm = null,
                    peakBpm = null,
                    eventConfidence = null,
                    confidenceStatus = null,
                    evidenceProvenance = null,
                    suggestedClass = null,
                    suggestionConfidence = null,
                    origin = "legacy_dismissal_tombstone",
                ),
            ),
        )

        val dailyHeader =
            "source,day,recovery_score_0_100,effort_score_0_100,total_sleep_min," +
                "sleep_efficiency_fraction,light_sleep_min,deep_sleep_min,rem_sleep_min," +
                "disturbances_count,resting_hr_bpm,hrv_ms,hrv_method,spo2_pct," +
                "skin_temperature_value_c,skin_temperature_semantics,respiratory_rate_per_min," +
                "steps_count,energy_kcal,raw_spo2_red_adc,raw_spo2_ir_adc," +
                "detailed_sleep_stages_status\r\n"
        assertEquals(
            dailyHeader +
                "noop_computed,2026-06-01,61,42,400,0.9,,,,3,55,42,RMSSD,,0.2," +
                "deviation_from_personal_baseline,15.2,5000,300,10,20," +
                "withheld_insufficient_evidence\r\n" +
                "wearable_import,2026-06-01,72,45,420,0.92,210,95,115,5,52,68.4,SDNN," +
                "96,33.1,absolute_temperature,14.2,6000,350,,,available\r\n",
            entries.getValue("comparison/daily_metrics.csv").decodeToString(),
        )
        assertEquals(
            "source,day,metric_key,value,unit\r\n" +
                "noop_computed,2026-06-01,skin_temp,0.2,celsius_delta_from_baseline\r\n" +
                "wearable_import,2026-06-01,recovery,72,score_0_100\r\n",
            entries.getValue("comparison/metric_series.csv").decodeToString(),
        )

        val workoutCsv = entries.getValue("comparison/workouts.csv").decodeToString()
        assertTrue(workoutCsv.contains("noop_computed,1970-01-01T00:00:00Z"))
        assertTrue(workoutCsv.contains("'=private formula"))
        assertFalse(workoutCsv.contains("private note"))
        assertFalse(workoutCsv.contains("private route"))

        val decisionsCsv = entries.getValue("comparison/detector_decisions.csv").decodeToString()
        assertTrue(
            decisionsCsv.contains(
                "accepted,user,Running," +
                    "${com.noop.analytics.AutoWorkoutDetector.detectorVersion},145,172,,run,0.8," +
                    "uncalibrated,heart_rate_and_motion,recorded_event",
            ),
        )
        assertTrue(
            decisionsCsv.contains(
                "1970-01-01T00:50:00Z,,,dismissed,user,,,,,,,,,,legacy_dismissal_tombstone",
            ),
        )

        val manifest = JSONObject(entries.getValue("comparison/manifest.json").decodeToString())
        assertEquals("noop.parallel_wear.v1", manifest.getString("schema"))
        assertFalse(manifest.getBoolean("contains_device_identifiers"))
        assertEquals(
            "noop.detector_decisions.v1",
            manifest.getString("detector_decisions_schema"),
        )
        assertEquals(
            com.noop.analytics.AutoWorkoutDetector.detectorVersion,
            manifest.getJSONObject("algorithm_revisions").getString("auto_workout_detector"),
        )
        val detector = JSONObject(
            entries.getValue("comparison/workout_detector.json").decodeToString(),
        )
        assertEquals("uncalibrated", detector.getString("event_confidence_status"))
        assertFalse(detector.getBoolean("unattended_save_permitted"))
        assertFalse(
            detector.getJSONObject("decision_history")
                .getBoolean("computed_workout_rows_imply_acceptance"),
        )

        for (data in entries.values) {
            val text = data.decodeToString()
            assertFalse(text.contains("device-secret"))
            assertFalse(text.contains("private note"))
            assertFalse(text.contains("private route"))
        }
    }

    @Test
    fun zipBytesReadBackByName() {
        val zip = WhoopCsvExporter.zipBytes(
            linkedMapOf(
                "a.csv" to "x,y\r\n".toByteArray(),
                "noop_metric_series.json" to "[]".toByteArray(),
                "noop_user_data.json" to "{}".toByteArray(),
            ),
        )
        val names = ArrayList<String>()
        ZipInputStream(zip.inputStream()).use { zis ->
            var e = zis.nextEntry
            while (e != null) { names.add(e.name); e = zis.nextEntry }
        }
        assertEquals(listOf("a.csv", "noop_metric_series.json", "noop_user_data.json"), names)
    }
}
