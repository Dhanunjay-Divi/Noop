import XCTest
@testable import OuraProtocol

final class HypnogramAssemblerTests: XCTestCase {
    private func phases(_ stages: [OuraSleepStage], rt: UInt32) -> [OuraSleepPhase] {
        stages.enumerated().map {
            OuraSleepPhase(ringTimestamp: rt, index: $0.offset, stage: $0.element)
        }
    }

    func testBurstCodesReceiveDistinctThirtySecondSlots() throws {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(ringTimestamp: 5_000,
                                    phases: phases([.awake, .light], rt: 5_000)))
        XCTAssertNil(assembler.feed(ringTimestamp: 5_010,
                                    phases: phases([.deep, .rem], rt: 5_010)))

        let burst = try XCTUnwrap(assembler.flush())
        let laid = burst.codesWithTimes(endUnixSeconds: 100_000)
        XCTAssertEqual(laid.map(\.ts), [99_880, 99_910, 99_940, 99_970])
        XCTAssertEqual(laid.map { $0.phase.stage }, [.awake, .light, .deep, .rem])
        XCTAssertEqual(Set(laid.map(\.ts)).count, laid.count,
                       "one timestamp per phase prevents (deviceId, ts, kind) event-key collapse")
    }

    func testErasedMiddlePageCreatesGapWithoutRetimingWrittenCodes() {
        let first = phases([.deep, .light, .rem, .awake], rt: 1_000)
        let erased = (0..<4).map {
            OuraSleepPhase(ringTimestamp: 1_001, index: $0, stage: .awake, unwritten: true)
        }
        let last = phases([.light, .deep, .rem, .light], rt: 1_002)
        let burst = OuraHypnogramBurst(records: [
            OuraHypnogramRecord(ringTimestamp: 1_000, phases: first),
            OuraHypnogramRecord(ringTimestamp: 1_001, phases: erased),
            OuraHypnogramRecord(ringTimestamp: 1_002, phases: last),
        ])

        let laid = burst.codesWithTimes(endUnixSeconds: 10_000)
        XCTAssertEqual(laid.count, 8)
        XCTAssertTrue(laid.allSatisfy { !$0.phase.unwritten })
        XCTAssertEqual(laid.prefix(4).map(\.ts), [9_640, 9_670, 9_700, 9_730])
        XCTAssertEqual(laid.suffix(4).map(\.ts), [9_880, 9_910, 9_940, 9_970])
        XCTAssertEqual(laid[4].ts - laid[3].ts, 150,
                       "four erased epochs remain a 120-second hole between 30-second slots")
    }

    func testAllErasedBurstProducesNoStageableNight() {
        let erased = (0..<8).map {
            OuraSleepPhase(ringTimestamp: 1_000, index: $0, stage: .awake, unwritten: true)
        }
        let burst = OuraHypnogramBurst(records: [
            OuraHypnogramRecord(ringTimestamp: 1_000, phases: erased),
        ])
        XCTAssertTrue(burst.codesWithTimes(endUnixSeconds: 10_000).isEmpty)
    }

    func testLargeGapSplitsBurstsAndResetClearsState() throws {
        let assembler = OuraHypnogramAssembler()
        XCTAssertNil(assembler.feed(ringTimestamp: 1_000,
                                    phases: phases([.light, .light], rt: 1_000)))
        let first = try XCTUnwrap(assembler.feed(ringTimestamp: 2_000,
                                                phases: phases([.deep], rt: 2_000)))
        XCTAssertEqual(first.totalCodes, 2)
        XCTAssertEqual(try XCTUnwrap(assembler.flush()).totalCodes, 1)
        _ = assembler.feed(ringTimestamp: 3_000, phases: phases([.rem], rt: 3_000))
        assembler.reset()
        XCTAssertNil(assembler.flush())
    }

    func testOnsetClampCannotEraseWholeWrittenNight() throws {
        let assembler = OuraHypnogramAssembler()
        _ = assembler.feed(ringTimestamp: 1_000,
                           phases: phases([.awake, .light, .deep, .rem], rt: 1_000))
        let burst = try XCTUnwrap(assembler.flush())
        XCTAssertEqual(burst.codesWithTimes(endUnixSeconds: 10_000,
                                            sleepStartUnixSeconds: 9_910).map(\.ts),
                       [9_910, 9_940, 9_970])
        XCTAssertEqual(burst.codesWithTimes(endUnixSeconds: 10_000,
                                            sleepStartUnixSeconds: 99_999).count, 4)
    }
}
