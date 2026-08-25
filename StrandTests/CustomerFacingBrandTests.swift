import XCTest
@testable import Strand

final class CustomerFacingBrandTests: XCTestCase {
    func testDynamicCustomerTextRemovesVendorWordingAndLegacyIds() {
        let raw = """
        WHOOP 5/MG · WHOOP import · my-whoop · whoop_live_hr_in_adv_ind_pkt · whoop5-C0FF · OpenWhoop
        """
        let visible = CustomerFacingBrand.text(raw)

        XCTAssertFalse(visible.localizedCaseInsensitiveContains("whoop"))
        XCTAssertTrue(visible.contains("newer band"))
        XCTAssertTrue(visible.contains("wearable import"))
        XCTAssertTrue(visible.contains("band broadcast setting"))
        XCTAssertTrue(visible.contains("band-5-C0FF"))
        XCTAssertTrue(visible.contains("NOOP legacy storage"))
    }

    func testUserAssignedAndAdvertisedNamesAreSafeToRender() {
        XCTAssertEqual(
            CustomerFacingBrand.text("My WHOOP sensor"),
            "My compatible band sensor"
        )
    }

    func testNoopAndUnrelatedProviderNamesRemainUnchanged() {
        XCTAssertEqual(
            CustomerFacingBrand.text("Noop Band · Apple Health · Garmin"),
            "Noop Band · Apple Health · Garmin"
        )
    }

    func testEveryChangelogEntryIsSafeAfterCustomerRendering() {
        for release in AppChangelog.releases {
            XCTAssertFalse(CustomerFacingBrand.text(release.title).localizedCaseInsensitiveContains("whoop"))
            for item in release.items {
                XCTAssertFalse(CustomerFacingBrand.text(item).localizedCaseInsensitiveContains("whoop"))
            }
        }
    }
}
