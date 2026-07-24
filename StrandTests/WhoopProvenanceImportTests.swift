import XCTest
import Foundation
import WhoopStore
@testable import Strand

final class WhoopProvenanceImportTests: XCTestCase {
    func testNoopApproximateRowsNeverEnterOfficialReferenceNamespace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-whoop-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let csv = """
        Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Day Strain,Sleep performance %,Source
        2026-01-01 00:00:00,2026-01-01 23:59:00,UTC+00:00,60,10,70,noop (APPROXIMATE)
        2026-01-02 00:00:00,2026-01-02 23:59:00,UTC+00:00,80,12,90,import
        2026-01-03 00:00:00,2026-01-03 23:59:00,UTC+00:00,99,20,99,other-app
        """
        try csv.write(
            to: directory.appendingPathComponent("physiological_cycles.csv"),
            atomically: true,
            encoding: .utf8)

        let store = try await WhoopStore.inMemory()
        let deviceId = "test-whoop-\(UUID().uuidString)"
        defer { WhoopReferenceImportManifest().remove(deviceId: deviceId) }
        _ = try await WhoopImporter.importExport(
            url: directory, into: store, deviceId: deviceId)

        let official = try await store.dailyMetrics(
            deviceId: deviceId, from: "2026-01-01", to: "2026-01-03")
        let local = try await store.dailyMetrics(
            deviceId: deviceId + "-noop", from: "2026-01-01", to: "2026-01-03")

        XCTAssertEqual(official.map(\.day), ["2026-01-02"])
        XCTAssertEqual(official.first?.recovery, 80)
        XCTAssertEqual(local.map(\.day), ["2026-01-01"])
        XCTAssertEqual(local.first?.recovery, 60)

        let officialSeries = try await store.metricSeries(
            deviceId: deviceId, key: "recovery", from: "2026-01-01", to: "2026-01-03")
        let localSeries = try await store.metricSeries(
            deviceId: deviceId + "-noop", key: "recovery",
            from: "2026-01-01", to: "2026-01-03")
        XCTAssertEqual(officialSeries.map(\.day), ["2026-01-02"])
        XCTAssertEqual(localSeries.map(\.day), ["2026-01-01"])
        XCTAssertFalse((official + local).contains { $0.day == "2026-01-03" })
        XCTAssertEqual(
            WhoopReferenceImportManifest().verifiedDays(
                deviceId: deviceId,
                schemaRevision: WhoopImporter.schemaRevision,
                metricKey: "recovery"),
            Set(["2026-01-02"]))
        XCTAssertTrue(
            WhoopReferenceImportManifest().verifiedDays(
                deviceId: deviceId,
                schemaRevision: WhoopImporter.schemaRevision,
                metricKey: "hrv").isEmpty)
    }

    func testCalibrationSchemaRevisionIsDerivedFromImporterVersion() {
        XCTAssertEqual(
            WhoopImporter.schemaRevision,
            "whoop-csv-import-v\(WhoopImporter.importerVersion)")
    }

    func testReferenceManifestIsMetricAndImporterRevisionScoped() throws {
        let suite = "noop-reference-manifest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = WhoopReferenceImportManifest(
            defaults: defaults, namespace: "test.referenceManifest")
        manifest.recordOfficialMetrics(
            [
                (day: "2026-01-01", metricKey: "recovery"),
                (day: "2026-01-02", metricKey: "strain"),
                (day: "not-a-day", metricKey: "recovery"),
            ],
            deviceId: "my-whoop",
            schemaRevision: "import-v2")

        XCTAssertEqual(
            manifest.verifiedDays(
                deviceId: "my-whoop", schemaRevision: "import-v2", metricKey: "recovery"),
            Set(["2026-01-01"]))
        XCTAssertEqual(
            manifest.verifiedDays(
                deviceId: "my-whoop", schemaRevision: "import-v2", metricKey: "strain"),
            Set(["2026-01-02"]))
        XCTAssertTrue(
            manifest.verifiedDays(
                deviceId: "my-whoop", schemaRevision: "import-v1", metricKey: "recovery").isEmpty)
    }
}
