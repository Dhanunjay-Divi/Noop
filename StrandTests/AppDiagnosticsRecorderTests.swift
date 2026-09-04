import XCTest
@testable import Strand

final class AppDiagnosticsRecorderTests: XCTestCase {
    func testScrollHitchAccumulatorClassifiesFramesWithoutRetainingSamples() {
        var accumulator = ScrollHitchAccumulator()

        XCTAssertEqual(accumulator.record(durationMs: 16), .regular)
        XCTAssertEqual(accumulator.record(durationMs: 50), .hitch)
        XCTAssertEqual(accumulator.record(durationMs: 149), .hitch)
        XCTAssertEqual(accumulator.record(durationMs: 150), .severe)
        XCTAssertNil(accumulator.record(durationMs: 5_001))

        XCTAssertEqual(accumulator.frameCount, 4)
        XCTAssertEqual(accumulator.hitchCount, 3)
        XCTAssertEqual(accumulator.severeHitchCount, 1)
        XCTAssertEqual(accumulator.worstDurationMs, 150)
        XCTAssertEqual(accumulator.meanDurationMs, 91.25, accuracy: 0.001)
    }

    func testBoundedTailKeepsNewestCompleteJSONLines() throws {
        let lines = (0..<200).map {
            "{\"schema\":1,\"event\":\"sample\",\"fields\":{\"index\":\"\($0)\"}}\n"
        }.joined()

        let bounded = AppDiagnosticsRecorder.boundedJSONLTail(
            Data(lines.utf8),
            maxBytes: 1_024
        )
        XCTAssertLessThanOrEqual(bounded.count, 1_024)

        let text = try XCTUnwrap(String(data: bounded, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("{\"schema\":1,\"event\":\"log.trimmed\""))
        XCTAssertTrue(text.contains("\"index\":\"199\""))
        XCTAssertFalse(text.contains("\"index\":\"0\""))

        for line in text.split(separator: "\n") {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(line.utf8)),
                "retention must never leave a partial JSONL record"
            )
        }
    }

    func testSessionRotationExportsCurrentAndPreviousWithoutArbitraryFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-app-diagnostics-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var first: AppDiagnosticsRecorder? = AppDiagnosticsRecorder(directory: directory)
        first?.start(subscribeToSystem: false)
        first?.record("test.first_session")
        XCTAssertTrue(
            first?.diagnosticEntries().contains {
                $0.name == AppDiagnosticsRecorder.currentSessionEntryName
                    && String(data: $0.data, encoding: .utf8)?.contains("test.first_session") == true
            } == true
        )
        first = nil

        let ignored = directory.appendingPathComponent("private-health-data.sqlite")
        try Data("must not export".utf8).write(to: ignored)

        let second = AppDiagnosticsRecorder(directory: directory)
        second.start(subscribeToSystem: false)
        second.record("test.second_session")
        let entries = second.diagnosticEntries()

        let current = try XCTUnwrap(entries.first {
            $0.name == AppDiagnosticsRecorder.currentSessionEntryName
        })
        let previous = try XCTUnwrap(entries.first {
            $0.name == AppDiagnosticsRecorder.previousSessionEntryName
        })
        XCTAssertTrue(String(data: current.data, encoding: .utf8)?.contains("test.second_session") == true)
        XCTAssertTrue(String(data: previous.data, encoding: .utf8)?.contains("test.first_session") == true)
        XCTAssertFalse(entries.contains { $0.name == ignored.lastPathComponent })
    }

    func testOperationMarkersCarryMatchingBoundedIDAndDuration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-app-operation-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = AppDiagnosticsRecorder(directory: directory)
        recorder.start(subscribeToSystem: false)
        let token = recorder.beginOperation("repository.refresh")
        recorder.endOperation(token, outcome: "published")

        let current = try XCTUnwrap(recorder.diagnosticEntries().first {
            $0.name == AppDiagnosticsRecorder.currentSessionEntryName
        })
        let text = try XCTUnwrap(String(data: current.data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"event\":\"operation.begin\""))
        XCTAssertTrue(text.contains("\"event\":\"operation.end\""))
        XCTAssertTrue(text.contains("\"operation_id\":\"op_1\""))
        XCTAssertTrue(text.contains("\"outcome\":\"published\""))
        XCTAssertTrue(text.contains("\"duration_ms\":"))
    }

    func testAsyncSnapshotDrainsPreviouslyQueuedBreadcrumbs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-app-async-snapshot-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = AppDiagnosticsRecorder(directory: directory)
        recorder.start(subscribeToSystem: false)
        recorder.record("test.before_async_snapshot")

        let entries = await recorder.diagnosticEntriesAsync()
        let current = try XCTUnwrap(entries.first {
            $0.name == AppDiagnosticsRecorder.currentSessionEntryName
        })
        XCTAssertTrue(
            String(data: current.data, encoding: .utf8)?
                .contains("test.before_async_snapshot") == true
        )
    }

    @MainActor
    func testAppHangBundleExcludesResearchDataAndQuestionnaire() throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-private-raw-\(UUID()).jsonl")
        try Data("{\"raw\":\"must-not-ship\"}\n".utf8).write(to: capture)
        defer { try? FileManager.default.removeItem(at: capture) }

        let originalAnswers = TestCentre.answers(.master)
        TestCentre.setAnswers(["freeform": "must-not-ship"], for: .master)
        defer { TestCentre.setAnswers(originalAnswers, for: .master) }

        let live = LiveState()
        live.puffinCaptureURL = capture
        let entries = TestBundleAssembler.assemble(
            profile: .master,
            live: live,
            purpose: .appHang
        )
        let names = Set(entries.map(\.name))

        XCTAssertTrue(names.contains("report.txt"))
        XCTAssertTrue(names.contains("meta.json"))
        XCTAssertFalse(names.contains("raw-capture.jsonl"))
        XCTAssertFalse(names.contains("screenshot.png"))
        XCTAssertFalse(names.contains { $0.hasPrefix("oura-") })
        XCTAssertFalse(names.contains { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") })
        XCTAssertFalse(entries.contains { String(decoding: $0.data, as: UTF8.self).contains("must-not-ship") })

        let metaEntry = try XCTUnwrap(entries.first { $0.name == "meta.json" })
        let meta = try JSONDecoder().decode(TestBundleMeta.self, from: metaEntry.data)
        XCTAssertEqual(meta.testProfile, "app-hang")
        XCTAssertTrue(meta.questionnaire.isEmpty)
        XCTAssertTrue(meta.captureCheck.isEmpty)
        XCTAssertNil(meta.profileStartedAt)
    }
}
