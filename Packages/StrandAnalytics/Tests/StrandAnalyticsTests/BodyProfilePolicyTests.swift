import XCTest
@testable import StrandAnalytics

final class BodyProfilePolicyTests: XCTestCase {
    func testAdultBmiRequiresConfirmedAdultInputs() throws {
        XCTAssertNil(BodyProfilePolicy.adultBMI(
            age: 30, weightKg: 75, heightCm: 178, measurementsConfirmed: false
        ))
        XCTAssertNil(BodyProfilePolicy.adultBMI(
            age: 19, weightKg: 75, heightCm: 178, measurementsConfirmed: true
        ))
        let bmi = try XCTUnwrap(BodyProfilePolicy.adultBMI(
            age: 30, weightKg: 75, heightCm: 178, measurementsConfirmed: true
        ))
        XCTAssertEqual(bmi, 23.671, accuracy: 0.001)
    }

    func testTargetProgressFailsClosedForUnsupportedScreeningContexts() {
        XCTAssertEqual(
            BodyProfilePolicy.targetAvailability(
                age: 30,
                currentWeightKg: 75,
                heightCm: 178,
                targetWeightKg: 70,
                measurementsConfirmed: false
            ),
            .measurementsUnconfirmed
        )
        XCTAssertEqual(
            BodyProfilePolicy.targetAvailability(
                age: 19,
                currentWeightKg: 75,
                heightCm: 178,
                targetWeightKg: 70,
                measurementsConfirmed: true
            ),
            .adultScreeningUnavailable
        )
        XCTAssertEqual(
            BodyProfilePolicy.targetAvailability(
                age: 30,
                currentWeightKg: 55,
                heightCm: 178,
                targetWeightKg: 60,
                measurementsConfirmed: true
            ),
            .currentWeightNeedsClinicalContext
        )
        XCTAssertEqual(
            BodyProfilePolicy.targetAvailability(
                age: 30,
                currentWeightKg: 75,
                heightCm: 178,
                targetWeightKg: 55,
                measurementsConfirmed: true
            ),
            .targetNeedsClinicalContext
        )
        XCTAssertEqual(
            BodyProfilePolicy.targetAvailability(
                age: 30,
                currentWeightKg: 75,
                heightCm: 178,
                targetWeightKg: 70,
                measurementsConfirmed: true
            ),
            .available
        )
    }

    func testMissingTargetStillChecksWhetherProgressFeatureIsSuitable() {
        XCTAssertEqual(
            BodyProfilePolicy.targetAvailability(
                age: 30,
                currentWeightKg: 75,
                heightCm: 178,
                targetWeightKg: nil,
                measurementsConfirmed: true
            ),
            .available
        )
    }
}
