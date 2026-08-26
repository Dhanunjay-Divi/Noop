import XCTest
@testable import Strand

/// macOS cannot link HealthKit, so these contract assertions protect the iOS-only bridge wiring while
/// the shared importer/policy tests exercise the actual data transformations as executable Swift.
final class AppleHealthAutomaticIngestionContractTests: XCTestCase {
    func testLiveBridgeConsumesAndObservesBothAbsoluteTemperatureTypes() throws {
        let source = try text("StrandiOS/Health/HealthKitBridge.swift")
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: ".bodyTemperature").count - 1, 3)
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: ".appleSleepingWristTemperature").count - 1, 3)
        XCTAssertTrue(source.contains("a.bodyTemperatureC = v"))
        XCTAssertTrue(source.contains("a.wristTemperatureC = v"))
        XCTAssertTrue(source.contains("bodyTemperatureC: a.bodyTemperatureC"))
        XCTAssertTrue(source.contains("wristTemperatureC: a.wristTemperatureC"))
        XCTAssertFalse(source.contains("skinTempDevC: a.bodyTemperatureC"))
    }

    func testNewestHealthKitWeightUsesProvenanceAwareProfileBoundary() throws {
        let source = try text("StrandiOS/Health/HealthKitBridge.swift")
        XCTAssertTrue(source.contains("private func newestBodyMassReading()"))
        XCTAssertTrue(source.contains("measuredAt: sample.endDate"))
        XCTAssertTrue(source.contains("sample.sourceRevision.source"))
        XCTAssertTrue(source.contains("profile.acceptExternalWeight"))
        XCTAssertTrue(source.contains("source: \"apple-health:\\(origin)\""))
    }

    func testAuthorizationAndBackgroundDeliveryClaimsStayExplicitAndQualified() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let view = try text("Strand/Screens/AppleHealthView.swift")
        let app = try text("StrandiOS/App/StrandiOSApp.swift")
        let entitlements = try text("StrandiOS/Resources/NOOP.entitlements")

        XCTAssertTrue(view.contains("Review Health access"))
        let resumeStart = try XCTUnwrap(bridge.range(of: "func refreshAuthIfPreviouslyGranted()"))
        let liveStart = try XCTUnwrap(
            bridge.range(of: "// MARK: - Live delivery", range: resumeStart.upperBound..<bridge.endIndex)
        )
        let resumeBody = String(bridge[resumeStart.lowerBound..<liveStart.lowerBound])
        XCTAssertFalse(resumeBody.contains("requestAuthorization("),
                       "Launch/resume must never open the Health permission sheet.")
        let launchStart = try XCTUnwrap(
            bridge.range(of: "func registerObserversAtLaunchIfPreviouslyRequested")
        )
        let refreshStart = try XCTUnwrap(
            bridge.range(of: "func refreshAuthIfPreviouslyGranted()", range: launchStart.upperBound..<bridge.endIndex)
        )
        let launchBody = String(bridge[launchStart.lowerBound..<refreshStart.lowerBound])
        XCTAssertTrue(launchBody.contains("authorizationRequestedKey"),
                      "Background-launch observers must be gated by NOOP's prior explicit Health action.")
        XCTAssertTrue(launchBody.contains("enableLiveDelivery()"))
        XCTAssertFalse(launchBody.contains("requestAuthorization("),
                       "A HealthKit background launch must never present a permission sheet.")
        XCTAssertTrue(app.contains("bridge.registerObserversAtLaunchIfPreviouslyRequested()"),
                      "Observers must be installed during app initialization, before scenePhase becomes active.")
        XCTAssertTrue(app.contains("await health.foregroundCatchUp()"))
        XCTAssertTrue(view.contains("Apple may deliver Health updates in the background on its schedule"))
        XCTAssertTrue(view.contains("does not include Apple's background-delivery entitlement"))
        XCTAssertFalse(view.contains("Apple Health (Live)"),
                       "System-scheduled HealthKit delivery must not be described as realtime.")
        XCTAssertTrue(entitlements.contains("com.apple.developer.healthkit.background-delivery"))
    }

    func testObserverDeletionsUseDurableAtomicFullTypeReconciliation() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let store = try text("Packages/WhoopStore/Sources/WhoopStore/HealthKitProjectionStore.swift")

        XCTAssertTrue(bridge.contains("whoopStore.healthKitAnchor(sampleType: type.identifier)"))
        XCTAssertTrue(bridge.contains("let deletedCount = deletedObjects?.count ?? 0"))
        XCTAssertTrue(bridge.contains("hasDeletions = hasDeletions || page.deletedCount > 0"))
        XCTAssertTrue(bridge.contains("projectionStart = Date(timeIntervalSince1970: 0)"),
                      "A timestamp-free HKDeletedObject must not be guessed into a recent window.")
        XCTAssertTrue(bridge.contains("whoopStore.reconcileHealthKitProjection("))
        XCTAssertFalse(bridge.contains("min(31, daysBack + 1)"))
        XCTAssertTrue(store.contains("Atomically replace one HealthKit type's complete projection"))
        XCTAssertTrue(store.contains("previous anchor intact"))
        XCTAssertTrue(store.contains("upsertHealthKitAnchor("))
        XCTAssertTrue(store.contains("DELETE FROM workout"))
    }

    func testEveryCommittedHealthProjectionRefreshesTheVisibleReadSpine() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let app = try text("StrandiOS/App/StrandiOSApp.swift")
        let model = try text("Strand/App/AppModel.swift")

        XCTAssertTrue(bridge.contains("var dataProjectionChanged: (() async -> Void)?"))
        XCTAssertGreaterThanOrEqual(
            bridge.components(separatedBy: "await dataProjectionChanged?()").count - 1, 2,
            "Both full imports and anchored observer reconciliations must refresh visible data.")
        XCTAssertTrue(app.contains("bridge.dataProjectionChanged ="))
        XCTAssertTrue(model.contains("func refreshAfterAppleHealthSync"))
        XCTAssertTrue(model.contains("AppleWatchDevice.shouldAutoActivate"))
    }

    func testMenstrualFlowIsBehindDedicatedCycleConsentAndNeverGeneralHealthConsent() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let optIn = try text("Strand/Screens/SkinTempCardsView.swift")

        let generalReadStart = try XCTUnwrap(bridge.range(of: "private var readTypes"))
        let generalReadEnd = try XCTUnwrap(
            bridge.range(of: "private var writeTypes", range: generalReadStart.upperBound..<bridge.endIndex)
        )
        let generalReadBody = String(bridge[generalReadStart.lowerBound..<generalReadEnd.lowerBound])
        XCTAssertFalse(generalReadBody.contains(".menstrualFlow"),
                       "General Apple Health connect must not silently request reproductive-health data.")

        XCTAssertTrue(bridge.contains("func requestCycleDataAccessAndImport() async"))
        XCTAssertTrue(bridge.contains("toShare: Set<HKSampleType>()"),
                      "The cycle request is read-only and must not add reproductive write access.")
        XCTAssertTrue(bridge.contains("read: Set<HKObjectType>([type])"))
        XCTAssertTrue(bridge.contains("cycleImportExplicitlyRequested"))
        XCTAssertTrue(bridge.contains("func disableCycleDataImport() async"))
        XCTAssertTrue(bridge.contains("deleteAllAppleHealthPeriodStarts"))
        XCTAssertTrue(optIn.contains("can ask to read cycle-start dates from Apple Health"),
                      "The in-app rationale must precede the dedicated system prompt.")
        XCTAssertTrue(optIn.contains(
            "Optional flow and symptom details stay private and are used only as context."
        ))
        XCTAssertTrue(optIn.contains(
            "Awareness only: not contraception, not a fertility predictor, not a medical service."
        ))
    }

    func testCoreHealthConsentExcludesOptionalBodyAndHighVolumeScopes() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let view = try text("Strand/Screens/AppleHealthView.swift")

        let coreReadStart = try XCTUnwrap(bridge.range(of: "private static let quantityReadIds"))
        let bodyReadStart = try XCTUnwrap(
            bridge.range(of: "private static let bodyCompositionReadIds",
                         range: coreReadStart.upperBound..<bridge.endIndex)
        )
        let coreReadBody = String(bridge[coreReadStart.lowerBound..<bodyReadStart.lowerBound])
        XCTAssertFalse(coreReadBody.contains(".bodyMass"))
        XCTAssertFalse(coreReadBody.contains(".bodyFatPercentage"))
        XCTAssertFalse(coreReadBody.contains(".leanBodyMass"))
        XCTAssertFalse(coreReadBody.contains(".bodyMassIndex"))

        let coreWriteStart = try XCTUnwrap(bridge.range(of: "private static let quantityWriteIds"))
        let legacyWriteStart = try XCTUnwrap(
            bridge.range(of: "private static let legacyQuantityWriteIds",
                         range: coreWriteStart.upperBound..<bridge.endIndex)
        )
        let coreWriteBody = String(bridge[coreWriteStart.lowerBound..<legacyWriteStart.lowerBound])
        XCTAssertFalse(coreWriteBody.contains(".heartRateVariabilitySDNN"))
        XCTAssertFalse(coreWriteBody.contains(".heartRate"))
        XCTAssertFalse(coreWriteBody.contains(".activeEnergyBurned"))

        XCTAssertTrue(bridge.contains("func requestBodyCompositionAccess() async"))
        XCTAssertTrue(bridge.contains("func requestHighResolutionWritebackAccess() async"))
        XCTAssertTrue(bridge.contains("if bodyCompositionAccessRequested"))
        XCTAssertTrue(bridge.contains("if highResolutionWritebackRequested"))
        XCTAssertTrue(view.contains("Add body composition"))
        XCTAssertTrue(view.contains("Add detailed write-back"))
        XCTAssertTrue(view.contains("separate choices after connecting"))
    }

    func testAmbiguousRMSSDIsNeverWrittenAsHealthKitSDNN() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let view = try text("Strand/Screens/AppleHealthView.swift")

        let vitalsStart = try XCTUnwrap(bridge.range(of: "private func writeVitals("))
        let sleepStart = try XCTUnwrap(
            bridge.range(of: "private func writeSleep(", range: vitalsStart.upperBound..<bridge.endIndex)
        )
        let vitalsBody = String(bridge[vitalsStart.lowerBound..<sleepStart.lowerBound])
        XCTAssertFalse(vitalsBody.contains("add(.heartRateVariabilitySDNN"),
                       "The mixed avgHrv column must never be emitted as Apple SDNN.")
        XCTAssertTrue(vitalsBody.contains("removeLegacyMislabelledHrvIfPossible"))
        XCTAssertTrue(bridge.contains("HKQuery.predicateForObjects(from: HKSource.default())"),
                      "Legacy cleanup must remain scoped to samples authored by NOOP.")
        XCTAssertTrue(view.contains("HRV is read-only"))
        XCTAssertTrue(view.contains("strap RMSSD as Apple Health SDNN"))

        let shortcut = try text("Strand/Data/ShortcutHealthExport.swift")
        XCTAssertTrue(shortcut.contains("return \"\\(hr),,,\\(timestamp"),
                      "The HealthKit-free Shortcut path must leave its legacy HRV and Steps fields empty.")
        XCTAssertFalse(shortcut.contains("let steps = try await source.stepSamples"),
                       "Unvalidated @57 motion-counter values must never be read for Apple Health export.")
    }

    func testWritebackDoesNotHideLocalStoreReadFailuresOrOverclaimCloudIsolation() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let view = try text("Strand/Screens/AppleHealthView.swift")

        let writebackStart = try XCTUnwrap(bridge.range(of: "private func writeBack("))
        let helpersEnd = try XCTUnwrap(
            bridge.range(of: "private struct DayAgg", range: writebackStart.upperBound..<bridge.endIndex)
        )
        let writebackBody = String(bridge[writebackStart.lowerBound..<helpersEnd.lowerBound])
        XCTAssertFalse(writebackBody.contains("try? await whoopStore"),
                       "A failed local read must fail the round trip instead of becoming empty data.")
        XCTAssertTrue(view.contains("NOOP does not upload this data to a NOOP-operated cloud"))
        XCTAssertTrue(view.contains("follow your Apple Health and iCloud settings"))
    }

    func testSleepPublicationMigrationPreflightsACompleteThrowingSnapshot() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let repository = try text("Strand/Data/Repository.swift")
        let writebackStart = try XCTUnwrap(bridge.range(of: "private func writeBack("))
        let vitalsStart = try XCTUnwrap(
            bridge.range(of: "private func writeVitals(",
                         range: writebackStart.upperBound..<bridge.endIndex))
        let writebackBody = String(bridge[writebackStart.lowerBound..<vitalsStart.lowerBound])

        XCTAssertTrue(writebackBody.contains("try await repo.sleepWritebackSnapshot("))
        XCTAssertFalse(writebackBody.contains("repo.allSleepSessions("))
        XCTAssertFalse(writebackBody.contains("repo.detailedSleepStageEvidence("))
        let snapshot = try XCTUnwrap(writebackBody.range(of: "sleepWritebackSnapshot("))
        let mutation = try XCTUnwrap(writebackBody.range(of: "try await writeSleep("))
        XCTAssertLessThan(snapshot.lowerBound, mutation.lowerBound)

        XCTAssertTrue(repository.contains("func sleepWritebackSnapshot("))
        XCTAssertTrue(repository.contains("throw RepositoryReadError.incompleteSleepSnapshot"))
        XCTAssertTrue(repository.contains("store.sleepSessionReadSnapshot("))
        XCTAssertTrue(repository.contains("snapshot.requestedByDevice"))
    }

    func testSleepPublicationMigrationReplacesBatchesBeforeOrphanCleanup() throws {
        let bridge = try text("StrandiOS/Health/HealthKitBridge.swift")
        let sleepStart = try XCTUnwrap(bridge.range(of: "private func writeSleep("))
        let markerStart = try XCTUnwrap(
            bridge.range(
                of: "private var sleepStagePublicationMigrationKey",
                range: sleepStart.upperBound..<bridge.endIndex))
        let body = String(bridge[sleepStart.lowerBound..<markerStart.lowerBound])

        XCTAssertFalse(
            body.contains(
                "predicate: HKQuery.predicateForObjects(from: HKSource.default()))"),
            "A migration must never delete the complete authored sleep history before saving.")
        let batchSave = try XCTUnwrap(body.range(of: "try await store.save("))
        let orphanRead = try XCTUnwrap(body.range(of: "appAuthoredSleepSamples("))
        XCTAssertLessThan(batchSave.lowerBound, orphanRead.lowerBound)
        XCTAssertTrue(body.contains("try await store.delete(Array(stale["))
    }

    private func text(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
