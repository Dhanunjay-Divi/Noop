import XCTest
@testable import WhoopStore

final class PortableUserDataTests: XCTestCase {
    private let now = 1_777_000_000

    private func nutrition(
        id: String = "meal-1",
        day: String = "2026-08-22",
        calories: Double? = nil,
        protein: Double? = 30,
        updatedAt: Int = 1_777_000_100
    ) -> NutritionEntryRow {
        NutritionEntryRow(
            id: id,
            origin: NutritionLogContract.manualOrigin,
            day: day,
            occurredAt: now,
            mealType: "lunch",
            label: "Tofu bowl",
            caloriesKcal: calories,
            proteinG: protein,
            note: "No fabricated macros",
            createdAt: now,
            updatedAt: updatedAt
        )
    }

    private func customExercise(
        id: String = "custom_split_squat",
        name: String = "Split Squat",
        updatedAt: Int = 1_777_000_100
    ) -> StrengthExerciseRow {
        StrengthExerciseRow(
            id: id,
            name: name,
            primaryMuscle: "quadriceps",
            secondaryMusclesJSON: #"["glutes"]"#,
            equipment: "dumbbell",
            movementPattern: "lunge",
            isCustom: true,
            createdAt: now,
            updatedAt: updatedAt
        )
    }

    private func catalogItem(updatedAt: Int = 1_777_000_100) -> NutritionCatalogItemRow {
        NutritionCatalogItemRow(
            id: "meal:tofu-bowl",
            kind: NutritionCatalogContract.mealKind,
            name: "Tofu bowl",
            caloriesKcal: 640,
            proteinG: 30,
            mealType: "lunch",
            source: NutritionCatalogContract.manualSource,
            isSaved: true,
            createdAt: now,
            updatedAt: updatedAt
        )
    }

    private func payload(
        nutritionRows: [NutritionEntryRow]? = nil,
        exercise: StrengthExerciseRow? = nil,
        routineUpdatedAt: Int? = nil,
        sessionUpdatedAt: Int? = nil
    ) throws -> PortableUserData {
        let exercise = exercise ?? customExercise()
        let routine = StrengthRoutineRow(
            id: "routine-1",
            name: "Lower A",
            note: "Controlled tempo",
            createdAt: now,
            updatedAt: routineUpdatedAt ?? now + 100
        )
        let prescription = StrengthRoutineExerciseRow(
            id: "routine-exercise-1",
            routineId: routine.id,
            exerciseId: exercise.id,
            position: 0,
            targetSets: 3,
            targetRepsMin: 8,
            targetRepsMax: 10,
            targetRPE: 8,
            restSeconds: 120,
            createdAt: now,
            updatedAt: routine.updatedAt
        )
        let session = StrengthSessionRow(
            id: "session-1",
            routineId: routine.id,
            name: "Lower A",
            startedAt: now + 1_000,
            endedAt: now + 2_800,
            note: "Felt strong",
            createdAt: now + 1_000,
            updatedAt: sessionUpdatedAt ?? now + 2_800
        )
        let set = StrengthSetRow(
            id: "set-1",
            sessionId: session.id,
            exerciseId: exercise.id,
            exercisePosition: 0,
            setPosition: 0,
            reps: 9,
            loadKg: 24,
            rpe: 8.5,
            restSeconds: 120,
            completedAt: now + 1_300,
            note: "Each side",
            createdAt: now + 1_000,
            updatedAt: session.updatedAt
        )
        return try PortableUserData(
            exportedAt: now + 3_000,
            nutritionEntries: nutritionRows ?? [nutrition()],
            nutritionCatalogItems: [catalogItem()],
            strengthExercises: [exercise],
            strengthRoutines: [routine],
            strengthRoutineExercises: [prescription],
            strengthSessions: [session],
            strengthSets: [set]
        )
    }

