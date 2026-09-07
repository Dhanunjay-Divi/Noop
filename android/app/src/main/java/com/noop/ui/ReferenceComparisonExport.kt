package com.noop.ui

import com.noop.analytics.PairedReferenceDay
import com.noop.analytics.WhoopReferenceComparisonReport
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.math.abs

/** Pure local encoder for a user-confirmed official-reference comparison export. */
object ReferenceComparisonExport {
    enum class Scope {
        SUMMARY_ONLY,
        EXACT_DAILY_PAIRS,
    }

    data class ExportPackage(
        val entries: List<Pair<String, ByteArray>>,
        val suggestedName: String,
    )

    fun makePackage(
        report: WhoopReferenceComparisonReport,
        metricName: String,
        units: String,
        appVersion: String,
        platform: String,
        importerRevision: String,
        scope: Scope,
        timestamp: String = LogExport.timestamp(),
    ): ExportPackage? {
        val statistics = report.statistics ?: return null
        val summary = summaryText(
            report,
            metricName,
            units,
            appVersion,
            platform,
            importerRevision,
            scope,
        )
        val entries = buildList {
            add("summary.txt" to summary.toByteArray())
            if (scope == Scope.EXACT_DAILY_PAIRS) {
                add("daily_pairs.csv" to exactPairsCsv(report.pairs).toByteArray())
            }
        }
        val scopeSlug = if (scope == Scope.SUMMARY_ONLY) "summary" else "exact-daily-pairs"
        return ExportPackage(
            entries = entries,
            suggestedName = listOf(
                "noop-provider-comparison",
                slug(metricName),
                scopeSlug,
                slug(platform),
                "v${slug(appVersion)}",
                timestamp,
            ).joinToString("-") + ".zip",
        )
    }

    private fun summaryText(
        report: WhoopReferenceComparisonReport,
        metricName: String,
        units: String,
        appVersion: String,
        platform: String,
        importerRevision: String,
        scope: Scope,
    ): String {
        val statistics = requireNotNull(report.statistics)
        val exact = scope == Scope.EXACT_DAILY_PAIRS
        val span = inclusiveDayCount(statistics.firstDay, statistics.lastDay)
            ?.let { "$it calendar days" }
            ?: "Unavailable"
        val calibration = buildList {
            add("Decision: ${report.calibration.decision.name.lowercase()}")
            add("Confidence: ${report.calibration.confidence.name.lowercase()}")
            add("Reason: ${report.calibration.reason}")
            report.calibration.validation?.let {
                add(
                    "Chronological validation: ${it.trainingCount} training days + " +
                        "${it.holdoutCount} untouched holdout days",
                )
                add("Holdout MAE improvement: ${number(it.relativeMAEImprovement * 100.0)}%")
            }
        }.joinToString("\n")
        val privacy = if (exact) {
            "daily_pairs.csv includes exact dates and daily official and NOOP values. Treat it as " +
                "sensitive health data. Account details, device identifiers, and raw streams are excluded."
        } else {
            "This summary excludes exact dates, daily values, personal means, raw streams, account " +
                "details, and device identifiers."
        }
        return """
            NOOP provider comparison export

            PRIVACY AND ORIGIN
            Scope: ${if (exact) "Aggregate summary plus exact daily pairs" else "Aggregate summary only"}
            Created locally only after explicit user confirmation.
            NOOP did not upload this export. It is shared only through the system action you choose.
            $privacy

            SOFTWARE
            NOOP version: $appVersion
            Platform: $platform
            Provider import revision: $importerRevision
            NOOP algorithm revision: ${report.noopAlgorithmVersion}

            COMPARISON
            Metric: $metricName
            Scale or units: $units
            Paired days: ${statistics.sampleCount}
            Comparison span: $span
            Error direction: NOOP minus official provider
            Bias: ${number(statistics.bias, signed = true)}
            Mean absolute error (MAE): ${number(statistics.meanAbsoluteError)}
            Root mean squared error (RMSE): ${number(statistics.rootMeanSquaredError)}
            Correlation (Pearson r): ${statistics.correlation?.let(::number) ?: "Unavailable"}

            PERSONAL CALIBRATION
            $calibration

            INTERPRETATION
            These results compare user-imported provider outcomes with separately computed NOOP estimates
            on matched days. They do not recover, reproduce, or claim to know proprietary formulas.
        """.trimIndent() + "\n"
    }

    private fun exactPairsCsv(pairs: List<PairedReferenceDay>): String {
        val rows = pairs.sortedBy { it.day }.map { pair ->
            listOf(
                pair.day,
                number(pair.official.value),
                number(pair.noop.value),
                number(pair.noop.value - pair.official.value, signed = true),
            ).joinToString(",")
        }
        return (
            listOf("day,official_provider_value,noop_value,noop_minus_official") + rows
        ).joinToString("\n") + "\n"
    }

    private fun inclusiveDayCount(firstDay: String, lastDay: String): Long? = runCatching {
        val first = LocalDate.parse(firstDay)
        val last = LocalDate.parse(lastDay)
        ChronoUnit.DAYS.between(first, last).takeIf { it >= 0 }?.plus(1)
    }.getOrNull()

    private fun number(value: Double, signed: Boolean = false): String {
        val normalized = if (abs(value) < 0.0000005) 0.0 else value
        var output = java.lang.String.format(
            Locale.US,
            if (signed) "%+.6f" else "%.6f",
            normalized,
        )
        while (output.endsWith("0")) output = output.dropLast(1)
        if (output.endsWith(".")) output = output.dropLast(1)
        return output
    }

    private fun slug(value: String): String {
        val result = value.lowercase(Locale.US)
            .split(Regex("[^a-z0-9]+"))
            .filter(String::isNotEmpty)
            .joinToString("-")
        return result.ifEmpty { "unknown" }
    }
}
