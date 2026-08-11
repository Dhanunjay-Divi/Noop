import XCTest
@testable import StrandAnalytics

final class WearableCapabilityCatalogTests: XCTestCase {
    func testCatalogContainsEverySourceExactlyOnce() {
        XCTAssertEqual(WearableCapabilityCatalog.all.map(\.source),
                       [.whoop4, .whoop5, .whoopMG, .ouraRing4,
                        .ringConnGen3, .humeBand2, .appleWatch])
        XCTAssertEqual(Set(WearableCapabilityCatalog.all.map(\.source)), Set(WearableSource.allCases))
    }

    func testEveryContractDeclaresEveryAcquisitionLane() {
        for contract in WearableCapabilityCatalog.all {
            XCTAssertEqual(Set(contract.acquisition.keys), Set(WearableAcquisitionLane.allCases))
        }
    }

    func testMissingValuesFailClosed() {
        let incomplete = WearableCapabilityContract(
            source: .whoop4, acquisition: [:], metricCapabilities: [:]
        )
        XCTAssertEqual(incomplete.availability(for: .directBLE), .unavailable)
        XCTAssertEqual(incomplete.state(for: .heartRate, via: .directBLE), .unsupported)
        XCTAssertFalse(incomplete.hasProjectSupportedPath(for: .heartRate))

        for contract in WearableCapabilityCatalog.all {
            for metric in WearableMetric.allCases {
                for lane in WearableAcquisitionLane.allCases
                where contract.metricCapabilities[metric]?[lane] == nil {
                    XCTAssertEqual(contract.state(for: metric, via: lane), .unsupported)
                }
            }
        }
    }

    func testVendorDocumentedLaneDoesNotBecomeProjectSupport() throws {
        let ring = try XCTUnwrap(WearableCapabilityCatalog.contract(for: .ringConnGen3))
        XCTAssertEqual(ring.availability(for: .healthKitBridge), .vendorDocumented)
        XCTAssertEqual(ring.state(for: .heartRate, via: .healthKitBridge), .bridgeImported)
        XCTAssertFalse(ring.hasProjectSupportedPath(for: .heartRate))
    }

    func testRingConnAndHumeHaveNoDirectBLE() throws {
        for source in [WearableSource.ringConnGen3, .humeBand2] {
            let contract = try XCTUnwrap(WearableCapabilityCatalog.contract(for: source))
            XCTAssertEqual(contract.availability(for: .directBLE), .unavailable)
            XCTAssertTrue(contract.constraints.contains(.noPublicBLEProtocol))
            for metric in WearableMetric.allCases {
                XCTAssertFalse(contract.state(for: metric, via: .directBLE).isExposed)
            }
        }
    }

    func testHumeHealthKitCategoriesStayUnverified() throws {
        let hume = try XCTUnwrap(WearableCapabilityCatalog.contract(for: .humeBand2))
        XCTAssertEqual(hume.availability(for: .healthKitBridge), .vendorDocumented)
        XCTAssertTrue(hume.constraints.contains(.bridgeCategoriesRequireDeviceValidation))
        for metric in [WearableMetric.heartRate, .heartRateVariability, .bloodOxygen,
                       .skinTemperature, .steps, .sleepStages] {
            XCTAssertEqual(hume.state(for: metric, via: .healthKitBridge), .notExposed)
            XCTAssertFalse(hume.hasProjectSupportedPath(for: metric))
        }
    }

