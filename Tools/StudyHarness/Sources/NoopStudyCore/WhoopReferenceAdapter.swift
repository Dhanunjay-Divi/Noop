import Foundation
import StrandAnalytics
import StrandImport

public struct ExportFeatureDay: Equatable, Sendable {
    public let day: String
    public let restingHeartRate: Double?
    public let hrvRMSSD: Double?
    public let respiratoryRate: Double?
    public let totalSleepMinutes: Double?
    public let inBedMinutes: Double?
    public let deepSleepMinutes: Double?
    public let remSleepMinutes: Double?
    public let lightSleepMinutes: Double?
    public let sleepEfficiencyPercent: Double?

    public init(
        day: String,
        restingHeartRate: Double?,
        hrvRMSSD: Double?,
        respiratoryRate: Double?,
        totalSleepMinutes: Double?,
        inBedMinutes: Double?,
        deepSleepMinutes: Double?,
        remSleepMinutes: Double?,
        lightSleepMinutes: Double?,
        sleepEfficiencyPercent: Double?
    ) {
        self.day = day
        self.restingHeartRate = restingHeartRate
        self.hrvRMSSD = hrvRMSSD
        self.respiratoryRate = respiratoryRate
        self.totalSleepMinutes = totalSleepMinutes
        self.inBedMinutes = inBedMinutes
        self.deepSleepMinutes = deepSleepMinutes
        self.remSleepMinutes = remSleepMinutes
        self.lightSleepMinutes = lightSleepMinutes
        self.sleepEfficiencyPercent = sleepEfficiencyPercent
    }
}

public struct StudyReferenceAuditInternal: Equatable, Sendable {
    public let cycleRows: Int
    public let officialCycleRows: Int
    public let sleepRows: Int
    public let workoutRows: Int
    public let journalRowsDiscarded: Int
    public let duplicateOfficialDaysDropped: Int
    public let quarantinedNonOfficialRows: Int
}

public struct StudySubjectReference: Equatable, Sendable {
    public let valuesByMetric: [WhoopComparableMetric: [String: Double]]
    public let featureDays: [ExportFeatureDay]
    public let audit: StudyReferenceAuditInternal
}

public enum WhoopReferenceAdapter {
    public static func load(from url: URL) throws -> StudySubjectReference {
        let result = try ImportCoordinator().importWhoopExport(from: url)
        let official = result.cycles.filter {
            WhoopCSVRowProvenance.classify(sourceLabel: $0.sourceLabel) == .officialReference
        }
        let quarantined = result.cycles.count - official.count

        var rowsByDay: [String: WhoopCycleRow] = [:]
        var duplicates = Set<String>()
        for row in official {
            guard let day = WhoopDayKeying.wakeDayKey(
                wake: row.wakeOnset,
                end: row.cycleEnd,
                start: row.cycleStart,
                tzOffsetMin: row.tzOffsetMin
            ), validDay(day) else {
                continue
            }
            if rowsByDay.updateValue(row, forKey: day) != nil {
                duplicates.insert(day)
            }
        }
        for day in duplicates { rowsByDay.removeValue(forKey: day) }

        var values: [WhoopComparableMetric: [String: Double]] = [:]
        var features: [ExportFeatureDay] = []
        for day in rowsByDay.keys.sorted() {
            guard let row = rowsByDay[day] else { continue }
            func add(_ metric: WhoopComparableMetric, _ value: Double?) {
                if let value, value.isFinite {
                    values[metric, default: [:]][day] = value
                }
            }
            add(.recoveryScore, row.recoveryScore)
            add(.effortScore, WhoopExportImporter.effortFromImportedDayStrain(row.dayStrain))
            add(.restScore, row.sleepPerformancePct)
            add(.restingHeartRate, row.restingHeartRate)
            add(.hrvRMSSD, row.hrvMs)
            add(.respiratoryRate, row.respiratoryRate)
            add(.bloodOxygenPercent, row.bloodOxygenPct)
            add(.totalSleepMinutes, row.asleepDurationMin)
            add(.deepSleepMinutes, row.deepSleepDurationMin)
            add(.remSleepMinutes, row.remDurationMin)
            add(.lightSleepMinutes, row.lightSleepDurationMin)
            add(.sleepEfficiencyPercent, row.sleepEfficiencyPct)

            features.append(ExportFeatureDay(
                day: day,
                restingHeartRate: row.restingHeartRate,
                hrvRMSSD: row.hrvMs,
                respiratoryRate: row.respiratoryRate,
                totalSleepMinutes: row.asleepDurationMin,
                inBedMinutes: row.inBedDurationMin,
                deepSleepMinutes: row.deepSleepDurationMin,
                remSleepMinutes: row.remDurationMin,
                lightSleepMinutes: row.lightSleepDurationMin,
                sleepEfficiencyPercent: row.sleepEfficiencyPct
            ))
        }

        return StudySubjectReference(
            valuesByMetric: values,
            featureDays: features,
            audit: StudyReferenceAuditInternal(
                cycleRows: result.cycles.count,
                officialCycleRows: official.count,
                sleepRows: result.sleeps.count,
                workoutRows: result.workouts.count,
                journalRowsDiscarded: result.journal.count,
                duplicateOfficialDaysDropped: duplicates.count,
                quarantinedNonOfficialRows: quarantined
            )
        )
    }
}

enum StudyDay {
    static func valid(_ day: String) -> Bool {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let dayOfMonth = Int(parts[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: dayOfMonth
        )
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year
            && roundTrip.month == month
            && roundTrip.day == dayOfMonth
    }
}

private func validDay(_ day: String) -> Bool { StudyDay.valid(day) }
