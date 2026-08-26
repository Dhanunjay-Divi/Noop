import XCTest
@testable import NoopLocalAccessCore

final class MCPServerTests: XCTestCase {
    func testInitializeIncludesReadOnlyInstructionsForCodex() throws {
        let server = NoopMCPServer(configuration: LocalAccessConfiguration(databasePath: "/unused"))
        let response = try XCTUnwrap(try server.handle(RPCRequest(id: .int(1), method: "initialize", params: nil)))
        let result = try XCTUnwrap(response.objectValue?["result"]?.objectValue)

        XCTAssertEqual(result["protocolVersion"], .string(noopLocalAccessProtocolVersion))
        XCTAssertTrue(result["instructions"]?.stringValue?.contains("read-only") == true)
        XCTAssertTrue(result["instructions"]?.stringValue?.contains("do not diagnose") == true)
    }

    func testToolsAreAnnotatedReadOnly() throws {
        let tools = try XCTUnwrap(toolsList().objectValue?["tools"])
        guard case .array(let values) = tools else {
            return XCTFail("Expected tools array")
        }

        XCTAssertFalse(values.isEmpty)
        for tool in values {
            let annotations = try XCTUnwrap(tool.objectValue?["annotations"]?.objectValue)
            XCTAssertEqual(annotations["readOnlyHint"], .bool(true))
            XCTAssertEqual(annotations["openWorldHint"], .bool(false))
        }
    }

    func testMetricSeriesUsesComputedFallbackForMissingImportedDay() throws {
        let url = try TemporaryDatabase.seeded()
        let server = NoopMCPServer(configuration: LocalAccessConfiguration(databasePath: url.path))
        let response = try XCTUnwrap(try server.handle(RPCRequest(
            id: .int(2),
            method: "tools/call",
            params: .object([
                "name": .string("metric_series"),
                "arguments": .object([
                    "key": .string("hrv"),
                    "from_day": .string("2026-06-10"),
                    "to_day": .string("2026-06-11"),
                ]),
            ])
        )))

        let structured = try XCTUnwrap(response.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue)
        XCTAssertEqual(structured["returned"], .int(2))
        guard case .array(let points) = structured["points"] else {
            return XCTFail("Expected points array")
        }
        XCTAssertEqual(points.compactMap { $0.objectValue?["source"]?.stringValue }, ["my-whoop", "my-whoop-noop"])
    }

    func testDetailedLocalStagesRequirePersistedRREvidence() throws {
        let url = try TemporaryDatabase.seeded { db in
            try db.execute(sql: """
                UPDATE dailyMetric
                SET deepMin = 70, remMin = 90, lightMin = 250
                WHERE deviceId = 'my-whoop-noop' AND day = '2026-06-11'
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric(
                    deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin
                ) VALUES
                    ('my-whoop-noop', '2026-06-12', 420, 0.9, 80, 100, 240),
                    ('my-whoop-noop', '2026-06-13', 420, 0.9, 85, 105, 230),
                    ('my-whoop-noop', '2026-06-14', 420, 0.9, 90, 110, 220),
                    ('my-whoop-noop', '2026-06-15', 420, 0.9, 95, 115, 210)
                """)
            try db.execute(sql: """
                INSERT INTO metricSeries(deviceId, day, key, value)
                VALUES
                    ('my-whoop-noop', '2026-06-11', 'sleep_deep_min', 70),
                    ('my-whoop-noop', '2026-06-12', 'sleep_deep_min', 80),
                    ('my-whoop-noop', '2026-06-13', 'sleep_deep_min', 85),
                    ('my-whoop-noop', '2026-06-14', 'sleep_deep_min', 90),
                    ('my-whoop-noop', '2026-06-15', 'sleep_deep_min', 95)
                """)
            try db.execute(sql: """
                INSERT INTO sleepSession(
                    deviceId, startTs, endTs, efficiency, stagesJSON,
                    rrEligibleWindowCount, rrValidWindowCount
                ) VALUES
                    (
                        'my-whoop-noop',
                        CAST(strftime('%s', '2026-06-10 22:00:00') AS INTEGER),
                        CAST(strftime('%s', '2026-06-11 06:00:00') AS INTEGER),
                        0.9, '{"light":250,"deep":70,"rem":90,"awake":70}',
                        96, 23
                    ),
                    (
                        'my-whoop-noop',
                        CAST(strftime('%s', '2026-06-11 22:00:00') AS INTEGER),
                        CAST(strftime('%s', '2026-06-12 06:00:00') AS INTEGER),
                        0.9, '{"light":240,"deep":80,"rem":100,"awake":60}',
                        95, 24
                    ),
                    (
                        'my-whoop-noop',
                        CAST(strftime('%s', '2026-06-12 22:00:00') AS INTEGER),
                        CAST(strftime('%s', '2026-06-13 06:00:00') AS INTEGER),
                        0.9, '{"light":230,"deep":85,"rem":105,"awake":60}',
                        96, 24
                    ),
                    (
                        'my-whoop-noop',
                        CAST(strftime('%s', '2026-06-13 22:00:00') AS INTEGER),
                        CAST(strftime('%s', '2026-06-14 06:00:00') AS INTEGER),
                        0.9, 'not-json',
                        96, 24
                    ),
                    (
                        'my-whoop-noop',
                        CAST(strftime('%s', '2026-06-14 22:00:00') AS INTEGER),
                        CAST(strftime('%s', '2026-06-15 06:00:00') AS INTEGER),
                        0.9, '{"unknown":480}',
                        96, 24
                    )
                """)
        }
        let access = NoopDataAccess(
            store: try ReadonlyNoopStore(path: url.path),
            deviceId: "my-whoop")

        let snapshot = try XCTUnwrap(try access.healthSnapshot(days: 4000).objectValue)
        guard case .array(let recent) = snapshot["recentDays"] else {
            return XCTFail("Expected recentDays")
        }
        let unsupported = recent.first { $0.objectValue?["day"] == .string("2026-06-11") }
        let staleBounds = recent.first { $0.objectValue?["day"] == .string("2026-06-12") }
        let supported = recent.first { $0.objectValue?["day"] == .string("2026-06-13") }
        let malformed = recent.first { $0.objectValue?["day"] == .string("2026-06-14") }
        let unrecognized = recent.first { $0.objectValue?["day"] == .string("2026-06-15") }
        XCTAssertEqual(unsupported?.objectValue?["deepMin"], .null)
        XCTAssertEqual(unsupported?.objectValue?["remMin"], .null)
        XCTAssertEqual(staleBounds?.objectValue?["deepMin"], .null)
        XCTAssertEqual(staleBounds?.objectValue?["remMin"], .null)
        XCTAssertEqual(supported?.objectValue?["deepMin"], .double(85))
        XCTAssertEqual(supported?.objectValue?["remMin"], .double(105))
        XCTAssertEqual(malformed?.objectValue?["deepMin"], .null)
        XCTAssertEqual(unrecognized?.objectValue?["deepMin"], .null)

        let series = try XCTUnwrap(try access.metricSeries(
            key: "sleep_deep_min",
            source: "my-whoop",
            days: 4000,
            fromDay: "2026-06-10",
            toDay: "2026-06-15",
            limit: 100
        ).objectValue)
        XCTAssertEqual(series["returned"], .int(1))
        guard case .array(let points) = series["points"] else {
            return XCTFail("Expected points")
        }
        XCTAssertEqual(points.first?.objectValue?["day"], .string("2026-06-13"))
        XCTAssertEqual(points.first?.objectValue?["value"], .double(85))
    }

