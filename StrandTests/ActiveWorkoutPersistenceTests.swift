import XCTest
import Foundation
import WhoopProtocol
@testable import Strand

/// Pins the durable manual-workout codec (#529): the persist -> rehydrate round-trip that lets a
/// manually-started session survive iOS killing the app mid-session so it can still be ended and saved.
/// Pure + `UserDefaults`-backed, mirroring the Android `ActiveWorkoutPersistenceTest` case for case.
final class ActiveWorkoutPersistenceTests: XCTestCase {

    private func sample(_ ts: Int, _ bpm: Int) -> HRSample { HRSample(ts: ts, bpm: bpm) }

    private func snapshot(
        startSec: Int = 1_700_000_000,
        endSec: Int? = nil,
        gpsEnabled: Bool = false,
        routeCheckpoint: WorkoutRouteCheckpoint? = nil,
        sport: String = "Tennis",
        samples: [HRSample] = [HRSample(ts: 1_700_000_001, bpm: 120), HRSample(ts: 1_700_000_061, bpm: 145)],
        avgHr: Int = 133,
        peakHr: Int = 145,
        liveStrain: Double = 8.4
    ) -> ActiveWorkoutPersistence.Snapshot {
        ActiveWorkoutPersistence.Snapshot(startSec: startSec, endSec: endSec,
                                          gpsEnabled: gpsEnabled, routeCheckpoint: routeCheckpoint,
                                          sport: sport, samples: samples,
                                          avgHr: avgHr, peakHr: peakHr, liveStrain: liveStrain)
    }

