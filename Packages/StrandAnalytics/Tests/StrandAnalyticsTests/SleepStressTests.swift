import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SleepStressTests: XCTestCase {
    func testFailsClosedWithoutJointCoverage() {
        let start = 1_700_000_000
        let hr = (0..<3_600).map { HRSample(ts: start + $0, bpm: 60) }

        XCTAssertNil(SleepStress.analyze(hr: hr, rr: [], startTs: start, endTs: start + 3_600))
    }

    func testStableRestingNightPublishesLowStress() throws {
        let streams = makeStreams(bucketCount: 12, stressedBuckets: [])
        let maybeResult = SleepStress.analyze(
            hr: streams.hr,
            rr: streams.rr,
            startTs: streams.start,
            endTs: streams.end)

        let result = try XCTUnwrap(maybeResult)
        XCTAssertEqual(result.coverageFraction, 1, accuracy: 0.0001)
        XCTAssertEqual(result.bucketCount(in: .low), 12)
        XCTAssertEqual(result.bucketCount(in: .high), 0)
    }

    func testElevatedHRAndSuppressedHRVProduceHighWindows() {
        let streams = makeStreams(bucketCount: 12, stressedBuckets: [10, 11])
        let result = SleepStress.analyze(
            hr: streams.hr,
            rr: streams.rr,
            startTs: streams.start,
            endTs: streams.end)

        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result?.bucketCount(in: .high) ?? 0, 2)
        XCTAssertGreaterThan(result?.fraction(in: .high) ?? 0, 0)
    }

    func testSparseJointCoverageDoesNotPublish() {
        let streams = makeStreams(bucketCount: 12, stressedBuckets: [])
        let sparseHR = streams.hr.filter { ($0.ts - streams.start) < 6 * SleepStress.bucketSeconds }
        let sparseRR = streams.rr.filter { ($0.ts - streams.start) < 6 * SleepStress.bucketSeconds }

        XCTAssertNil(SleepStress.analyze(
            hr: sparseHR,
            rr: sparseRR,
            startTs: streams.start,
            endTs: streams.end))
    }

    private func makeStreams(
        bucketCount: Int,
        stressedBuckets: Set<Int>
    ) -> (start: Int, end: Int, hr: [HRSample], rr: [RRInterval]) {
        let start = 1_700_000_000
        let end = start + bucketCount * SleepStress.bucketSeconds
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        hr.reserveCapacity(end - start)
        rr.reserveCapacity(end - start)

        for offset in 0..<(end - start) {
            let bucket = offset / SleepStress.bucketSeconds
            let stressed = stressedBuckets.contains(bucket)
            hr.append(HRSample(ts: start + offset, bpm: stressed ? 100 : 60))
            let calmRR = offset.isMultiple(of: 2) ? 900 : 1_000
            let stressedRR = offset.isMultiple(of: 2) ? 650 : 660
            rr.append(RRInterval(ts: start + offset, rrMs: stressed ? stressedRR : calmRR))
        }
        return (start, end, hr, rr)
    }
}
