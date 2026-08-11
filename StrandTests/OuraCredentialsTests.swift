// Tests the OURA_CLOUD_IMPORT-gated Oura import lane; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if OURA_CLOUD_IMPORT
import XCTest
@testable import Strand

final class OuraCredentialsTests: XCTestCase {
    func testParsesCompleteInfoDict() {
        let info: [String: Any] = [
            "OURA_CLIENT_ID": "cid",
            "OURA_REDIRECT_URI": "noop://oura/callback",
        ]
        let c = OuraCredentials.from(info)
        XCTAssertEqual(c, OuraCredentials(clientId: "cid", redirectURI: "noop://oura/callback"))
    }

    func testNilWhenAnyKeyMissingOrBlank() {
        XCTAssertNil(OuraCredentials.from(["OURA_CLIENT_ID": "cid"]))  // no redirect
        XCTAssertNil(OuraCredentials.from([
            "OURA_CLIENT_ID": "", "OURA_REDIRECT_URI": "noop://x",
        ]))  // blank id
    }
}
#endif // OURA_CLOUD_IMPORT