    func testWhoop5DirectRowsDescribeBLEAndRemainExperimental() throws {
        let whoop = try XCTUnwrap(WearableCapabilityCatalog.contract(for: .whoop5))
        XCTAssertEqual(whoop.availability(for: .directBLE), .experimental)
        XCTAssertEqual(whoop.state(for: .heartRate, via: .directBLE), .deviceDerived)
        XCTAssertEqual(whoop.state(for: .rrIntervals, via: .directBLE), .deviceDerived)
        XCTAssertEqual(whoop.state(for: .skinTemperature, via: .directBLE), .measuredSignal)
        XCTAssertEqual(whoop.state(for: .motion, via: .directBLE), .measuredSignal)
        XCTAssertEqual(whoop.state(for: .opticalWaveform, via: .directBLE), .measuredSignal)
        XCTAssertEqual(whoop.state(for: .bloodOxygen, via: .directBLE), .notExposed)
        XCTAssertEqual(whoop.state(for: .steps, via: .directBLE), .deviceDerived)
        XCTAssertEqual(whoop.state(for: .sleepStages, via: .directBLE), .deviceDerived)
        XCTAssertFalse(whoop.hasProjectSupportedPath(for: .rrIntervals))
        XCTAssertFalse(whoop.hasProjectSupportedPath(for: .opticalWaveform))
        XCTAssertTrue(whoop.hasProjectSupportedPath(for: .heartRate)) // file import, not BLE
    }

    func testOuraCloudDocumentedAndBLEExperimental() throws {
        let oura = try XCTUnwrap(WearableCapabilityCatalog.contract(for: .ouraRing4))
        XCTAssertEqual(oura.availability(for: .vendorCloud), .vendorDocumented)
        XCTAssertEqual(oura.availability(for: .directBLE), .experimental)
        XCTAssertEqual(oura.state(for: .readinessScore, via: .vendorCloud), .bridgeImported)
        XCTAssertFalse(oura.hasProjectSupportedPath(for: .rrIntervals))
    }

    func testWhoopMGECGAcquisitionExperimentalAndInterpretationUnsupported() throws {
        let mg = try XCTUnwrap(WearableCapabilityCatalog.contract(for: .whoopMG))
        XCTAssertEqual(mg.state(for: .ecgPackets, via: .directBLE), .measuredSignal)
        XCTAssertEqual(mg.availability(for: .directBLE), .experimental)
        XCTAssertFalse(mg.hasProjectSupportedPath(for: .ecgPackets))
        for lane in WearableAcquisitionLane.allCases {
            XCTAssertEqual(mg.state(for: .ecgInterpretation, via: lane), .unsupported)
        }
    }

    func testAppleWatchIsConditionalHealthKitOnly() throws {
        let watch = try XCTUnwrap(WearableCapabilityCatalog.contract(for: .appleWatch))
        XCTAssertEqual(watch.availability(for: .directBLE), .unavailable)
        XCTAssertEqual(watch.availability(for: .healthConnectBridge), .unavailable)
        XCTAssertEqual(watch.availability(for: .healthKitBridge), .projectSupported)
        for metric in [WearableMetric.heartRate, .heartRateVariability, .bloodOxygen,
                       .respiratoryRate, .wristTemperature, .steps, .sleepStages,
                       .workouts, .vo2Max] {
            XCTAssertEqual(watch.state(for: metric, via: .healthKitBridge), .bridgeImported)
            XCTAssertTrue(watch.hasProjectSupportedPath(for: metric))
        }
        XCTAssertEqual(watch.state(for: .rrIntervals, via: .directBLE), .notExposed)
        XCTAssertTrue(watch.constraints.isSuperset(of: [
            .healthKitEntitlementRequired, .healthKitPerTypeConsentRequired,
            .metricRequiresCompatibleDevice, .backgroundDeliveryNotGuaranteed,
        ]))
    }

    func testBloodPressureUnsupportedEverywhere() {
        for contract in WearableCapabilityCatalog.all {
            for lane in WearableAcquisitionLane.allCases {
                XCTAssertEqual(contract.state(for: .bloodPressure, via: lane), .unsupported)
            }
            XCTAssertFalse(contract.hasProjectSupportedPath(for: .bloodPressure))
            XCTAssertTrue(contract.constraints.contains(.bloodPressureUnsupported))
        }
    }
}
