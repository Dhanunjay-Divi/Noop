import Foundation
import GRDB

extension WhoopStore {
    /// Every registry identity is included so archived/secondary straps do not lose unsent history.
    public func pairedDeviceIdsForRemoteSync() async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM pairedDevice ORDER BY addedAt ASC, id ASC"
            )
        }
    }

    public func remoteSyncSleepSessions(
        deviceId: String,
        from: Int,
        to: Int,
        limit: Int,
        afterStartTs: Int? = nil
    ) async throws -> [CachedSleepSession] {
        let boundedLimit = max(1, min(limit, 5_001))
        return try syncRead { db in
            var cursorClause = ""
            var arguments: [DatabaseValueConvertible] = [deviceId, from, to]
            if let afterStartTs {
                cursorClause = " AND startTs > ?"
                arguments.append(afterStartTs)
            }
            arguments.append(boundedLimit)
            return try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited,
                       startTsAdjusted FROM sleepSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?\(cursorClause)
                ORDER BY startTs ASC LIMIT ?
                """, arguments: StatementArguments(arguments))
                .map {
                    CachedSleepSession(
                        startTs: $0["startTs"], endTs: $0["endTs"],
                        efficiency: $0["efficiency"], restingHr: $0["restingHr"],
                        avgHrv: $0["avgHrv"], stagesJSON: $0["stagesJSON"],
                        userEdited: $0["userEdited"], startTsAdjusted: $0["startTsAdjusted"]
                    )
                }
        }
    }

    public func remoteSyncWorkouts(
        deviceId: String,
        from: Int,
        to: Int,
        allowedSources: Set<String>?,
        limit: Int,
        afterStartTs: Int? = nil,
        afterSport: String? = nil
    ) async throws -> [WorkoutRow] {
        let boundedLimit = max(1, min(limit, 5_001))
        return try syncRead { db in
            var cursorClause = ""
            var sourceClause = ""
            var args: [DatabaseValueConvertible] = [deviceId, from, to]
            if let afterStartTs, let afterSport {
                cursorClause = " AND (startTs > ? OR (startTs = ? AND sport > ?))"
                args.append(afterStartTs)
                args.append(afterStartTs)
                args.append(afterSport)
            }
            if let allowedSources {
                guard !allowedSources.isEmpty else { return [] }
                let ordered = allowedSources.sorted()
                sourceClause = " AND source IN (\(ordered.map { _ in "?" }.joined(separator: ",")))"
                args.append(contentsOf: ordered)
            }
            args.append(boundedLimit)
            return try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
                       strain, distanceM, zonesJSON, notes FROM workout
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?\(cursorClause)\(sourceClause)
                ORDER BY startTs ASC, sport ASC LIMIT ?
                """, arguments: StatementArguments(args))
                .map {
                    WorkoutRow(
                        startTs: $0["startTs"], endTs: $0["endTs"], sport: $0["sport"],
                        source: $0["source"], durationS: $0["durationS"],
                        energyKcal: $0["energyKcal"], avgHr: $0["avgHr"],
                        maxHr: $0["maxHr"], strain: $0["strain"],
                        distanceM: $0["distanceM"], zonesJSON: $0["zonesJSON"],
                        notes: $0["notes"]
                    )
                }
        }
    }

    public func remoteSyncJournalEntries(
        deviceId: String,
        from: String,
        to: String,
        limit: Int,
        afterDay: String? = nil,
        afterQuestion: String? = nil
    ) async throws -> [JournalEntry] {
        let boundedLimit = max(1, min(limit, 5_001))
        return try syncRead { db in
            var cursorClause = ""
            var arguments: [DatabaseValueConvertible] = [deviceId, from, to]
            if let afterDay, let afterQuestion {
                cursorClause = " AND (day > ? OR (day = ? AND question > ?))"
                arguments.append(afterDay)
                arguments.append(afterDay)
                arguments.append(afterQuestion)
            }
            arguments.append(boundedLimit)
            return try Row.fetchAll(db, sql: """
                SELECT day, question, answeredYes, notes, numericValue FROM journal
                WHERE deviceId = ? AND day >= ? AND day <= ?\(cursorClause)
                ORDER BY day ASC, question ASC LIMIT ?
                """, arguments: StatementArguments(arguments))
                .map {
                    JournalEntry(
                        day: $0["day"], question: $0["question"],
                        answeredYes: ($0["answeredYes"] as Int) != 0,
                        notes: $0["notes"], numericValue: $0["numericValue"]
                    )
                }
        }
    }
}
