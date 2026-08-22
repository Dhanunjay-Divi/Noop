import Foundation
import XCTest
@testable import WhoopStore

final class BackupManifestTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripAndPayloadValidation() throws {
        let database = directory.appendingPathComponent("noop-backup.sqlite")
        try Data("SQLite format 3\0rows".utf8).write(to: database)
        let settings = Data(#"{"settings.schemaVersion":2,"profile.age":34}"#.utf8)
        let settingsURL = directory.appendingPathComponent("settings.json")
        try settings.write(to: settingsURL)

        let manifest = try BackupManifest.make(
            databaseAt: database,
            databaseEntryName: "noop-backup.sqlite",
            settingsData: settings,
            settingsEntryName: "settings.json",
            createdAtEpochMs: 1_787_376_000_000,
            sourcePlatform: .apple,
            databaseEngine: .grdb,
            databaseSchemaVersion: 41,
            settingsSchemaVersion: 2,
            appVersion: "9.2.0"
        )
        let decoded = try BackupManifest.decoded(from: manifest.encoded())

        XCTAssertEqual(decoded, manifest)
        XCTAssertNil(decoded.validationProblem(
            databaseAt: database,
            settingsAt: settingsURL,
            expectedDatabaseEntryName: "noop-backup.sqlite",
            expectedSettingsEntryName: "settings.json",
            currentPlatform: .apple,
            currentDatabaseEngine: .grdb,
            currentDatabaseSchemaVersion: 41
        ))
    }

    func testTamperedPayloadFailsHashValidation() throws {
        let database = directory.appendingPathComponent("noop-backup.sqlite")
        try Data("original".utf8).write(to: database)
        let manifest = try BackupManifest.make(
            databaseAt: database,
            databaseEntryName: "noop-backup.sqlite",
            settingsData: nil,
            settingsEntryName: "settings.json",
            createdAtEpochMs: 1,
            sourcePlatform: .apple,
            databaseEngine: .grdb,
            databaseSchemaVersion: 41,
            settingsSchemaVersion: nil,
            appVersion: nil
        )
        try Data("tampered".utf8).write(to: database)

        XCTAssertTrue(manifest.validationProblem(
            databaseAt: database,
            settingsAt: nil,
            expectedDatabaseEntryName: "noop-backup.sqlite",
            expectedSettingsEntryName: "settings.json",
            currentPlatform: .apple,
            currentDatabaseEngine: .grdb,
            currentDatabaseSchemaVersion: 41
        )?.contains("hash") == true)
    }

    func testWrongPlatformAndFutureSchemaFailBeforeRestore() throws {
        let database = directory.appendingPathComponent("noop-backup.sqlite")
        try Data("payload".utf8).write(to: database)
        let android = try BackupManifest.make(
            databaseAt: database,
            databaseEntryName: "noop-backup.sqlite",
            settingsData: nil,
            settingsEntryName: "settings.json",
            createdAtEpochMs: 1,
            sourcePlatform: .android,
            databaseEngine: .room,
            databaseSchemaVersion: 31,
            settingsSchemaVersion: nil,
            appVersion: nil
        )
        XCTAssertTrue(android.validationProblem(
            databaseAt: database,
            settingsAt: nil,
            expectedDatabaseEntryName: "noop-backup.sqlite",
            expectedSettingsEntryName: "settings.json",
            currentPlatform: .apple,
            currentDatabaseEngine: .grdb,
            currentDatabaseSchemaVersion: 41
        )?.contains("Android") == true)

        let future = try BackupManifest.make(
            databaseAt: database,
            databaseEntryName: "noop-backup.sqlite",
            settingsData: nil,
            settingsEntryName: "settings.json",
            createdAtEpochMs: 1,
            sourcePlatform: .apple,
            databaseEngine: .grdb,
            databaseSchemaVersion: 42,
            settingsSchemaVersion: nil,
            appVersion: nil
        )
        XCTAssertTrue(future.validationProblem(
            databaseAt: database,
            settingsAt: nil,
            expectedDatabaseEntryName: "noop-backup.sqlite",
            expectedSettingsEntryName: "settings.json",
            currentPlatform: .apple,
            currentDatabaseEngine: .grdb,
            currentDatabaseSchemaVersion: 41
        )?.contains("newer") == true)
    }

    func testAndroidShapedJSONDecodesWithTheSharedWireKeys() throws {
        let data = Data(#"{"appVersion":"9.2.0","createdAtEpochMs":1787376000000,"databaseEngine":"room","databaseSchemaVersion":31,"format":"noop-backup","payloads":{"database":{"bytes":123,"path":"noop-backup.sqlite","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"settings":{"bytes":45,"path":"settings.json","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}},"settingsSchemaVersion":2,"sourcePlatform":"android","version":1}"#.utf8)
        let manifest = try BackupManifest.decoded(from: data)

        XCTAssertEqual(manifest.sourcePlatform, .android)
        XCTAssertEqual(manifest.databaseEngine, .room)
        XCTAssertEqual(manifest.databaseSchemaVersion, 31)
        XCTAssertEqual(manifest.settingsSchemaVersion, 2)
        XCTAssertEqual(manifest.payloads.database.path, "noop-backup.sqlite")
        XCTAssertEqual(manifest.payloads.settings?.path, "settings.json")
    }
}