    /// A throwaway, isolated defaults suite so the test never touches the real store.
    private func freshDefaults() -> UserDefaults {
        let name = "test.activeWorkout.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - pure codec round-trip

    func testEncodeDecodeRoundTripsEveryField() {
        let original = snapshot()
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripWithNoSamples() {
        // A session that started but hasn't captured a sample yet (strap not streaming) must still
        // persist + rehydrate — otherwise a kill right after Start loses the start time.
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(samples: [], avgHr: 0, peakHr: 0, liveStrain: 0)))
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.samples.isEmpty)
        XCTAssertEqual(decoded!.startSec, 1_700_000_000)
        XCTAssertEqual(decoded!.sport, "Tennis")
    }

    func testRoundTripSportNameWithSpacesPreserved() {
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(sport: "Traditional Strength Training")))
        XCTAssertEqual(decoded!.sport, "Traditional Strength Training")
    }

    func testFinishedAtRoundTripsForRetryWithoutExtendingWorkout() {
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(endSec: 1_700_000_900)))
        XCTAssertEqual(decoded?.endSec, 1_700_000_900)
    }

    func testDecodeRejectsFinishBeforeStartRatherThanResumingCorruptWorkout() {
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(endSec: 1_699_999_999)))
        XCTAssertNil(decoded)
    }

    func testGpsIntentAndExactRouteCheckpointRoundTrip() {
        let points = [RouteMath.LatLng(51.5033, -0.1196), RouteMath.LatLng(51.5007, -0.1246)]
        let checkpoint = WorkoutRouteCheckpoint(polyline: RouteMath.encode(points),
                                                pointCount: points.count,
                                                lastFixMs: 1_700_000_061_000)
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(gpsEnabled: true, routeCheckpoint: checkpoint,
                                                      sport: "Running")))
        XCTAssertEqual(decoded?.gpsEnabled, true)
        XCTAssertEqual(decoded?.routeCheckpoint, checkpoint)
        XCTAssertEqual(decoded?.routeCheckpoint?.decodedPoints(), points)
        XCTAssertEqual(decoded?.shouldResumeGps, true)
    }

    func testEndedGpsSnapshotNeverResumesLocation() {
        let checkpoint = WorkoutRouteCheckpoint(
            polyline: RouteMath.encode([RouteMath.LatLng(1, 1)]),
            pointCount: 1,
            lastFixMs: 1_700_000_100_000)
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(endSec: 1_700_000_900,
                                                      gpsEnabled: true,
                                                      routeCheckpoint: checkpoint,
                                                      sport: "Running")))
        XCTAssertEqual(decoded?.routeCheckpoint, checkpoint)
        XCTAssertEqual(decoded?.shouldResumeGps, false,
                       "A failed-save retry stays frozen even though its route is retained.")
    }

    func testLegacySnapshotWithoutGpsKeysStillDecodesAsNonGps() {
        let json = """
        {"startSec":1700000000,"sport":"Tennis","samples":[],"avgHr":0,"peakHr":0,"liveStrain":0}
        """
        let decoded = ActiveWorkoutPersistence.decode(Data(json.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.gpsEnabled, false)
        XCTAssertNil(decoded?.routeCheckpoint)
        XCTAssertEqual(decoded?.shouldResumeGps, false)
    }

    func testCorruptRouteCheckpointIsDroppedWithoutInventingPartialRoute() {
        let corrupt = WorkoutRouteCheckpoint(polyline: RouteMath.encode([RouteMath.LatLng(1, 1)]),
                                             pointCount: 2,
                                             lastFixMs: 1_700_000_100_000)
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(gpsEnabled: true,
                                                      routeCheckpoint: corrupt,
                                                      sport: "Running")))
        XCTAssertEqual(decoded?.gpsEnabled, true)
        XCTAssertNil(decoded?.routeCheckpoint)
        XCTAssertEqual(decoded?.shouldResumeGps, true,
                       "GPS may resume fresh, but a mismatched persisted route must not be used.")
    }

    // MARK: - UserDefaults store / load / clear

    func testStoreLoadClearRoundTrip() {
        let defaults = freshDefaults()
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))   // nothing yet
        let snap = snapshot()
        ActiveWorkoutPersistence.store(snap, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), snap)
        // Ending the session clears it — a relaunch then rehydrates nothing.
        ActiveWorkoutPersistence.clear(from: defaults)
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))
    }

    func testStoreOverwritesPreviousSnapshot() {
        // Each bounded checkpoint replaces the snapshot; the latest durable window wins.
        let defaults = freshDefaults()
        ActiveWorkoutPersistence.store(snapshot(samples: [sample(1_700_000_001, 120)], avgHr: 120, peakHr: 120),
                                       into: defaults)
        let later = snapshot(samples: [sample(1_700_000_001, 120), sample(1_700_000_061, 150)],
                             avgHr: 135, peakHr: 150, liveStrain: 9.1)
        ActiveWorkoutPersistence.store(later, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), later)
    }

    func testFailedDatabaseSaveRetainsRecoverySnapshotForRetry() async {
        enum ExpectedFailure: Error { case unavailable }
        let defaults = freshDefaults()
        let checkpoint = WorkoutRouteCheckpoint(
            polyline: RouteMath.encode([RouteMath.LatLng(1, 1), RouteMath.LatLng(1.001, 1.001)]),
            pointCount: 2,
            lastFixMs: 1_700_000_800_000)
        let snap = snapshot(endSec: 1_700_000_900, gpsEnabled: true,
                            routeCheckpoint: checkpoint, sport: "Running")
        ActiveWorkoutPersistence.store(snap, into: defaults)
        let originalBytes = defaults.data(forKey: ActiveWorkoutPersistence.defaultsKey)

        let result = await ActiveWorkoutPersistence.saveThenClear(from: defaults) {
            throw ExpectedFailure.unavailable
        }

        guard case .failed = result else { return XCTFail("Expected a failed commit") }
        XCTAssertEqual(defaults.data(forKey: ActiveWorkoutPersistence.defaultsKey), originalBytes)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), snap)
    }

    func testSuccessfulDatabaseSaveClearsRecoverySnapshotAfterCommit() async {
        let defaults = freshDefaults()
        let checkpoint = WorkoutRouteCheckpoint(
            polyline: RouteMath.encode([RouteMath.LatLng(1, 1), RouteMath.LatLng(1.001, 1.001)]),
            pointCount: 2,
            lastFixMs: 1_700_000_800_000)
        ActiveWorkoutPersistence.store(
            snapshot(endSec: 1_700_000_900, gpsEnabled: true,
                     routeCheckpoint: checkpoint, sport: "Running"),
            into: defaults)
        var didSave = false

        let result = await ActiveWorkoutPersistence.saveThenClear(from: defaults) {
            didSave = true
        }

        XCTAssertEqual(result, .saved)
        XCTAssertTrue(didSave)
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))
    }

    // MARK: - honest failure (no revived bogus card)

    func testDecodeNilOrEmptyIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(nil))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data()))
    }

    func testDecodeGarbageIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("not json".utf8)))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("{\"unexpected\":1}".utf8)))
    }

    func testDecodeRejectsNonPositiveStart() {
        let bad = snapshot(startSec: 0)
        XCTAssertNil(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(bad)))
    }

    // MARK: - bound-checked untrusted samples

    func testDecodeDropsOutOfRangeSamples() {
        // A corrupt blob with a bpm=0, bpm=400, and ts<=0 sample — only the in-range one survives.
        let dirty = snapshot(samples: [
            sample(1_700_000_001, 150),   // good
            sample(1_700_000_002, 0),     // bpm 0 — rejected
            sample(1_700_000_003, 400),   // bpm out of range — rejected
            sample(0, 120),               // ts <= 0 — rejected
        ])
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertEqual(decoded?.samples, [sample(1_700_000_001, 150)])
    }

    func testDecodeClampsNegativeDerivedStats() {
        let dirty = snapshot(samples: [], avgHr: -5, peakHr: -9, liveStrain: -3)
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.avgHr, 0)
        XCTAssertEqual(decoded!.peakHr, 0)
        XCTAssertEqual(decoded!.liveStrain, 0, accuracy: 1e-9)
    }

    // MARK: - bounded growing-snapshot cadence

    func testRecoveryCadenceBoundsFullSnapshotWritesAndForcedLifecycleCanResetIt() {
        var cadence = WorkoutRecoveryCadence(persistedSampleCount: 0, persistedAtSec: 1_000)
        XCTAssertFalse(cadence.isDue(sampleCount: 1, nowSec: 1_001))
        XCTAssertFalse(cadence.isDue(sampleCount: 29, nowSec: 1_029))
        XCTAssertTrue(cadence.isDue(sampleCount: 30, nowSec: 1_029),
                      "Thirty fresh packets bound the unpersisted sample tail.")

        cadence.didPersist(sampleCount: 30, atSec: 1_029)
        XCTAssertFalse(cadence.isDue(sampleCount: 31, nowSec: 1_058))
        XCTAssertTrue(cadence.isDue(sampleCount: 31, nowSec: 1_059),
                      "Sparse HR still checkpoints by elapsed time.")

        cadence.didPersist(sampleCount: 31, atSec: 1_059) // forced GPS/lifecycle checkpoint
        XCTAssertFalse(cadence.isDue(sampleCount: 31, nowSec: 2_000),
                       "No new sample means there is no HR tail to persist.")
    }

    func testLiveStrainCadenceWaitsForTrustworthyCoverage() {
        let cadence = WorkoutLiveStrainCadence(computedSampleCount: 0, computedAtSec: 1_000)

        XCTAssertFalse(cadence.isDue(
            sampleCount: 19, firstSampleSec: 1_000, nowSec: 1_600,
            minimumSampleCount: 20, minimumSpanSec: 599
        ))
        XCTAssertFalse(cadence.isDue(
            sampleCount: 600, firstSampleSec: 1_000, nowSec: 1_598,
            minimumSampleCount: 20, minimumSpanSec: 599
        ))
        XCTAssertTrue(cadence.isDue(
            sampleCount: 600, firstSampleSec: 1_000, nowSec: 1_599,
            minimumSampleCount: 20, minimumSpanSec: 599
        ))
    }

    func testLiveStrainCadenceSupportsDenseAndSparseStreams() {
        var cadence = WorkoutLiveStrainCadence(computedSampleCount: 600, computedAtSec: 1_600)
        cadence.didCompute(sampleCount: 600, atSec: 1_600)

        XCTAssertFalse(cadence.isDue(
            sampleCount: 604, firstSampleSec: 1_000, nowSec: 1_604,
            minimumSampleCount: 20, minimumSpanSec: 599
        ))
        XCTAssertTrue(cadence.isDue(
            sampleCount: 605, firstSampleSec: 1_000, nowSec: 1_604,
            minimumSampleCount: 20, minimumSpanSec: 599
        ), "Dense streams refresh after five accepted samples.")

        cadence.didCompute(sampleCount: 605, atSec: 1_604)
        XCTAssertTrue(cadence.isDue(
            sampleCount: 606, firstSampleSec: 1_000, nowSec: 1_634,
            minimumSampleCount: 20, minimumSpanSec: 599
        ), "Sparse streams refresh after elapsed time without waiting for five packets.")
    }


    // MARK: - genuine HR-event cursor

    func testWorkoutCursorRejectsCachedAndRepeatedSequence() {
        var cursor = WorkoutHeartRateCursor(consumedSequence: 7)
        let time = Date(timeIntervalSince1970: 1_700_000_100)

        XCTAssertNil(cursor.consume(sequence: 7, bpm: 140, receivedAt: time),
                     "A pre-workout cached value is not a workout sample.")
        XCTAssertEqual(cursor.consume(sequence: 8, bpm: 140, receivedAt: time),
                       sample(1_700_000_100, 140))
        XCTAssertNil(cursor.consume(sequence: 8, bpm: 140,
                                    receivedAt: time.addingTimeInterval(1)),
                     "The same accepted packet may only be consumed once.")
    }

    func testWorkoutCursorKeepsSameBpmWhenItIsANewTimestampedPacket() {
        var cursor = WorkoutHeartRateCursor(consumedSequence: 0)
        XCTAssertEqual(cursor.consume(sequence: 1, bpm: 82,
                                      receivedAt: Date(timeIntervalSince1970: 1_700_000_100)),
                       sample(1_700_000_100, 82))
        XCTAssertEqual(cursor.consume(sequence: 2, bpm: 82,
                                      receivedAt: Date(timeIntervalSince1970: 1_700_000_101)),
                       sample(1_700_000_101, 82),
                       "Unchanged BPM is still real data when a new packet arrives one second later.")
    }

    func testWorkoutCursorDeduplicatesStorageSecondWithoutInventingTime() {
        var cursor = WorkoutHeartRateCursor(consumedSequence: 0)
        XCTAssertNotNil(cursor.consume(sequence: 1, bpm: 100,
                                       receivedAt: Date(timeIntervalSince1970: 1_700_000_100.1)))
        XCTAssertNil(cursor.consume(sequence: 2, bpm: 101,
                                    receivedAt: Date(timeIntervalSince1970: 1_700_000_100.9)))
        XCTAssertNil(cursor.consume(sequence: 3, bpm: 99,
                                    receivedAt: Date(timeIntervalSince1970: 1_700_000_099.9)),
                     "An out-of-order clock value must not make the workout timeline run backward.")
        XCTAssertEqual(cursor.consume(sequence: 4, bpm: 102,
                                      receivedAt: Date(timeIntervalSince1970: 1_700_000_101.1)),
                       sample(1_700_000_101, 102))
    }

    func testWorkoutCursorConsumesButRejectsImplausiblePacket() {
        var cursor = WorkoutHeartRateCursor(consumedSequence: 4)
        let time = Date(timeIntervalSince1970: 1_700_000_100)
        XCTAssertNil(cursor.consume(sequence: 5, bpm: 0, receivedAt: time))
        XCTAssertNil(cursor.consume(sequence: 5, bpm: 80, receivedAt: time),
                     "Changing cached fields cannot rehabilitate an already-consumed packet identity.")
    }
}
