import XCTest
@testable import Strand

final class ProjectInfoTests: XCTestCase {
    func testAppStorePrivacyAndSupportURLsArePublicWebsitePages() {
        let expectedHost = "noop-private-trial.usetaptech.chatgpt.site"

        XCTAssertEqual(ProjectInfo.privacyPolicyURL.scheme, "https")
        XCTAssertEqual(ProjectInfo.privacyPolicyURL.host, expectedHost)
        XCTAssertEqual(ProjectInfo.privacyPolicyURL.path, "/privacy")

        XCTAssertEqual(ProjectInfo.supportURL.scheme, "https")
        XCTAssertEqual(ProjectInfo.supportURL.host, expectedHost)
        XCTAssertEqual(ProjectInfo.supportURL.path, "/support")
    }

    func testAppStoreDocumentURLsDoNotPointAtPrivateSourceHosting() {
        for url in [ProjectInfo.privacyPolicyURL, ProjectInfo.supportURL] {
            XCTAssertNotEqual(url.host, "github.com")
            XCTAssertFalse(url.path.lowercased().contains("issues"))
        }
    }

    func testBandOrderURLRequiresPublicHTTPSWithoutCredentials() {
        XCTAssertEqual(
            ProjectInfo.validatedBandOrderURL(
                " https://shop.example.com/band#checkout "
            )?.absoluteString,
            "https://shop.example.com/band"
        )

        for rejected in [
            nil,
            "",
            "$(NOOP_BAND_ORDER_URL)",
            "http://shop.example.com/band",
            "https://user:secret@shop.example.com/band",
            "https:///band",
        ] {
            XCTAssertNil(ProjectInfo.validatedBandOrderURL(rejected))
        }
    }
}
