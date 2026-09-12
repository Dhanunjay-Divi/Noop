import XCTest
import WhoopStore
@testable import Strand

/// #798 - the per-entry hydration list (add / delete / edit / total). The day total banked into
/// `metricSeries` is always re-derived from this list, so the math here is the source of truth for an
/// edited day. These pin: a non-positive amount never enters the list, deleting/editing keeps the total
/// non-negative and self-consistent, and an edit to 0 is a delete (no zero rows linger).
@MainActor
final class HydrationEntriesTests: XCTestCase {

    private func entry(_ ml: Int, secondsAgo: TimeInterval = 0) -> HydrationEntry {
        HydrationEntry(amountMl: ml, loggedAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo))
    }

    // MARK: - adding

    func testAddingAppendsPositiveAmount() {
        let out = HydrationEntries.adding([], amountMl: 237)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.amountMl, 237)
    }

    func testAddingRejectsNonPositive() {
        XCTAssertTrue(HydrationEntries.adding([], amountMl: 0).isEmpty)
        XCTAssertTrue(HydrationEntries.adding([], amountMl: -50).isEmpty)
    }

    // MARK: - total

    func testTotalSumsAmounts() {
        let list = [entry(30), entry(237), entry(500)]
        XCTAssertEqual(HydrationEntries.total(list), 767, accuracy: 0.0001)
    }

    func testTotalOfEmptyIsZero() {
        XCTAssertEqual(HydrationEntries.total([]), 0, accuracy: 0.0001)
    }

    func testDisplayPolicyKeepsMissingAndClearedTotalsUnlogged() {
        XCTAssertNil(HydrationStore.confirmedTotal(nil))
        XCTAssertNil(HydrationStore.confirmedTotal(0))
        XCTAssertNil(HydrationStore.confirmedTotal(-1))
        XCTAssertNil(HydrationStore.confirmedTotal(.nan))
        XCTAssertEqual(
            HydrationStore.cardValue(totalML: nil, goalML: 3_200, missingText: "Not logged"),
            "Not logged"
        )
        XCTAssertEqual(
            HydrationStore.cardValue(totalML: 1_200, goalML: 3_200, missingText: "Not logged"),
            "1.2 / 3.2 L"
        )
    }

    func testHydrationDisplayFormattingUsesLocaleDecimalSeparators() {
        XCTAssertEqual(
            HydrationDisplayFormatting.decimalLitres(
                fromML: 1_250,
                locale: Locale(identifier: "en_US")
            ),
            "1.2"
        )
        XCTAssertEqual(
            HydrationDisplayFormatting.decimalLitres(
                fromML: 1_250,
                locale: Locale(identifier: "de_DE")
            ),
            "1,2"
        )
    }

    func testHydrationWeekdayLabelsFollowLocaleAndKeepFullSpokenName() {
        let english = HydrationDisplayFormatting.weekdayText(
            forDayKey: "2026-09-09",
            locale: Locale(identifier: "en_US")
        )
        let german = HydrationDisplayFormatting.weekdayText(
            forDayKey: "2026-09-09",
            locale: Locale(identifier: "de_DE")
        )

        XCTAssertEqual(english, HydrationWeekdayText(compact: "W", spoken: "Wednesday"))
        XCTAssertEqual(german, HydrationWeekdayText(compact: "M", spoken: "Mittwoch"))
        XCTAssertNil(
            HydrationDisplayFormatting.weekdayText(
                forDayKey: "not-a-day",
                locale: Locale(identifier: "de_DE")
            )
        )
    }

    func testHydrationAccessibilityDescriptionsUseLocalizedMetricTemplates() {
        let english = HydrationDisplayFormatting.ringAccessibilityValue(
            totalML: 1_250,
            goalML: 3_200,
            missingText: "Not logged",
            targetUnavailable: "Target unavailable",
            locale: Locale(identifier: "en_US")
        )
        let german = HydrationDisplayFormatting.ringAccessibilityValue(
            totalML: 1_250,
            goalML: 3_200,
            missingText: "Nicht protokolliert",
            targetUnavailable: "Ziel nicht verfügbar",
            locale: Locale(identifier: "de_DE")
        )
        let germanHistory = HydrationDisplayFormatting.historyAccessibilityLabel(
            dayKey: "2026-09-09",
            valueML: 1_250,
            missingText: "Nicht protokolliert",
            locale: Locale(identifier: "de_DE")
        )

        XCTAssertEqual(english, "1.2 of 3.2 litres")
        XCTAssertEqual(german, "1,2 von 3,2 Litern")
        XCTAssertEqual(germanHistory, "Mittwoch: 1,2 Liter")
    }

    func testHydrationViewUsesLocalizedFormattingInsteadOfUSWeekdayFormatter() throws {
        let hydration = try source("Strand/Screens/HydrationView.swift")

        XCTAssertFalse(hydration.contains("Locale(identifier: \"en_US\")"))
        XCTAssertFalse(hydration.contains("weekdayAbbrev"))
        XCTAssertTrue(hydration.contains("HydrationDisplayFormatting.weekdayText"))
        XCTAssertTrue(hydration.contains("HydrationDisplayFormatting.entryAccessibilityLabel"))
        XCTAssertTrue(hydration.contains("HydrationDisplayFormatting.visibleMillilitres"))
    }

    func testSingleSourceProvenanceNamesTheSourceWithoutAnOverlapWarning() {
        let presentation = HydrationReading(
            valueML: 500,
            source: .appleHealth,
            noopML: 0,
            appleHealthML: 500
        ).provenance(
            strings: HydrationProvenanceStrings(
                noopOnlyLabel: "NOOP",
                externalOnlyLabel: "Apple Health",
                bothLabel: "NOOP and Apple Health",
                bothExplanation: "merge explanation"
            )
        )

        XCTAssertEqual(presentation.sourceLabel, "Apple Health")
        XCTAssertNil(presentation.explanation)
        XCTAssertTrue(presentation.sourceTotals.isEmpty)
    }

    func testBothSourceProvenanceKeepsTotalsSeparateAndExplainsTheConservativeMerge() {
        let explanation = "The displayed total uses the larger source total."
        let presentation = HydrationReading(
            valueML: 700,
            source: .both,
            noopML: 500,
            appleHealthML: 700
        ).provenance(
            strings: HydrationProvenanceStrings(
                noopOnlyLabel: "NOOP",
                externalOnlyLabel: "Apple Health",
                bothLabel: "NOOP and Apple Health",
                bothExplanation: explanation
            )
        )

        XCTAssertEqual(presentation.sourceLabel, "NOOP and Apple Health")
        XCTAssertEqual(presentation.explanation, explanation)
        XCTAssertEqual(
            presentation.sourceTotals,
            [
                HydrationSourceTotal(source: .noop, valueML: 500),
                HydrationSourceTotal(source: .appleHealth, valueML: 700),
            ]
        )
    }

    func testTrailingHistoryKeysEndOnTheExplicitDayAndRejectInvalidDates() {
        XCTAssertEqual(
            HydrationStore.trailingDayKeys(throughDay: "2028-03-01", days: 3),
            ["2028-02-28", "2028-02-29", "2028-03-01"]
        )
        XCTAssertNil(HydrationStore.trailingDayKeys(throughDay: "2028-02-30", days: 7))
        XCTAssertNil(HydrationStore.trailingDayKeys(throughDay: "not-a-day", days: 7))
    }

    func testLegacyScalarEntryTimestampStaysInsideRepresentedDayAcrossTimezones() throws {
        let day = "2026-09-01"
        for secondsFromGMT in [-12 * 3_600, 0, 14 * 3_600] {
            let zone = try XCTUnwrap(TimeZone(secondsFromGMT: secondsFromGMT))
            let date = try XCTUnwrap(
                HydrationStore.legacyEntryDate(
                    forDayKey: day,
                    timeZone: zone
                )
            )
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour],
                from: date
            )
            XCTAssertEqual(components.year, 2026)
            XCTAssertEqual(components.month, 9)
            XCTAssertEqual(components.day, 1)
            XCTAssertEqual(components.hour, 12)

            let utcDayStart = try XCTUnwrap(
                ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")
            ).timeIntervalSince1970
            XCTAssertGreaterThanOrEqual(
                date.timeIntervalSince1970,
                utcDayStart - 14 * 3_600
            )
            XCTAssertLessThan(
                date.timeIntervalSince1970,
                utcDayStart + 36 * 3_600
            )
        }
    }

    func testLegacyScalarOnlyDayMaterializesAtRepresentedDayInsteadOfNow() async throws {
        let day = "2026-09-01"
        clearEntries(day: day)
        defer { clearEntries(day: day) }
        let (repo, store) = try await makeRepository()
        _ = try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: HydrationStore.key, value: 500)],
            deviceId: HydrationStore.sourceId
        )

        let entries = try await repo.hydrationEntries(day: day)
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(entry.amountMl, 500)
        XCTAssertEqual(
            Repository.localDayKey(entry.loggedAt),
            day
        )
        XCTAssertLessThan(
            entry.loggedAt,
            Date(timeIntervalSince1970: 1_800_000_000),
            "A historical scalar must not be stamped with the migration/open time."
        )
    }

    func testHydrationRouteCarriesTheSelectedDay() {
        let route = TabRoute.hydration(day: "2026-09-01")
        guard case .hydration(let selectedDay) = route else {
            return XCTFail("Expected the hydration route")
        }
        XCTAssertEqual(selectedDay, "2026-09-01")
        XCTAssertNotEqual(route, .hydration(day: "2026-09-02"))
    }

    func testBothTodaySurfacesRouteHydrationWithTheirSelectedDay() throws {
        let classic = try source("Strand/Screens/TodayView.swift")
        let liquid = try source("Strand/Liquid/LiquidTodayView.swift")

        XCTAssertTrue(classic.contains("route: .hydration(day: selectedDayKey)"))
        XCTAssertTrue(liquid.contains("cardLink(.hydration(day: selectedDayKey)"))
        XCTAssertFalse(classic.contains("route: .hydration)"))
        XCTAssertFalse(liquid.contains("cardLink(.hydration,"))
    }

    func testDetailModelDefaultsToCalendarToday() {
        let now = Date(timeIntervalSince1970: 1_789_070_400)
        let model = HydrationDetailModel(now: now)

        XCTAssertTrue(model.hasValidDay)
        XCTAssertEqual(model.selectedDayKey, Repository.localDayKey(now))
    }

    // MARK: - removing

    func testRemovingDropsTheTargetAndRederivesTotal() {
        let a = entry(30), b = entry(500)
        let after = HydrationEntries.removing([a, b], id: a.id)
        XCTAssertEqual(after.map(\.id), [b.id])
        XCTAssertEqual(HydrationEntries.total(after), 500, accuracy: 0.0001)
    }

    func testRemovingUnknownIdIsNoOp() {
        let a = entry(30)
        let after = HydrationEntries.removing([a], id: UUID())
        XCTAssertEqual(after.map(\.id), [a.id])
    }

    // MARK: - updating

    func testUpdatingSetsNewAmountAndKeepsIdentity() {
        let a = entry(30)
        let after = HydrationEntries.updating([a], id: a.id, amountMl: 250)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.id, a.id)              // identity preserved
        XCTAssertEqual(after.first?.amountMl, 250)
        XCTAssertEqual(after.first?.loggedAt, a.loggedAt)  // timestamp preserved
    }

    func testUpdatingToNonPositiveDeletesTheEntry() {
        let a = entry(30), b = entry(500)
        let after = HydrationEntries.updating([a, b], id: a.id, amountMl: 0)
        XCTAssertEqual(after.map(\.id), [b.id])
        XCTAssertEqual(HydrationEntries.total(after), 500, accuracy: 0.0001)
    }

    func testUpdatingUnknownIdIsNoOp() {
        let a = entry(30)
        let after = HydrationEntries.updating([a], id: UUID(), amountMl: 999)
        XCTAssertEqual(after.first?.amountMl, 30)
    }

    // MARK: - Persistence integrity

    func testConcurrentAddsPreserveEveryIncrementAndEntry() async throws {
        let day = "2098-01-01"
        clearEntries(day: day)
        defer { clearEntries(day: day) }
        let (repo, store) = try await makeRepository()

        async let first = repo.logHydration(amountMl: 237, day: day)
        async let second = repo.logHydration(amountMl: 500, day: day)
        let results = await (first, second)

        XCTAssertTrue(results.0.succeeded)
        XCTAssertTrue(results.1.succeeded)
        let rows = try await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )
        XCTAssertEqual(try XCTUnwrap(rows.first?.value), 737, accuracy: 0.0001)
        let amounts = try await repo.hydrationEntries(day: day).map(\.amountMl).sorted()
        XCTAssertEqual(amounts, [237, 500])
        XCTAssertEqual(repo.hydrationSeq, 2)
    }

    func testFailedMutationsLeaveCanonicalEntriesAndRevisionUnchanged() async throws {
        let day = "2098-01-02"
        clearEntries(day: day)
        defer { clearEntries(day: day) }
        let (repo, store) = try await makeRepository()
        let seeded = await repo.logHydration(amountMl: 237, day: day)
        XCTAssertTrue(seeded.succeeded)
        let originalEntries = try await repo.hydrationEntries(day: day)
        let originalRevision = repo.hydrationSeq
        let entry = try XCTUnwrap(originalEntries.first)
        repo.setHydrationFailureForTesting(writes: true)

        let added = await repo.logHydration(amountMl: 500, day: day)
        let updated = await repo.updateHydrationEntry(
            id: entry.id,
            amountMl: 300,
            day: day
        )
        let deleted = await repo.deleteHydrationEntry(id: entry.id, day: day)

        XCTAssertFalse(added.succeeded)
        XCTAssertFalse(updated.succeeded)
        XCTAssertFalse(deleted.succeeded)
        let persistedEntries = try await repo.hydrationEntries(day: day)
        XCTAssertEqual(persistedEntries, originalEntries)
        XCTAssertEqual(repo.hydrationSeq, originalRevision)
        repo.setHydrationFailureForTesting()
        let rows = try await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )
        XCTAssertEqual(try XCTUnwrap(rows.first?.value), 237, accuracy: 0.0001)
    }

    func testMalformedPersistedEntryBlocksEveryMutationWithoutChangingCanonicalState() async throws {
        let day = "2098-01-05"
        clearEntries(day: day)
        defer { clearEntries(day: day) }
        let (repo, store) = try await makeRepository()
        let validID = UUID()
        try await store.seedHydrationPersistenceForTesting(
            [
                HydrationLogEntry(
                    id: validID.uuidString.lowercased(),
                    day: day,
                    amountML: 237,
                    loggedAt: 4_040_000_000
                ),
                HydrationLogEntry(
                    id: "not-a-uuid",
                    day: day,
                    amountML: 263,
                    loggedAt: 4_040_000_001
                ),
            ],
            deviceId: HydrationStore.sourceId,
            day: day,
            metricKey: HydrationStore.key,
            totalML: 500
        )
        let originalRevision = repo.hydrationSeq

        do {
            _ = try await repo.hydrationEntries(day: day)
            XCTFail("Malformed persisted hydration must fail closed.")
        } catch {
            // Expected: a malformed canonical row must block reads and mutations.
        }
        let added = await repo.logHydration(amountMl: 100, day: day)
        let updated = await repo.updateHydrationEntry(
            id: validID,
            amountMl: 300,
            day: day
        )
        let deleted = await repo.deleteHydrationEntry(id: validID, day: day)

        XCTAssertFalse(added.succeeded)
        XCTAssertFalse(updated.succeeded)
        XCTAssertFalse(deleted.succeeded)
        XCTAssertEqual(repo.hydrationSeq, originalRevision)
        let persistedEntries = try await store.hydrationLogEntries(
            deviceId: HydrationStore.sourceId,
            day: day
        )
        XCTAssertEqual(
            persistedEntries.map(\.id),
            [validID.uuidString.lowercased(), "not-a-uuid"]
        )
        XCTAssertEqual(persistedEntries.map(\.amountML), [237, 263])
        let totals = try await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )
        XCTAssertEqual(try XCTUnwrap(totals.first?.value), 500, accuracy: 0.0001)
    }

    func testDeletingLastEntryIsSuccessfulAndBanksCanonicalZero() async throws {
        let day = "2098-01-03"
        clearEntries(day: day)
        defer { clearEntries(day: day) }
        let (repo, store) = try await makeRepository()
        let seeded = await repo.logHydration(amountMl: 237, day: day)
        XCTAssertTrue(seeded.succeeded)
        let seededEntries = try await repo.hydrationEntries(day: day)
        let entry = try XCTUnwrap(seededEntries.first)

        let result = await repo.deleteHydrationEntry(id: entry.id, day: day)

        XCTAssertEqual(result, .saved(totalML: nil))
        let persistedEntries = try await repo.hydrationEntries(day: day)
        XCTAssertTrue(persistedEntries.isEmpty)
        let rows = try await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )
        XCTAssertEqual(try XCTUnwrap(rows.first?.value), 0, accuracy: 0.0001)
        XCTAssertEqual(repo.hydrationSeq, 2)
    }

    func testReadFailureDoesNotMasqueradeAsMissingIntake() async throws {
        let (repo, _) = try await makeRepository()
        repo.setHydrationFailureForTesting(reads: true)

        do {
            _ = try await repo.hydrationTotal(day: "2098-01-04")
            XCTFail("Expected the broken local store read to throw")
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testDetailModelLoadsOnlyTheSelectedDayAndHistoryEndsThere() async throws {
        let selectedDay = "2098-02-10"
        let laterDay = "2098-02-20"
        clearEntries(day: selectedDay)
        clearEntries(day: laterDay)
        defer {
            clearEntries(day: selectedDay)
            clearEntries(day: laterDay)
        }
        let (repo, _) = try await makeRepository()
        let selectedSeed = await repo.logHydration(amountMl: 237, day: selectedDay)
        let laterSeed = await repo.logHydration(amountMl: 500, day: laterDay)
        XCTAssertTrue(selectedSeed.succeeded)
        XCTAssertTrue(laterSeed.succeeded)

        let snapshot = try await HydrationDetailModel(
            selectedDayKey: selectedDay
        ).load(from: repo)

        XCTAssertEqual(snapshot.totalML, 237)
        XCTAssertEqual(snapshot.reading?.source, .noop)
        XCTAssertEqual(snapshot.reading?.noopML, 237)
        XCTAssertEqual(snapshot.entries.map(\.amountMl), [237])
        XCTAssertEqual(snapshot.history.count, 7)
        XCTAssertEqual(snapshot.history.last?.day, selectedDay)
        XCTAssertEqual(snapshot.history.last?.value, 237)
        XCTAssertFalse(snapshot.history.contains { $0.day == laterDay })
    }

    func testSourceAwareDetailReadUsesTheLargerTotalInsteadOfAddingOverlappingSources() async throws {
        let day = "2098-02-11"
        clearEntries(day: day)
        defer { clearEntries(day: day) }
        let (repo, store) = try await makeRepository()
        let noopSeed = await repo.logHydration(amountMl: 500, day: day)
        XCTAssertTrue(noopSeed.succeeded)
        try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: HydrationStore.key, value: 700)],
            deviceId: Repository.appleHealthSource
        )

        let snapshot = try await HydrationDetailModel(
            selectedDayKey: day
        ).load(from: repo)

        XCTAssertEqual(snapshot.totalML, 700)
        XCTAssertEqual(snapshot.reading?.source, .both)
        XCTAssertEqual(snapshot.reading?.noopML, 500)
        XCTAssertEqual(snapshot.reading?.appleHealthML, 700)
        XCTAssertNotEqual(snapshot.totalML, 1_200)
    }

    func testDetailModelAddEditDeleteAndUndoStyleRemovalNeverTouchAnotherDay() async throws {
        let selectedDay = "2098-03-10"
        let todayDay = "2098-03-20"
        clearEntries(day: selectedDay)
        clearEntries(day: todayDay)
        defer {
            clearEntries(day: selectedDay)
            clearEntries(day: todayDay)
        }
        let (repo, _) = try await makeRepository()
        let todaySeed = await repo.logHydration(amountMl: 700, day: todayDay)
        XCTAssertTrue(todaySeed.succeeded)
        let model = HydrationDetailModel(selectedDayKey: selectedDay)

        let addedCup = await model.add(amountML: 237, to: repo)
        let addedSip = await model.add(amountML: 30, to: repo)
        XCTAssertTrue(addedCup.succeeded)
        XCTAssertTrue(addedSip.succeeded)
        var entries = try await repo.hydrationEntries(day: selectedDay)
        let cup = try XCTUnwrap(entries.first(where: { $0.amountMl == 237 }))
        let latestSip = try XCTUnwrap(entries.first(where: { $0.amountMl == 30 }))

        let updatedCup = await model.update(
            entryID: cup.id,
            amountML: 300,
            in: repo
        )
        let undidSip = await model.delete(entryID: latestSip.id, from: repo)
        let addedBottle = await model.add(amountML: 500, to: repo)
        let deletedCup = await model.delete(entryID: cup.id, from: repo)
        XCTAssertTrue(updatedCup.succeeded)
        XCTAssertTrue(
            undidSip.succeeded,
            "Removing the latest add is the existing undo/correction primitive."
        )
        XCTAssertTrue(addedBottle.succeeded)
        XCTAssertTrue(deletedCup.succeeded)

        entries = try await repo.hydrationEntries(day: selectedDay)
        let selectedTotal = try await repo.hydrationTotal(day: selectedDay)
        let todayTotal = try await repo.hydrationTotal(day: todayDay)
        let todayEntries = try await repo.hydrationEntries(day: todayDay)
        XCTAssertEqual(entries.map(\.amountMl), [500])
        XCTAssertEqual(selectedTotal, 500)
        XCTAssertEqual(todayTotal, 700)
        XCTAssertEqual(todayEntries.map(\.amountMl), [700])
    }

    func testInvalidExplicitDayFailsClosedWithoutFallingBackToToday() async throws {
        let todayDay = "2098-04-20"
        clearEntries(day: todayDay)
        defer { clearEntries(day: todayDay) }
        let (repo, _) = try await makeRepository()
        let todaySeed = await repo.logHydration(amountMl: 500, day: todayDay)
        XCTAssertTrue(todaySeed.succeeded)
        let model = HydrationDetailModel(selectedDayKey: "invalid-day")

        XCTAssertFalse(model.hasValidDay)
        let rejectedAdd = await model.add(amountML: 237, to: repo)
        XCTAssertFalse(rejectedAdd.succeeded)
        do {
            _ = try await model.load(from: repo)
            XCTFail("An invalid explicit route must fail closed.")
        } catch {
            XCTAssertEqual(error as? HydrationDetailModelError, .invalidDayKey)
        }
        let todayTotal = try await repo.hydrationTotal(day: todayDay)
        XCTAssertEqual(todayTotal, 500)
    }

    func testDetailReloadPublishesOneSnapshotAndClearsStalePresentationOnFailure() throws {
        let hydrationSource = try source("Strand/Screens/HydrationView.swift")
        let reload = try XCTUnwrap(
            hydrationSource.range(of: "    private func reload() async {")
        )
        let reloadBody = hydrationSource[reload.lowerBound...]
        let reloadEnd = try XCTUnwrap(
            reloadBody.range(of: "\n    }\n}\n\n// MARK: - Amount sheet")
        )
        let boundedReload = String(
            reloadBody[..<reloadEnd.lowerBound]
        )

        XCTAssertTrue(boundedReload.contains("hydrationSnapshot = snapshot"))
        XCTAssertTrue(boundedReload.contains("hydrationSnapshot = nil"))
        XCTAssertTrue(boundedReload.contains("editingEntry = nil"))
        XCTAssertTrue(boundedReload.contains("hasLoadedHydration = false"))
    }

    private func makeRepository() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "hydration-test", mac: nil, name: "Test")
        let repo = Repository(deviceId: "hydration-test")
        repo.setStoreForTesting(store)
        return (repo, store)
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func clearEntries(day: String) {
        UserDefaults.standard.removeObject(
            forKey: HydrationStore.entriesKey(forDay: day)
        )
    }
}
