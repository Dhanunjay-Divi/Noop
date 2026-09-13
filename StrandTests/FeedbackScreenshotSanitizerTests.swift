import XCTest
@testable import Strand

final class FeedbackScreenshotSanitizerTests: XCTestCase {
    func testCaptureGuardRejectsOptOutDismissalAndStaleResults() {
        var guardState = FeedbackScreenshotCaptureGuard()
        let first = guardState.begin()

        XCTAssertTrue(
            guardState.accepts(
                first,
                isPresented: true,
                isOptedIn: true
            )
        )
        XCTAssertFalse(
            guardState.accepts(
                first,
                isPresented: true,
                isOptedIn: false
            )
        )
        XCTAssertFalse(
            guardState.accepts(
                first,
                isPresented: false,
                isOptedIn: true
            )
        )

        guardState.invalidate()
        XCTAssertFalse(
            guardState.accepts(
                first,
                isPresented: true,
                isOptedIn: true
            )
        )
        let second = guardState.begin()
        XCTAssertFalse(
            guardState.accepts(
                first,
                isPresented: true,
                isOptedIn: true
            )
        )
        XCTAssertTrue(
            guardState.accepts(
                second,
                isPresented: true,
                isOptedIn: true
            )
        )
    }

    func testMetadataBearingPNGIsStrippedBeforeReview() {
        let sanitized = FeedbackScreenshotSanitizer.sanitize(
            FeedbackScreenshotFixture.rawMetadataBearing
        )

        XCTAssertEqual(sanitized, FeedbackScreenshotFixture.sanitized)
        XCTAssertEqual(
            FeedbackScreenshotSanitizer.sanitize(
                FeedbackScreenshotFixture.sanitized
            ),
            FeedbackScreenshotFixture.sanitized
        )
    }

    func testMalformedAndUnknownCriticalChunksFailClosed() {
        var badChecksum = FeedbackScreenshotFixture.sanitized
        badChecksum[badChecksum.index(badChecksum.startIndex, offsetBy: 20)] ^= 0xff
        XCTAssertNil(FeedbackScreenshotSanitizer.sanitize(badChecksum))

        var unknownCritical = FeedbackScreenshotFixture.sanitized
        let typeOffset = unknownCritical.index(
            unknownCritical.startIndex,
            offsetBy: 12
        )
        unknownCritical.replaceSubrange(
            typeOffset..<unknownCritical.index(typeOffset, offsetBy: 4),
            with: Data("ABCD".utf8)
        )
        XCTAssertNil(FeedbackScreenshotSanitizer.sanitize(unknownCritical))
        XCTAssertNil(
            FeedbackScreenshotSanitizer.sanitize(
                Data(FeedbackScreenshotFixture.sanitized.dropLast())
            )
        )
    }
}
