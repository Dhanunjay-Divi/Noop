import Foundation
import XCTest

final class WatchLiveHRSampleSelectionTests: XCTestCase {
    private struct Sample {
        let endDate: Date
        let bpm: Double
    }

    func testInvalidNewestSampleDoesNotHideEarlierValidSample() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let selected = newestUsableSample(
            [
                Sample(endDate: now.addingTimeInterval(-2), bpm: 72),
                Sample(endDate: now.addingTimeInterval(-1), bpm: 221),
            ],
            now: now
        )

        XCTAssertEqual(selected?.bpm, 72)
        XCTAssertEqual(selected?.endDate, now.addingTimeInterval(-2))

        let selection = try selectionSource()
        let plausibility = try XCTUnwrap(
            selection.range(of: "WatchLiveHRPolicy.plausibleBPM.contains(rounded)")
        )
        let newest = try XCTUnwrap(
            selection.range(of: ".max(by:", range: plausibility.upperBound..<selection.endIndex)
        )
        XCTAssertLessThan(plausibility.lowerBound, newest.lowerBound)
        XCTAssertTrue(selection.contains(".compactMap"))
    }

    func testInitialBatchWithNoValidSampleTransitionsToNoReadableSample() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let selected = newestUsableSample(
            [
                Sample(endDate: now.addingTimeInterval(-31), bpm: 72),
                Sample(endDate: now.addingTimeInterval(1), bpm: 72),
                Sample(endDate: now.addingTimeInterval(-1), bpm: 29),
                Sample(endDate: now.addingTimeInterval(-2), bpm: 221),
            ],
            now: now
        )

        XCTAssertNil(selected)

        let publish = try publishSource()
        XCTAssertTrue(
            publish.contains("guard let latest = Self.newestUsableSample(samples, now: now) else")
        )
        XCTAssertTrue(publish.contains("guard reportNoSample else { return }"))
        XCTAssertTrue(publish.contains("owner.accessState = .noReadableSample"))
        XCTAssertTrue(try watchLiveHRSource().contains("reportNoSample: true"))
    }

    private func newestUsableSample(
        _ samples: [Sample],
        now: Date
    ) -> (endDate: Date, bpm: Int)? {
        samples
            .compactMap { sample -> (endDate: Date, bpm: Int)? in
                let age = now.timeIntervalSince(sample.endDate)
                guard age >= 0 && age <= 30,
                      let rounded = Int(exactly: sample.bpm.rounded()),
                      (30...220).contains(rounded) else {
                    return nil
                }
                return (endDate: sample.endDate, bpm: rounded)
            }
            .max(by: { $0.endDate < $1.endDate })
    }

    private func selectionSource() throws -> String {
        let source = try watchLiveHRSource()
        let start = try XCTUnwrap(source.range(of: "nonisolated private static func newestUsableSample("))
        let end = try XCTUnwrap(
            source.range(
                of: "nonisolated private static func publishNewest(",
                range: start.upperBound..<source.endIndex
            )
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func publishSource() throws -> String {
        let source = try watchLiveHRSource()
        let start = try XCTUnwrap(source.range(of: "nonisolated private static func publishNewest("))
        let end = try XCTUnwrap(
            source.range(
                of: "private func scheduleExpiry(",
                range: start.upperBound..<source.endIndex
            )
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func watchLiveHRSource() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent("NOOPWatch/WatchLiveHR.swift"),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("project.yml").path
        ) {
            let parent = candidate.deletingLastPathComponent()
            precondition(parent.path != candidate.path, "Could not locate repository root")
            candidate = parent
        }
        return candidate
    }
}
