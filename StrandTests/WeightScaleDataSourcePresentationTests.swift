import XCTest
import WhoopProtocol
@testable import Strand

final class WeightScaleDataSourcePresentationTests: XCTestCase {
    func testUnknownMultiUserSlotCannotDisplayBMI() {
        let measurement = makeMeasurement(userID: 0xFF)

        XCTAssertNil(displayedBMI(
            measurement,
            selectedUserID: 0xFF
        ))
    }

    func testUnassignedMultiUserSlotCannotDisplayBMI() {
        let measurement = makeMeasurement(userID: 7)

        XCTAssertNil(displayedBMI(
            measurement,
            selectedUserID: nil
        ))
        XCTAssertNil(displayedBMI(
            measurement,
            selectedUserID: 3
        ))
    }

    func testAssignedMultiUserAndSingleUserReadingsCanDisplayBMI() {
        let assigned = makeMeasurement(userID: 7)
        let singleUser = makeMeasurement(userID: nil)

        XCTAssertEqual(displayedBMI(assigned, selectedUserID: 7), 23.7)
        XCTAssertEqual(displayedBMI(singleUser, selectedUserID: nil), 23.7)
    }

    func testAssignmentDoesNotBypassAdultProfileGate() {
        let measurement = makeMeasurement(userID: 7)

        XCTAssertNil(displayedBMI(
            measurement,
            selectedUserID: 7,
            age: 19
        ))
        XCTAssertNil(displayedBMI(
            measurement,
            selectedUserID: 7,
            heightConfirmed: false
        ))
    }

    func testCardPassesTheSourceAssignmentDecisionIntoPresentationPolicy() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Strand/Screens/DataSourcesView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "mayUpdateProfile: source.mayUpdateProfile(for: capture.measurement)"
        ))
    }

    private func displayedBMI(
        _ measurement: WeightScaleMeasurement,
        selectedUserID: UInt8?,
        age: Int = 30,
        heightConfirmed: Bool = true
    ) -> Double? {
        WeightScaleDataSourcePresentation.displayedBMI(
            measurement: measurement,
            mayUpdateProfile: WeightScaleProfileUserPolicy.allows(
                measurementUserID: measurement.userID,
                selectedUserID: selectedUserID
            ),
            age: age,
            heightCm: 178,
            ageConfirmed: true,
            heightConfirmed: heightConfirmed
        )
    }

    private func makeMeasurement(userID: UInt8?) -> WeightScaleMeasurement {
        WeightScaleMeasurement(
            weightKg: 75,
            timestamp: nil,
            userID: userID,
            bmi: 23.7,
            heightCm: 178,
            unit: .si
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
