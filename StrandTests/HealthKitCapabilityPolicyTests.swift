import XCTest
@testable import Strand

final class HealthKitCapabilityPolicyTests: XCTestCase {
    private let baseKey = "com.apple.developer.healthkit"
    private let backgroundKey = "com.apple.developer.healthkit.background-delivery"

    func testProfilelessBuildRequiresAppStoreReceipt() {
        XCTAssertFalse(
            HealthKitCapabilityPolicy.allows(
                entitlement: baseKey,
                embeddedProvisioningProfile: nil,
                hasAppStoreReceipt: false
            )
        )
        XCTAssertTrue(
            HealthKitCapabilityPolicy.allows(
                entitlement: baseKey,
                embeddedProvisioningProfile: nil,
                hasAppStoreReceipt: true
            )
        )
    }

    func testEmbeddedProfileRequiresTheRequestedTruthyEntitlement() throws {
        let profile = try provisioningProfile(entitlements: [
            baseKey: true,
            backgroundKey: false,
        ])

        XCTAssertTrue(
            HealthKitCapabilityPolicy.allows(
                entitlement: baseKey,
                embeddedProvisioningProfile: profile,
                hasAppStoreReceipt: false
            )
        )
        XCTAssertFalse(
            HealthKitCapabilityPolicy.allows(
                entitlement: backgroundKey,
                embeddedProvisioningProfile: profile,
                hasAppStoreReceipt: true
            )
        )
        XCTAssertFalse(
            HealthKitCapabilityPolicy.allows(
                entitlement: "missing.entitlement",
                embeddedProvisioningProfile: profile,
                hasAppStoreReceipt: true
            )
        )
    }

    func testMalformedEmbeddedProfileFailsClosedEvenWithReceipt() {
        XCTAssertFalse(
            HealthKitCapabilityPolicy.allows(
                entitlement: baseKey,
                embeddedProvisioningProfile: Data("not a profile".utf8),
                hasAppStoreReceipt: true
            )
        )
    }

    private func provisioningProfile(entitlements: [String: Any]) throws -> Data {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Entitlements": entitlements],
            format: .xml,
            options: 0
        )
        var wrapped = Data([0x30, 0x82, 0x01, 0x00])
        wrapped.append(plist)
        wrapped.append(Data([0x00, 0x01]))
        return wrapped
    }
}