    func testDetailedStagesBridgeBeforeCrossMidnightDayAssignment() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func timestamp(_ day: Int, _ hour: Int, _ minute: Int) -> Int {
            Int(calendar.date(from: DateComponents(
                year: 2026,
                month: 6,
                day: day,
                hour: hour,
                minute: minute
            ))!.timeIntervalSince1970)
        }

        let firstStart = timestamp(20, 20, 0)
        let firstEnd = timestamp(20, 23, 55)
        let secondStart = timestamp(21, 0, 5)
        let secondEnd = timestamp(21, 3, 0)
        let url = try TemporaryDatabase.seeded { db in
            try db.execute(sql: """
                INSERT INTO dailyMetric(
                    deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin
                ) VALUES
                    ('my-whoop-noop', '2026-06-20', 220, 0.9, 40, 40, 140),
                    ('my-whoop-noop', '2026-06-21', 165, 0.9, 30, 35, 100)
                """)
            try db.execute(sql: """
                INSERT INTO metricSeries(deviceId, day, key, value)
                VALUES
                    ('my-whoop-noop', '2026-06-20', 'sleep_deep_min', 40),
                    ('my-whoop-noop', '2026-06-21', 'sleep_deep_min', 30)
                """)
            try db.execute(
                sql: """
                    INSERT INTO sleepSession(
                        deviceId, startTs, endTs, efficiency, stagesJSON,
                        rrEligibleWindowCount, rrValidWindowCount
                    ) VALUES
                        ('my-whoop-noop', ?, ?, 0.9,
                         '{"light":140,"deep":40,"rem":40,"awake":15}', 47, 12),
                        ('my-whoop-noop', ?, ?, 0.9,
                         '{"light":100,"deep":30,"rem":35,"awake":10}', 35, NULL)
                    """,
                arguments: [firstStart, firstEnd, secondStart, secondEnd])
        }
        let access = NoopDataAccess(
            store: try ReadonlyNoopStore(path: url.path),
            deviceId: "my-whoop")

        let series = try XCTUnwrap(try access.metricSeries(
            key: "sleep_deep_min",
            source: "my-whoop",
            days: 4000,
            fromDay: "2026-06-20",
            toDay: "2026-06-21",
            limit: 100
        ).objectValue)

        XCTAssertEqual(
            series["returned"],
            .int(0),
            "the supported pre-midnight fragment must not publish apart from its unsupported continuation")
    }
}
