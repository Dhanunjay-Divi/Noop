import XCTest
@testable import Strand

@MainActor
final class ProfileExternalWeightTests: XCTestCase {
    private var suiteNames: [String] = []

    func testDisplayNameDefaultsNormalizesAndStaysLocal() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        XCTAssertEqual(profile.displayName, "Noop")

        profile.setDisplayName("  Avery\n  Quinn  ")
        XCTAssertEqual(profile.displayName, "Avery Quinn")
        XCTAssertEqual(defaults.string(forKey: "profile.displayName"), "Avery Quinn")

        profile.setDisplayName("   ")
        XCTAssertEqual(profile.displayName, "Noop")
        XCTAssertNil(defaults.object(forKey: "profile.displayName"))

        profile.setDisplayName(String(repeating: " ", count: 40) + "Avery " + String(repeating: "Q", count: 40))
        XCTAssertEqual(profile.displayName, "Avery " + String(repeating: "Q", count: 26))

        let emoji = "\u{1F600}"
        profile.setDisplayName(String(repeating: "A", count: 31) + emoji + "B")
        XCTAssertEqual(profile.displayName, String(repeating: "A", count: 31) + emoji)
    }

    func testOptionalTargetWeightPersistsClearsAndRejectsInvalidValues() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        XCTAssertNil(profile.targetWeightKg)

        profile.setTargetWeightKg(68.5)
        XCTAssertEqual(profile.targetWeightKg, 68.5)
        XCTAssertEqual(
            ProfileStore(defaults: defaults).targetWeightKg,
            68.5,
            "The user-selected target must survive a relaunch"
        )

        profile.setTargetWeightKg(.nan)
        profile.setTargetWeightKg(500)
        XCTAssertEqual(profile.targetWeightKg, 68.5, "Invalid input must not replace a valid target")

        profile.setTargetWeightKg(nil)
        XCTAssertNil(profile.targetWeightKg)
        XCTAssertNil(ProfileStore(defaults: defaults).targetWeightKg)
        XCTAssertNil(defaults.object(forKey: "profile.targetWeightKg"))
    }

    func testBodySeedsRemainUnconfirmedUntilAcceptedOrEdited() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        XCTAssertFalse(profile.weightInputConfirmed)
        XCTAssertFalse(profile.heightInputConfirmed)
        XCTAssertFalse(profile.bodyInputsConfirmed)
        XCTAssertNil(profile.adultBMI)

        profile.confirmAgeInput()
        profile.weightKg = 75
        XCTAssertTrue(profile.weightInputConfirmed)
        XCTAssertFalse(profile.bodyInputsConfirmed)
        profile.heightCm = 178
        XCTAssertTrue(profile.bodyInputsConfirmed)
        XCTAssertEqual(try XCTUnwrap(profile.adultBMI), 23.671, accuracy: 0.001)
    }

    func testBodyConfirmationCanAcceptVisibleOnboardingValues() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        profile.confirmAgeInput()
        profile.confirmBodyInputs()
        XCTAssertTrue(profile.bodyInputsConfirmed)
        XCTAssertNotNil(profile.adultBMI)
    }

    func testAdultBmiAndTargetProgressRemainUnavailableBelowAgeTwenty() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        profile.weightKg = 75
        profile.heightCm = 178
        profile.dateOfBirth = ProfileStore.dateOfBirth(forAge: 19)
        XCTAssertNil(profile.adultBMI)
        XCTAssertEqual(
            profile.targetWeightAvailability(targetWeightKg: 70),
            .adultScreeningUnavailable
        )
    }

    func testExternalWeightConfirmsOnlyWeightInput() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        let now = Date()
        XCTAssertTrue(profile.acceptExternalWeight(
            weightKg: 78,
            measuredAt: now,
            source: "apple-health",
            receivedAt: now
        ))
        XCTAssertTrue(profile.weightInputConfirmed)
        XCTAssertFalse(profile.heightInputConfirmed)
        XCTAssertNil(profile.adultBMI)
    }

    func testAcceptsOnlyNewerValidExternalWeightAndPersistsProvenance() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        let received = Date(timeIntervalSince1970: 2_000_000_000)
        let first = received.addingTimeInterval(-120)

        XCTAssertTrue(profile.acceptExternalWeight(weightKg: 78.4, measuredAt: first,
                                                   source: "bluetooth-sig-wss:scale-a",
                                                   receivedAt: received))
        XCTAssertEqual(profile.weightKg, 78.4, accuracy: 0.000_001)
        XCTAssertEqual(profile.externalWeightProvenance,
                       ExternalWeightProvenance(measuredAt: first, source: "bluetooth-sig-wss:scale-a"))

        XCTAssertFalse(profile.acceptExternalWeight(weightKg: 77.0,
                                                    measuredAt: first.addingTimeInterval(-1),
                                                    source: "apple-health", receivedAt: received))
        XCTAssertEqual(profile.weightKg, 78.4, accuracy: 0.000_001)
        XCTAssertFalse(profile.acceptExternalWeight(weightKg: .nan, measuredAt: received,
                                                    source: "apple-health", receivedAt: received))
        XCTAssertFalse(profile.acceptExternalWeight(weightKg: 79,
                                                    measuredAt: received.addingTimeInterval(301),
                                                    source: "apple-health", receivedAt: received))
    }

    func testManualEditWinsUntilAReadingTakenAfterTheEdit() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        let now = Date()
        XCTAssertTrue(profile.acceptExternalWeight(weightKg: 75,
                                                   measuredAt: now.addingTimeInterval(-60),
                                                   source: "apple-health", receivedAt: now))

        profile.weightKg = 82 // direct profile edit records a manual precedence timestamp
        XCTAssertFalse(profile.acceptExternalWeight(weightKg: 76,
                                                    measuredAt: now.addingTimeInterval(-1),
                                                    source: "apple-health", receivedAt: now))
        XCTAssertEqual(profile.weightKg, 82, accuracy: 0.000_001)

        let later = Date().addingTimeInterval(2)
        XCTAssertTrue(profile.acceptExternalWeight(weightKg: 81.2, measuredAt: later,
                                                   source: "bluetooth-sig-wss:scale-a",
                                                   receivedAt: later))
        XCTAssertEqual(profile.weightKg, 81.2, accuracy: 0.000_001)
    }

    func testFirstExternalReadingCanBootstrapAfterInitialManualProfileEntry() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        profile.weightKg = 90
        let received = Date()
        let historicalLatest = received.addingTimeInterval(-86_400)
        XCTAssertTrue(profile.acceptExternalWeight(weightKg: 88.5,
                                                   measuredAt: historicalLatest,
                                                   source: "apple-health", receivedAt: received))
        XCTAssertEqual(profile.weightKg, 88.5, accuracy: 0.000_001)
    }

    func testDeletionReconcileRollsBackWithinSameSourceAndRestoresFallbackWhenEmpty() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        profile.weightKg = 84
        let now = Date()
        XCTAssertTrue(profile.acceptExternalWeight(weightKg: 82,
                                                   measuredAt: now.addingTimeInterval(-60),
                                                   source: "apple-health:new-scale",
                                                   receivedAt: now))

        XCTAssertTrue(profile.reconcileExternalWeight(weightKg: 83,
                                                      measuredAt: now.addingTimeInterval(-86_400),
                                                      source: "apple-health:old-scale",
                                                      receivedAt: now))
        XCTAssertEqual(profile.weightKg, 83, accuracy: 0.000_001)
        XCTAssertTrue(profile.reconcileExternalWeight(weightKg: nil, measuredAt: nil,
                                                      source: "apple-health", receivedAt: now))
        XCTAssertEqual(profile.weightKg, 84, accuracy: 0.000_001)
        XCTAssertNil(profile.externalWeightProvenance)
    }

    func testDeletionReconcileNeverOverridesManualEditOrAnotherSource() throws {
        let defaults = try freshDefaults()
        let profile = ProfileStore(defaults: defaults)
        let now = Date()
        XCTAssertTrue(profile.acceptExternalWeight(weightKg: 78,
                                                   measuredAt: now.addingTimeInterval(-60),
                                                   source: "apple-health:watch",
                                                   receivedAt: now))
        profile.weightKg = 91
        XCTAssertTrue(profile.reconcileExternalWeight(weightKg: nil, measuredAt: nil,
                                                      source: "apple-health", receivedAt: now))
        XCTAssertEqual(profile.weightKg, 91, accuracy: 0.000_001)
        XCTAssertNil(profile.externalWeightProvenance)

        let later = now.addingTimeInterval(2)
        XCTAssertTrue(profile.acceptExternalWeight(weightKg: 80, measuredAt: later,
                                                   source: "bluetooth-sig-wss:scale",
                                                   receivedAt: later))
        XCTAssertFalse(profile.reconcileExternalWeight(weightKg: nil, measuredAt: nil,
                                                       source: "apple-health", receivedAt: later))
        XCTAssertEqual(profile.weightKg, 80, accuracy: 0.000_001)
        XCTAssertEqual(profile.externalWeightProvenance?.source, "bluetooth-sig-wss:scale")
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "ProfileExternalWeightTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw XCTSkip("Couldn't create suite-scoped UserDefaults")
        }
        defaults.removePersistentDomain(forName: name)
        suiteNames.append(name)
        return defaults
    }

    override func tearDown() {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }
}
