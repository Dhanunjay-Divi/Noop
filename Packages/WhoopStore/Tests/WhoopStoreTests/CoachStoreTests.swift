import XCTest
@testable import WhoopStore

final class CoachStoreTests: XCTestCase {
    func testTranscriptIsDurableOrderedAndBounded() async throws {
        let store = try await WhoopStore.inMemory()
        for index in 0..<45 {
            try await store.appendCoachMessage(CoachMessageRow(
                id: String(format: "message-%02d", index),
                createdAt: Int64(1_000 + index),
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                text: "turn \(index)"
            ))
        }

        let rows = try await store.coachMessages()
        XCTAssertEqual(rows.count, CoachStoreContract.maxMessages)
        XCTAssertEqual(rows.first?.id, "message-05")
        XCTAssertEqual(rows.last?.id, "message-44")
        XCTAssertEqual(rows.map(\.createdAt), rows.map(\.createdAt).sorted())

        let cleared = try await store.clearCoachMessages()
        let afterClear = try await store.coachMessages()
        XCTAssertEqual(cleared, 40)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testMemoryCanBeEditedDisabledAndDeleted() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertCoachMemory(CoachMemoryRow(
            id: "goal",
            text: "Training for a 10K",
            enabled: true,
            createdAt: 1_000,
            updatedAt: 1_000
        ))
        try await store.upsertCoachMemory(CoachMemoryRow(
            id: "injury",
            text: "Avoid running advice this week",
            enabled: false,
            createdAt: 1_100,
            updatedAt: 1_100
        ))

        let all = try await store.coachMemories()
        let enabled = try await store.coachMemories(includeDisabled: false)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(enabled.map(\.id), ["goal"])

        try await store.upsertCoachMemory(CoachMemoryRow(
            id: "goal",
            text: "Training for a half marathon",
            enabled: false,
            createdAt: 1_000,
            updatedAt: 1_200
        ))
        let afterEdit = try await store.coachMemories()
        let edited = try XCTUnwrap(afterEdit.first { $0.id == "goal" })
        XCTAssertEqual(edited.text, "Training for a half marathon")
        XCTAssertFalse(edited.enabled)
        XCTAssertEqual(edited.createdAt, 1_000)

        let firstDelete = try await store.deleteCoachMemory(id: "injury")
        let secondDelete = try await store.deleteCoachMemory(id: "injury")
        XCTAssertTrue(firstDelete)
        XCTAssertFalse(secondDelete)
    }

    func testContractRejectsInvalidRowsAndTrimsText() throws {
        XCTAssertThrowsError(try CoachStoreContract.validated(CoachMessageRow(
            id: "message",
            createdAt: 1,
            role: "system",
            text: "hidden prompt"
        )))
        XCTAssertThrowsError(try CoachStoreContract.validated(CoachMemoryRow(
            id: "memory",
            text: "",
            enabled: true,
            createdAt: 1,
            updatedAt: 1
        )))
        let row = try CoachStoreContract.validated(CoachMessageRow(
            id: " message ",
            createdAt: 1,
            role: "user",
            text: " hello "
        ))
        XCTAssertEqual(row.id, "message")
        XCTAssertEqual(row.text, "hello")
    }
}
