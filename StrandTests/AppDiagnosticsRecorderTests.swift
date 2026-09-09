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

    func testFreshnessBucketsDoNotRetainHealthTimestamps() {
        XCTAssertEqual(AppDiagnosticsRecorder.freshnessBucket(ageSeconds: nil), "missing")
        XCTAssertEqual(AppDiagnosticsRecorder.freshnessBucket(ageSeconds: -120), "future_clock")
        XCTAssertEqual(AppDiagnosticsRecorder.freshnessBucket(ageSeconds: 30), "under_2m")
        XCTAssertEqual(AppDiagnosticsRecorder.freshnessBucket(ageSeconds: 300), "2m_to_15m")
        XCTAssertEqual(AppDiagnosticsRecorder.freshnessBucket(ageSeconds: 1_800), "15m_to_2h")
        XCTAssertEqual(AppDiagnosticsRecorder.freshnessBucket(ageSeconds: 8_000), "over_2h")
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

    func testSensitiveFieldNamesAreDroppedAtRecorderBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-app-redaction-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = AppDiagnosticsRecorder(directory: directory)
        recorder.start(subscribeToSystem: false)
        recorder.record(
            "test.redaction",
            fields: [
                "route": "/v1/managed/chunks/{chunk_id}",
                "authorization": "Bearer private-value",
                "phone_number": "+15555550123",
                "installation_id": "noop-private-installation",
                "incident_id": UUID().uuidString,
                "request_url": "https://private.example/signed",
                "server_request_id": String(repeating: "b", count: 32),
                "user_note": "private user text",
            ]
        )

        let current = try XCTUnwrap(recorder.diagnosticEntries().first {
            $0.name == AppDiagnosticsRecorder.currentSessionEntryName
        })
        let text = try XCTUnwrap(String(data: current.data, encoding: .utf8))
        let event = try XCTUnwrap(text.split(separator: "\n").last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any]
        )
        let fields = try XCTUnwrap(object["fields"] as? [String: String])
        XCTAssertEqual(fields["route"], "/v1/managed/chunks/{chunk_id}")
        XCTAssertEqual(fields["redacted_fields"], "7")
        XCTAssertFalse(text.contains("private-value"))
        XCTAssertFalse(text.contains("15555550123"))
        XCTAssertFalse(text.contains("noop-private-installation"))
        XCTAssertFalse(text.contains("incident_id"))
        XCTAssertFalse(text.contains("private.example"))
        XCTAssertFalse(text.contains(String(repeating: "b", count: 32)))
        XCTAssertFalse(text.contains("private user text"))
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
        live.append(log: "private health evidence bpm=137 hrv=42")
        let storage = TestBundleMeta.Storage(
            dbBytes: 123,
            rows: ["hr": 456],
            rawCaptureBytes: 789,
            latestHrUnix: 1_788_000_123
        )
        let entries = TestBundleAssembler.assemble(
            profile: .master,
            live: live,
            storage: storage,
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
        XCTAssertFalse(entries.contains { String(decoding: $0.data, as: UTF8.self).contains("bpm=137") })
        XCTAssertFalse(entries.contains { String(decoding: $0.data, as: UTF8.self).contains("hrv=42") })
        XCTAssertFalse(entries.contains { String(decoding: $0.data, as: UTF8.self).contains("1788000123") })

        let metaEntry = try XCTUnwrap(entries.first { $0.name == "meta.json" })
        let meta = try JSONDecoder().decode(TestBundleMeta.self, from: metaEntry.data)
        XCTAssertEqual(meta.testProfile, "app-hang")
        XCTAssertEqual(meta.source, ["App runtime diagnostics"])
        XCTAssertTrue(meta.questionnaire.isEmpty)
        XCTAssertTrue(meta.captureCheck.isEmpty)
        XCTAssertNil(meta.profileStartedAt)
        XCTAssertNil(meta.storage.latestHrUnix)
    }

    @MainActor
    func testAppHangBundleIncludesOnlyExplicitReviewedContext() throws {
        let screenshot = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let entries = TestBundleAssembler.assemble(
            profile: .master,
            live: LiveState(),
            purpose: .appHang,
            runtimeDiagnostics: [],
            userNote: "Health froze near WHOOP 4C1594026",
            appReportScreenshotPNG: screenshot
        )

        let note = try XCTUnwrap(entries.first { $0.name == "user-note.txt" })
        let noteText = try XCTUnwrap(String(data: note.data, encoding: .utf8))
        XCTAssertTrue(noteText.contains("Health froze"))
        XCTAssertFalse(noteText.contains("4C1594026"))
        XCTAssertEqual(
            entries.first { $0.name == DisplayScreenshot.bundleName }?.data,
            screenshot
        )

        let preview = ReportReviewGate(entries: entries).previewText
        XCTAssertTrue(preview.contains("Health froze"))
        XCTAssertTrue(preview.contains(DisplayScreenshot.bundleName))
    }
}
