import XCTest
import StrandAnalytics
@testable import Strand

/// A1/S4/S5 - the pure pieces behind the Today hero Charge-ring tap and the home-screen collapses:
/// the descriptive readiness read kept on the hero (#205), the collapsed "Synced from: ..." footer summary
/// (S5), and full-catalog metric ordering. Each is a view-free static so it pins without a live view.
final class TodayChargeTapCollapseTests: XCTestCase {

    // MARK: #205 descriptive readiness read (kept on the hero after Readiness folded into the Charge tap)

    func testReadinessWord_mapsEveryLevel() {
        XCTAssertEqual(TodayView.readinessWord(.primed), "Aligned")
        XCTAssertEqual(TodayView.readinessWord(.balanced), "Within range")
        XCTAssertEqual(TodayView.readinessWord(.strained), "Recheck")
        XCTAssertEqual(TodayView.readinessWord(.rundown), "Multiple shifts")
    }

    func testReadinessWord_insufficientHasNoWord() {
        // Not enough history yet: the hero shows no readiness word (the old card hid itself), so nil.
        XCTAssertNil(TodayView.readinessWord(.insufficient))
    }

    // MARK: S5 collapsed Data Sources footer summary

    func testSyncedFromSummary_listsOnlySourcesWithData() {
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: true, hasApple: true, hasXiaomi: false),
            "Synced from: Noop Band, Apple Watch")
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: true, hasApple: false, hasXiaomi: false),
            "Synced from: Noop Band")
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: true, hasApple: true, hasXiaomi: true),
            "Synced from: Noop Band, Apple Watch, Mi Band")
    }

    func testSyncedFromSummary_appleHealthReadsAsAppleWatch() {
        // A watch-only user reads the device they know, not the framework: "Apple Watch", not "Apple Health".
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: false, hasApple: true, hasXiaomi: false),
            "Synced from: Apple Watch")
    }

    func testSyncedFromSummary_noSourcesIsHonest() {
        XCTAssertEqual(
            TodayView.syncedFromSummary(hasWhoop: false, hasApple: false, hasXiaomi: false),
            "No sources yet")
    }

    // MARK: Key Metrics focused/expanded order

    func testExpandedMetricsKeepPinsFirstAndRestoreTheWholeCatalog() {
        let pins: [KeyMetric] = [.steps, .hrv, .bloodOxygen]
        let expanded = KeyMetricPrefs.catalogOrder(startingWith: pins)
        XCTAssertEqual(Array(expanded.prefix(pins.count)), pins)
        XCTAssertEqual(Set(expanded), Set(KeyMetric.allCases))
        XCTAssertEqual(expanded.count, KeyMetric.allCases.count)
    }
}
