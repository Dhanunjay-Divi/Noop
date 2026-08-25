import Foundation
import StrandAnalytics

/// Pure encoder for the user-initiated WHOOP-vs-NOOP comparison export.
///
/// This type performs no file IO and no networking. Callers should invoke `makePackage` only after the
/// user confirms the requested privacy scope, then hand the returned entries to `FileExport`.
enum ReferenceComparisonExport {
    enum Scope: String, CaseIterable, Identifiable {
        case summaryOnly
        case exactDailyPairs

        var id: String { rawValue }
    }

    struct Context: Equatable {
        let appVersion: String
        let platform: String
        let whoopImporterRevision: String
    }

    struct ExportPackage: Equatable {
        let entries: [FileExport.BundleEntry]
        let suggestedName: String
    }

    /// Builds an in-memory export package. No bytes are written until `FileExport.exportBundle` receives
    /// the returned entries. The aggregate summary intentionally omits comparison dates, daily values,
    /// and the official/NOOP personal means.
    static func makePackage(
        report: WhoopReferenceComparisonReport,
        metricName: String,
        units: String,
        context: Context,
        scope: Scope,
        date: Date = Date()
    ) -> ExportPackage? {
        guard let statistics = report.statistics else { return nil }

        let summary = summaryText(
            report: report,
            statistics: statistics,
            metricName: metricName,
            units: units,
            context: context,
            scope: scope
        )
        var entries = [
            FileExport.BundleEntry(name: "summary.txt", data: Data(summary.utf8))
        ]

        if scope == .exactDailyPairs {
            entries.append(
                FileExport.BundleEntry(
                    name: "daily_pairs.csv",
                    data: Data(exactPairsCSV(report.pairs).utf8)
                )
            )
        }

        let scopeSlug = scope == .summaryOnly ? "summary" : "exact-daily-pairs"
        let filename = [
            "noop-provider-comparison",
            slug(metricName),
            scopeSlug,
            slug(context.platform),
            "v\(slug(context.appVersion))",
            FileExport.timestamp(date),
        ].joined(separator: "-") + ".zip"
        return ExportPackage(entries: entries, suggestedName: filename)
    }

    private static func summaryText(
        report: WhoopReferenceComparisonReport,
        statistics: ReferenceComparisonStatistics,
        metricName: String,
        units: String,
        context: Context,
        scope: Scope
    ) -> String {
        let scopeTitle = scope == .summaryOnly
            ? "Aggregate summary only"
            : "Aggregate summary plus exact daily pairs"
        let privacyText = scope == .summaryOnly
            ? """
              This summary excludes exact comparison dates, every daily provider/NOOP value, personal \
              provider and NOOP means, raw sensor streams, account details, and device identifiers.
              """
            : """
              daily_pairs.csv includes exact dates and daily official provider and NOOP values. Treat that \
              CSV as sensitive health data. This summary still excludes account details, device \
              identifiers, and raw sensor streams.
              """
        let span = inclusiveDayCount(
            firstDay: statistics.firstDay,
            lastDay: statistics.lastDay
        ).map { "\($0) calendar days" } ?? "Unavailable"
        let correlation = statistics.correlation.map { number($0) } ?? "Unavailable"

        var calibrationLines = [
            "Decision: \(report.calibration.decision.rawValue)",
            "Confidence: \(report.calibration.confidence.rawValue)",
            "Reason: \(report.calibration.reason)",
        ]
        if let validation = report.calibration.validation {
            calibrationLines.append(
                "Chronological validation: \(validation.trainingCount) training days + " +
                "\(validation.holdoutCount) untouched holdout days"
            )
            calibrationLines.append(
                "Holdout MAE improvement: \(number(validation.relativeMAEImprovement * 100))%"
            )
        }

        return CustomerFacingBrand.text("""
        NOOP provider comparison export

        PRIVACY AND ORIGIN
        Scope: \(scopeTitle)
        Created locally only after explicit user confirmation.
        NOOP did not upload this export. It is shared only through the system Files/share action you choose.
        \(privacyText)

        SOFTWARE
        NOOP version: \(context.appVersion)
        Platform: \(context.platform)
        Provider import revision: \(context.whoopImporterRevision)
        NOOP algorithm revision: \(report.noopAlgorithmVersion)

        COMPARISON
        Metric: \(metricName)
        Scale or units: \(units)
        Paired days: \(statistics.sampleCount)
        Comparison span: \(span)
        Error direction: NOOP minus official provider
        Bias: \(number(statistics.bias, signed: true))
        Mean absolute error (MAE): \(number(statistics.meanAbsoluteError))
        Root mean squared error (RMSE): \(number(statistics.rootMeanSquaredError))
        Correlation (Pearson r): \(correlation)

        PERSONAL CALIBRATION
        \(calibrationLines.joined(separator: "\n"))

        INTERPRETATION
        These results compare user-imported provider outcomes with separately computed NOOP \
        estimates on matched days. They do not recover, reproduce, or claim to know the provider's \
        proprietary formulas.

        TESTER SHARING CHECKLIST
        [ ] Latest original, unmodified wearable export ZIP
        [ ] This NOOP comparison ZIP
        On iPhone, save the NOOP ZIP to Files. In Files, select both ZIPs together, tap Share → Messages, \
        and use the same iMessage conversation with your trial coordinator. The original wearable ZIP contains sensitive health \
        data, so verify the recipient before sending. NOOP does not choose a recipient, send a message, \
        or upload either file automatically.
        """)
    }

    private static func exactPairsCSV(_ pairs: [PairedReferenceDay]) -> String {
        let rows = pairs.sorted { $0.day < $1.day }.map { pair in
            [
                pair.day,
                number(pair.official.value),
                number(pair.noop.value),
                number(pair.noop.value - pair.official.value, signed: true),
            ].joined(separator: ",")
        }
        return ([
            "day,official_provider_value,noop_value,noop_minus_official"
        ] + rows).joined(separator: "\n") + "\n"
    }

    private static func inclusiveDayCount(firstDay: String, lastDay: String) -> Int? {
        func components(_ day: String) -> DateComponents? {
            let pieces = day.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 3,
                  let year = Int(pieces[0]),
                  let month = Int(pieces[1]),
                  let day = Int(pieces[2])
            else { return nil }
            return DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0),
                year: year,
                month: month,
                day: day
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let firstComponents = components(firstDay),
              let lastComponents = components(lastDay),
              let first = calendar.date(from: firstComponents),
              let last = calendar.date(from: lastComponents),
              let days = calendar.dateComponents([.day], from: first, to: last).day,
              days >= 0
        else { return nil }
        return days + 1
    }

    private static func number(_ value: Double, signed: Bool = false) -> String {
        let normalized = abs(value) < 0.0000005 ? 0 : value
        var result = String(
            format: signed ? "%+.6f" : "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            normalized
        )
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let pieces = lowered.components(
            separatedBy: CharacterSet.alphanumerics.inverted
        ).filter { !$0.isEmpty }
        return pieces.joined(separator: "-").isEmpty ? "unknown" : pieces.joined(separator: "-")
    }
}