    func testReadableJSONRoundTripPreservesNullsAndCompleteStrengthGraph() throws {
        let original = try payload()
        let data = try original.encodedData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains(#""format" : "noop.user-data""#))
        XCTAssertTrue(text.contains(#""schemaVersion" : 2"#))
        XCTAssertTrue(text.contains(#""secondaryMuscles" : ["#))
        XCTAssertFalse(text.contains("secondaryMusclesJSON"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let nutritionEntries = try XCTUnwrap(json["nutritionEntries"] as? [[String: Any]])
        let meal = try XCTUnwrap(nutritionEntries.first)
        XCTAssertNil(meal["caloriesKcal"], "nil meal nutrient must remain absent, not zero")

        let decoded = try PortableUserData.decode(data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.nutritionEntries[0].caloriesKcal)
        XCTAssertEqual(decoded.nutritionEntries[0].proteinG, 30)
        XCTAssertEqual(decoded.nutritionCatalogItems[0].name, "Tofu bowl")
        XCTAssertEqual(decoded.strengthRoutineExercises[0].targetRPE, 8)
        XCTAssertEqual(decoded.strengthSets[0].restSeconds, 120)
        XCTAssertEqual(decoded.strengthSets[0].rpe, 8.5)
    }

    func testDecodesAndroidCompatibleCamelCaseFixture() throws {
        let decoded = try PortableUserData.decode(
            Data(
                """
                {
                  "format": "noop.user-data",
                  "schemaVersion": 1,
                  "exportedAt": 1777003000,
                  "nutritionEntries": [{
                    "id": "android-meal",
                    "deviceId": "nutrition-log",
                    "origin": "manual",
                    "day": "2026-08-22",
                    "occurredAt": 1777000000,
                    "mealType": "lunch",
                    "proteinG": 25,
                    "createdAt": 1777000000,
                    "updatedAt": 1777000100
                  }],
                  "strengthExercises": [],
                  "strengthRoutines": [],
                  "strengthRoutineExercises": [],
                  "strengthSessions": [],
                  "strengthSets": []
                }
                """.utf8
            )
        )

        XCTAssertEqual(decoded.nutritionEntries[0].id, "android-meal")
        XCTAssertEqual(decoded.nutritionEntries[0].proteinG, 25)
        XCTAssertNil(decoded.nutritionEntries[0].caloriesKcal)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertTrue(decoded.nutritionCatalogItems.isEmpty)
    }

    func testRejectsFutureSchemaDuplicateIDsPositionsAndBrokenReferences() throws {
        let valid = try payload()

        var future = valid
        future.schemaVersion = PortableUserData.currentSchemaVersion + 1
        XCTAssertThrowsError(try future.validated()) { error in
            XCTAssertEqual(error as? PortableUserDataError, .unsupportedSchema(3))
        }

        var duplicate = valid
        duplicate.nutritionEntries.append(duplicate.nutritionEntries[0])
        XCTAssertThrowsError(try duplicate.validated()) { error in
            XCTAssertEqual(error as? PortableUserDataError, .duplicateID("nutritionEntries"))
        }

        var duplicatePosition = valid
        var secondSet = duplicatePosition.strengthSets[0]
        secondSet.id = "set-2"
        duplicatePosition.strengthSets.append(secondSet)
        XCTAssertThrowsError(try duplicatePosition.validated()) { error in
            XCTAssertEqual(error as? PortableUserDataError, .duplicatePosition("strengthSets"))
        }

        var broken = valid
        broken.strengthSets[0].exerciseId = "missing"
        XCTAssertThrowsError(try broken.validated()) { error in
            XCTAssertEqual(error as? PortableUserDataError, .brokenRelationship("strengthSets"))
        }
    }

    func testAtomicImportRestoresRowsAndNullableNutritionProjection() async throws {
        let store = try await WhoopStore.inMemory()
        let summary = try await store.importPortableUserData(try payload())

        XCTAssertEqual(summary.nutritionEntries, 1)
        XCTAssertEqual(summary.nutritionCatalogItems, 1)
        XCTAssertEqual(summary.strengthExercises, 1)
        XCTAssertEqual(summary.strengthRoutines, 1)
        XCTAssertEqual(summary.strengthRoutineExercises, 1)
        XCTAssertEqual(summary.strengthSessions, 1)
        XCTAssertEqual(summary.strengthSets, 1)

        let meals = try await store.nutritionEntries(from: "2026-08-22", to: "2026-08-22")
        XCTAssertEqual(meals.map(\.id), ["meal-1"])
        let totals = try await store.nutritionTotals(day: "2026-08-22")
        XCTAssertNil(totals.caloriesKcal)
        XCTAssertEqual(totals.proteinG, 30)
        let calories = try await store.metricSeries(
            deviceId: NutritionLogContract.deviceId,
            key: NutritionLogContract.caloriesKey,
            from: "2026-08-22",
            to: "2026-08-22"
        )
        let protein = try await store.metricSeries(
            deviceId: NutritionLogContract.deviceId,
            key: NutritionLogContract.proteinKey,
            from: "2026-08-22",
            to: "2026-08-22"
        )
        XCTAssertTrue(calories.isEmpty)
        XCTAssertEqual(protein.first?.value, 30)
        let catalog = try await store.nutritionCatalogItems(savedOnly: true)
        XCTAssertEqual(catalog.map(\.id), ["meal:tofu-bowl"])

        let routines = try await store.strengthRoutines(includeArchived: true)
        XCTAssertEqual(routines.first?.routine.id, "routine-1")
        XCTAssertEqual(routines.first?.exercises.first?.targetRepsMax, 10)
        let sessions = try await store.strengthSessions()
        XCTAssertEqual(sessions.first?.session.id, "session-1")
        XCTAssertEqual(sessions.first?.sets.first?.loadKg, 24)
        XCTAssertEqual(sessions.first?.sets.first?.note, "Each side")
    }

    func testImportKeepsNewerLocalEditsAndBuiltInCatalogDefinitions() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertNutritionEntries([
            nutrition(id: "meal-1", calories: 700, protein: 40, updatedAt: now + 500),
        ])
        try await store.upsertStrengthExercises([
            customExercise(name: "Local Split Squat", updatedAt: now + 500),
        ])

        let stale = try payload(
            nutritionRows: [nutrition(calories: 300, protein: 20, updatedAt: now + 200)],
            exercise: customExercise(name: "Old Export Name", updatedAt: now + 200)
        )
        let staleSummary = try await store.importPortableUserData(stale)
        XCTAssertEqual(staleSummary.nutritionEntries, 0)
        XCTAssertEqual(staleSummary.strengthExercises, 0)
        let retainedMeal = try await store.nutritionEntry(id: "meal-1")
        let exercisesAfterStale = try await store.strengthExercises(includeArchived: true)
        XCTAssertEqual(retainedMeal?.caloriesKcal, 700)
        XCTAssertEqual(
            exercisesAfterStale.first { $0.id == "custom_split_squat" }?.name,
            "Local Split Squat"
        )

        let exercisesBeforeBuiltIn = try await store.strengthExercises(includeArchived: true)
        var squat = try XCTUnwrap(
            exercisesBeforeBuiltIn.first { $0.id == "barbell_back_squat" }
        )
        let canonicalName = squat.name
        squat.name = "Forged Built-in"
        squat.updatedAt = now + 9_000
        let builtInPayload = try PortableUserData(
            exportedAt: now + 10_000,
            nutritionEntries: [],
            strengthExercises: [squat],
            strengthRoutines: [],
            strengthRoutineExercises: [],
            strengthSessions: [],
            strengthSets: []
        )
        let builtInSummary = try await store.importPortableUserData(builtInPayload)
        XCTAssertEqual(builtInSummary.strengthExercises, 0)
        let exercisesAfterBuiltIn = try await store.strengthExercises(includeArchived: true)
        XCTAssertEqual(
            exercisesAfterBuiltIn.first { $0.id == "barbell_back_squat" }?.name,
            canonicalName
        )
    }

    func testValidationFailureWritesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        var broken = try payload()
        broken.strengthSets[0].sessionId = "missing-session"

        await XCTAssertThrowsErrorAsync {
            _ = try await store.importPortableUserData(broken)
        }
        let nutrition = try await store.nutritionEntries(
            from: "0000-01-01",
            to: "9999-12-31"
        )
        let routines = try await store.strengthRoutines(includeArchived: true)
        let sessions = try await store.strengthSessions()
        XCTAssertTrue(nutrition.isEmpty)
        XCTAssertTrue(routines.isEmpty)
        XCTAssertTrue(sessions.isEmpty)
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
