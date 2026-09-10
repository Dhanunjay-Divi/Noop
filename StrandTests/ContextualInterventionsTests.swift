import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class ContextualInterventionsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(
        _ year: Int = 2026,
        _ month: Int = 8,
        _ day: Int = 22,
        _ hour: Int = 12,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func candidate(
        kind: ContextualInterventionKind = .stressBreathing,
        observedAt: Date,
        maximumAge: TimeInterval = 5 * 60,
        fingerprint: String = "window-1"
    ) -> ContextualInterventionCandidate {
        ContextualInterventionCandidate(
            kind: kind,
            observedAt: observedAt,
            maximumAge: maximumAge,
            fingerprint: fingerprint,
            title: "Review",
            body: "Open NOOP to review.",
            route: .today
        )
    }

    private func daily(_ day: String, spo2: Double?) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: nil,
            strain: nil,
            exerciseCount: nil,
            spo2Pct: spo2
        )
    }

    func testDeliveryGateRejectsStaleDuplicateCooldownAndQuietHourPrompts() {
        let now = date()
        let fresh = candidate(observedAt: now.addingTimeInterval(-30))
        let delivered = ContextualInterventionPolicy.evaluate(
            fresh,
            state: .empty,
            now: now,
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        )
        XCTAssertTrue(delivered.shouldDeliver)
        XCTAssertEqual(delivered.reason, .deliver)

        let duplicate = ContextualInterventionPolicy.evaluate(
            fresh,
            state: delivered.nextState,
            now: now.addingTimeInterval(60),
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        )
        XCTAssertEqual(duplicate.reason, .duplicate)

        let newStressWindow = candidate(
            observedAt: now.addingTimeInterval(31 * 60),
            fingerprint: "window-2"
        )
        let topicCooldown = ContextualInterventionPolicy.evaluate(
            newStressWindow,
            state: delivered.nextState,
            now: now.addingTimeInterval(31 * 60),
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        )
        XCTAssertEqual(topicCooldown.reason, .topicCooldown)

        let oxygen = candidate(
            kind: .oxygenTrend,
            observedAt: now.addingTimeInterval(10 * 60),
            maximumAge: 24 * 60 * 60,
            fingerprint: "oxygen-1"
        )
        let globalCooldown = ContextualInterventionPolicy.evaluate(
            oxygen,
            state: delivered.nextState,
            now: now.addingTimeInterval(10 * 60),
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        )
        XCTAssertEqual(globalCooldown.reason, .globalCooldown)

        let stale = ContextualInterventionPolicy.evaluate(
            candidate(observedAt: now.addingTimeInterval(-301)),
            state: .empty,
            now: now,
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        )
        XCTAssertEqual(stale.reason, .stale)

        let atNight = date(2026, 8, 22, 23)
        let quiet = ContextualInterventionPolicy.evaluate(
            candidate(observedAt: atNight),
            state: .empty,
            now: atNight,
            quietHoursEnabled: true,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        )
        XCTAssertEqual(quiet.reason, .quietHours)
    }

    func testDeliveryStateRoundTripsAcrossRestart() {
        let suiteName = "contextual-interventions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = ContextualInterventionState(
            lastGlobalDelivery: date(),
            deliveries: [
                ContextualInterventionKind.oxygenTrend.rawValue: .init(
                    at: date(),
                    fingerprint: "oxygen-a"
                )
            ]
        )

        ContextualInterventionCenter.saveState(state, defaults: defaults)

        XCTAssertEqual(ContextualInterventionCenter.loadState(defaults: defaults), state)
    }

    func testPlannedWorkoutRetriesAfterTransientCooldownAndQuietHours() {
        let start = date(2026, 8, 23, 8)
        let boundary = start.addingTimeInterval(-2 * 60 * 60)
        let planned = candidate(
            kind: .adaptivePlannedWorkout,
            observedAt: boundary,
            maximumAge: 2 * 60 * 60,
            fingerprint: "planned-a"
        )
        let state = ContextualInterventionState(
            lastGlobalDelivery: boundary.addingTimeInterval(-10 * 60),
            deliveries: [:]
        )

        XCTAssertEqual(
            ContextualInterventionPolicy.nextEligibleDate(
                for: planned,
                state: state,
                notBefore: boundary,
                quietHoursEnabled: true,
                quietStartMinutes: 22 * 60,
                quietEndMinutes: 7 * 60,
                calendar: calendar
            ),
            date(2026, 8, 23, 7)
        )
        XCTAssertNil(ContextualInterventionPolicy.nextEligibleDate(
            for: planned,
            state: ContextualInterventionState(
                lastGlobalDelivery: boundary,
                deliveries: [
                    ContextualInterventionKind.adaptivePlannedWorkout.rawValue: .init(
                        at: boundary,
                        fingerprint: "planned-a"
                    )
                ]
            ),
            notBefore: boundary,
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        ))
    }

    func testTravelAndRoutineSuppressWeakerAdaptiveFollowUpsForTheDay() {
        let now = date()
        let travel = candidate(
            kind: .adaptiveTravel,
            observedAt: now,
            maximumAge: 36 * 60 * 60,
            fingerprint: "travel-a"
        )
        let deliveredTravel = ContextualInterventionPolicy.evaluate(
            travel,
            state: .empty,
            now: now,
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        )
        XCTAssertTrue(deliveredTravel.shouldDeliver)

        let later = now.addingTimeInterval(31 * 60)
        let routine = candidate(
            kind: .adaptiveRoutineRecovery,
            observedAt: later,
            maximumAge: 18 * 60 * 60,
            fingerprint: "routine-a"
        )
        XCTAssertEqual(
            ContextualInterventionPolicy.evaluate(
                routine,
                state: deliveredTravel.nextState,
                now: later,
                quietHoursEnabled: false,
                quietStartMinutes: 22 * 60,
                quietEndMinutes: 7 * 60,
                calendar: calendar
            ).reason,
            .topicCooldown
        )

        let planned = candidate(
            kind: .adaptivePlannedWorkout,
            observedAt: later,
            maximumAge: 2 * 60 * 60,
            fingerprint: "planned-a"
        )
        XCTAssertEqual(
            ContextualInterventionPolicy.evaluate(
                planned,
                state: deliveredTravel.nextState,
                now: later,
                quietHoursEnabled: false,
                quietStartMinutes: 22 * 60,
                quietEndMinutes: 7 * 60,
                calendar: calendar
            ).reason,
            .topicCooldown
        )

        let sleep = candidate(
            kind: .adaptiveSleepRecovery,
            observedAt: later,
            maximumAge: 18 * 60 * 60,
            fingerprint: "sleep-a"
        )
        XCTAssertEqual(
            ContextualInterventionPolicy.evaluate(
                sleep,
                state: deliveredTravel.nextState,
                now: later,
                quietHoursEnabled: false,
                quietStartMinutes: 22 * 60,
                quietEndMinutes: 7 * 60,
                calendar: calendar
            ).reason,
            .topicCooldown
        )
    }

    func testPlannedWorkoutSuppressesWeakerRoutineAndSleepPrompts() {
        let now = date()
        let planned = candidate(
            kind: .adaptivePlannedWorkout,
            observedAt: now,
            maximumAge: 2 * 60 * 60,
            fingerprint: "planned-a"
        )
        let delivered = ContextualInterventionPolicy.evaluate(
            planned,
            state: .empty,
            now: now,
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        )
        XCTAssertTrue(delivered.shouldDeliver)

        let later = now.addingTimeInterval(31 * 60)
        for kind in [
            ContextualInterventionKind.adaptiveRoutineRecovery,
            .adaptiveSleepRecovery
        ] {
            XCTAssertEqual(
                ContextualInterventionPolicy.evaluate(
                    candidate(
                        kind: kind,
                        observedAt: later,
                        maximumAge: 18 * 60 * 60,
                        fingerprint: "\(kind.rawValue)-a"
                    ),
                    state: delivered.nextState,
                    now: later,
                    quietHoursEnabled: false,
                    quietStartMinutes: 22 * 60,
                    quietEndMinutes: 7 * 60,
                    calendar: calendar
                ).reason,
                .topicCooldown
            )
        }
    }

    func testPlannedWorkoutCandidateExpiresAtWorkoutStart() {
        let observedAt = date(2026, 8, 22, 17, 15)
        let adjustment = DailyActionPlanner.WorkoutAdjustment(
            startSec: Int(date(2026, 8, 22, 17, 30).timeIntervalSince1970),
            durationMinutes: 60,
            reason: .sleepDeficit,
            measuredSleepMinutes: 372,
            referenceSleepMinutes: 450,
            sleepDeficitMinutes: 78,
            sleepReference: .personalUsual,
            confidence: .solid
        )

        let candidate = AdaptiveDayInterventionFactory.plannedWorkoutCandidate(
            from: adjustment,
            day: "2026-08-22",
            observedAt: observedAt
        )

        XCTAssertEqual(candidate.maximumAge, 15 * 60, accuracy: 0.001)
        XCTAssertEqual(candidate.route, .workouts)
    }

    func testPlannedWorkoutBoundaryUsesAdaptiveDayDiagnosticIdentity() {
        XCTAssertEqual(
            LocalNotificationLifecycleLedger.stableIdentifier(
                ContextualInterventionCenter.plannedWorkoutRequestID
            ),
            "adaptive_day"
        )
        XCTAssertEqual(
            LocalNotificationLifecycleLedger.stableIdentifier(
                AdaptivePlannedWorkoutScheduler.requestID
            ),
            "adaptive_day"
        )
    }

    func testNaturalPlannedWorkoutExpiryPreservesAcceptedDeliveryHistory() {
        let suiteName = "planned-workout-expiry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = ContextualInterventionState(
            lastGlobalDelivery: date(),
            deliveries: [
                ContextualInterventionKind.adaptivePlannedWorkout.rawValue: .init(
                    at: date(),
                    fingerprint: "planned-a"
                )
            ]
        )
        ContextualInterventionCenter.saveState(state, defaults: defaults)
        ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
            keepingFingerprint: "planned-a",
            defaults: defaults
        )

        ContextualInterventionCenter.expirePlannedWorkoutArtifacts(
            fingerprint: "planned-a",
            defaults: defaults
        )

        XCTAssertEqual(ContextualInterventionCenter.loadState(defaults: defaults), state)
    }

    func testMissingWorkoutReconciliationDistinguishesExpiryFromRetraction() {
        let suiteName = "planned-workout-missing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let start = date(2026, 8, 22, 17, 30)
        let fingerprint = [
            "planned-workout",
            "2026-08-22",
            String(Int(start.timeIntervalSince1970)),
            "SLEEP_DEFICIT",
        ].joined(separator: "|")
        let state = ContextualInterventionState(
            lastGlobalDelivery: start.addingTimeInterval(-60 * 60),
            deliveries: [
                ContextualInterventionKind.adaptivePlannedWorkout.rawValue: .init(
                    at: start.addingTimeInterval(-60 * 60),
                    fingerprint: fingerprint
                )
            ]
        )

        ContextualInterventionCenter.saveState(state, defaults: defaults)
        ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
            keepingFingerprint: fingerprint,
            defaults: defaults
        )
        ContextualInterventionCenter.reconcileMissingPlannedWorkoutArtifacts(
            now: start.addingTimeInterval(1),
            defaults: defaults
        )
        XCTAssertEqual(ContextualInterventionCenter.loadState(defaults: defaults), state)

        ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
            keepingFingerprint: fingerprint,
            defaults: defaults
        )
        ContextualInterventionCenter.reconcileMissingPlannedWorkoutArtifacts(
            now: start.addingTimeInterval(-1),
            defaults: defaults
        )
        XCTAssertEqual(ContextualInterventionCenter.loadState(defaults: defaults), .empty)
    }

    func testPlannedWorkoutStartDateRejectsMalformedFingerprint() {
        let start = date(2026, 8, 22, 17, 30)
        let startSec = Int(start.timeIntervalSince1970)

        XCTAssertEqual(
            ContextualInterventionCenter.plannedWorkoutStartDate(
                from: "planned-workout|2026-08-22|\(startSec)"
            ),
            start
        )
        XCTAssertEqual(
            ContextualInterventionCenter.plannedWorkoutStartDate(
                from: "planned-workout|2026-08-22|\(startSec)|SLEEP_DEFICIT"
            ),
            start
        )
        XCTAssertNil(ContextualInterventionCenter.plannedWorkoutStartDate(
            from: "planned-workout|2026-08-22|not-a-date|SLEEP_DEFICIT"
        ))
        XCTAssertNil(ContextualInterventionCenter.plannedWorkoutStartDate(
            from: "other|2026-08-22|\(startSec)|SLEEP_DEFICIT"
        ))
    }

    func testLegacyWorkoutIdentityMigratesWithoutDroppingCooldownHistory() {
        let deliveredAt = date()
        let legacy = "planned-workout|2026-08-22|1700000123|SLEEP_DEFICIT"
        let current = "planned-workout|2026-08-22|1700000123"
        let state = ContextualInterventionState(
            lastGlobalDelivery: deliveredAt,
            deliveries: [
                ContextualInterventionKind.adaptivePlannedWorkout.rawValue: .init(
                    at: deliveredAt,
                    fingerprint: legacy
                )
            ]
        )

        let migrated = ContextualInterventionCenter.reconciledPlannedWorkoutState(
            state,
            keepingFingerprint: current
        )

        XCTAssertEqual(migrated.lastGlobalDelivery, deliveredAt)
        XCTAssertEqual(
            migrated.deliveries[
                ContextualInterventionKind.adaptivePlannedWorkout.rawValue
            ],
            .init(at: deliveredAt, fingerprint: current)
        )
        XCTAssertTrue(
            ContextualInterventionCenter.plannedWorkoutFingerprintsMatch(
                legacy,
                current
            )
        )
        XCTAssertFalse(
            ContextualInterventionCenter.plannedWorkoutFingerprintsMatch(
                legacy,
                "planned-workout|2026-08-23|1700000123"
            )
        )
    }

    func testDelayedLegacyDeliveryCannotRestoreTheOldIdentityShape() {
        let suiteName = "planned-workout-legacy-delivery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deliveredAt = date()
        let current = "planned-workout|2026-08-22|1700000123"
        ContextualInterventionCenter.saveState(
            .init(
                lastGlobalDelivery: deliveredAt,
                deliveries: [
                    ContextualInterventionKind.adaptivePlannedWorkout.rawValue: .init(
                        at: deliveredAt,
                        fingerprint: current
                    )
                ]
            ),
            defaults: defaults
        )

        ContextualInterventionCenter.recordScheduledPlannedWorkoutDelivery(
            fingerprint: "\(current)|SLEEP_DEFICIT",
            deliveredAt: deliveredAt.addingTimeInterval(60),
            defaults: defaults
        )

        XCTAssertEqual(
            ContextualInterventionCenter.loadState(defaults: defaults)
                .deliveries[
                    ContextualInterventionKind.adaptivePlannedWorkout.rawValue
                ]?.fingerprint,
            current
        )
    }

    @MainActor
    func testScheduledPlannedWorkoutIsReconciledAgainstLaterAcceptedPrompts() {
        let start = date(2026, 8, 22, 17, 30)
        let startSec = Int(start.timeIntervalSince1970)
        let boundary = start.addingTimeInterval(-AdaptivePlannedWorkoutScheduler.leadTime)
        let globalConflict = ContextualInterventionState(
            lastGlobalDelivery: boundary.addingTimeInterval(-10 * 60),
            deliveries: [:]
        )
        XCTAssertTrue(AdaptivePlannedWorkoutScheduler.shouldKeepPending(
            startSec: startSec,
            fingerprint: "planned-a",
            state: globalConflict,
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        ))

        XCTAssertTrue(AdaptivePlannedWorkoutScheduler.shouldKeepPending(
            startSec: Int(date(2026, 8, 23, 8).timeIntervalSince1970),
            fingerprint: "planned-quiet",
            state: .empty,
            quietHoursEnabled: true,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        ))

        let travelConflict = ContextualInterventionState(
            lastGlobalDelivery: boundary.addingTimeInterval(-60 * 60),
            deliveries: [
                ContextualInterventionKind.adaptiveTravel.rawValue: .init(
                    at: boundary.addingTimeInterval(-60 * 60),
                    fingerprint: "travel-a"
                )
            ]
        )
        XCTAssertFalse(AdaptivePlannedWorkoutScheduler.shouldKeepPending(
            startSec: startSec,
            fingerprint: "planned-a",
            state: travelConflict,
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        ))

        let weakerRoutine = ContextualInterventionState(
            lastGlobalDelivery: boundary.addingTimeInterval(-60 * 60),
            deliveries: [
                ContextualInterventionKind.adaptiveRoutineRecovery.rawValue: .init(
                    at: boundary.addingTimeInterval(-60 * 60),
                    fingerprint: "routine-a"
                )
            ]
        )
        XCTAssertTrue(AdaptivePlannedWorkoutScheduler.shouldKeepPending(
            startSec: startSec,
            fingerprint: "planned-a",
            state: weakerRoutine,
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60,
            calendar: calendar
        ))
    }

    func testTimeZoneObservationIgnoresDSTAndSurvivesRestartForTravelRetry() {
        let suiteName = "adaptive-time-zone.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(AdaptiveDayTimeZoneStore.observe(
            offsetSec: 0,
            nowSec: 1_000,
            defaults: defaults
        ))
        XCTAssertNil(AdaptiveDayTimeZoneStore.observe(
            offsetSec: 60 * 60,
            nowSec: 2_000,
            defaults: defaults
        ))
        let travel = AdaptiveDayTimeZoneStore.observe(
            offsetSec: 3 * 60 * 60,
            nowSec: 3_000,
            defaults: defaults
        )

        XCTAssertEqual(travel?.previousOffsetSec, 60 * 60)
        XCTAssertEqual(travel?.currentOffsetSec, 3 * 60 * 60)
        XCTAssertEqual(AdaptiveDayTimeZoneStore.pending(defaults: defaults), travel)
        AdaptiveDayTimeZoneStore.discardPending(defaults: defaults)
        XCTAssertNil(AdaptiveDayTimeZoneStore.pending(defaults: defaults))
    }

    func testAdaptiveRecommendationMapsToPrivateSleepRoute() {
        let candidate = AdaptiveDayInterventionFactory.candidate(from: .init(
            kind: .routineRecovery,
            observedAtSec: 1_700_000_000,
            maximumAgeSeconds: 18 * 60 * 60,
            confidence: .strong,
            fingerprint: "routine-window",
            evidence: ["personal-sleep-timing"]
        ))

        XCTAssertEqual(candidate.kind, .adaptiveRoutineRecovery)
        XCTAssertEqual(candidate.route, .sleep)
        XCTAssertEqual(candidate.fingerprint, "routine-window")
        XCTAssertFalse(candidate.body.contains("party"))
    }

    func testPlannedWorkoutCandidateUsesPrivateWorkoutRouteAndBoundedIdentity() {
        let observedAt = date()
        let startSec = Int(observedAt.timeIntervalSince1970) + 60 * 60
        let candidate = AdaptiveDayInterventionFactory.plannedWorkoutCandidate(
            from: .init(
                startSec: startSec,
                durationMinutes: 60,
                reason: .sleepAndRecovery,
                measuredSleepMinutes: 372,
                referenceSleepMinutes: 450,
                sleepDeficitMinutes: 78,
                sleepReference: .personalUsual,
                confidence: .solid
            ),
            day: "2026-08-22",
            observedAt: observedAt
        )

        XCTAssertEqual(candidate.kind, .adaptivePlannedWorkout)
        XCTAssertEqual(candidate.route, .workouts)
        XCTAssertEqual(candidate.maximumAge, 60 * 60)
        XCTAssertEqual(candidate.evidence.count, 3)
        XCTAssertTrue(candidate.evidence.contains(String(localized: "daily_plan.workout_adjustment.sleep_label")))
        XCTAssertTrue(candidate.evidence.contains(String(localized: "daily_plan.evidence.readiness")))
        XCTAssertFalse(candidate.fingerprint.contains("372"))
        XCTAssertEqual(
            candidate.fingerprint,
            "planned-workout|2026-08-22|\(startSec)"
        )
        XCTAssertFalse(candidate.body.contains("17:"))
    }

    func testMovingWorkoutWithinThirtyMinutesChangesItsFingerprint() {
        let observedAt = date()
        let first = DailyActionPlanner.WorkoutAdjustment(
            startSec: Int(observedAt.timeIntervalSince1970) + 60 * 60,
            durationMinutes: 60,
            reason: .sleepDeficit,
            measuredSleepMinutes: 372,
            referenceSleepMinutes: 450,
            sleepDeficitMinutes: 78,
            sleepReference: .personalUsual,
            confidence: .solid
        )
        let moved = DailyActionPlanner.WorkoutAdjustment(
            startSec: first.startSec + 5 * 60,
            durationMinutes: first.durationMinutes,
            reason: first.reason,
            measuredSleepMinutes: first.measuredSleepMinutes,
            referenceSleepMinutes: first.referenceSleepMinutes,
            sleepDeficitMinutes: first.sleepDeficitMinutes,
            sleepReference: first.sleepReference,
            confidence: first.confidence
        )

        XCTAssertNotEqual(
            AdaptiveDayInterventionFactory.plannedWorkoutCandidate(
                from: first,
                day: "2026-08-22",
                observedAt: observedAt
            ).fingerprint,
            AdaptiveDayInterventionFactory.plannedWorkoutCandidate(
                from: moved,
                day: "2026-08-22",
                observedAt: observedAt
            ).fingerprint
        )
    }

    func testChangingWorkoutEvidenceKeepsTheSameFingerprint() {
        let observedAt = date()
        let first = DailyActionPlanner.WorkoutAdjustment(
            startSec: Int(observedAt.timeIntervalSince1970) + 60 * 60,
            durationMinutes: 60,
            reason: .sleepDeficit,
            measuredSleepMinutes: 372,
            referenceSleepMinutes: 450,
            sleepDeficitMinutes: 78,
            sleepReference: .personalUsual,
            confidence: .solid
        )
        let changedEvidence = DailyActionPlanner.WorkoutAdjustment(
            startSec: first.startSec,
            durationMinutes: first.durationMinutes,
            reason: .sleepAndRecovery,
            measuredSleepMinutes: first.measuredSleepMinutes,
            referenceSleepMinutes: first.referenceSleepMinutes,
            sleepDeficitMinutes: first.sleepDeficitMinutes,
            sleepReference: first.sleepReference,
            confidence: first.confidence
        )

        XCTAssertEqual(
            AdaptiveDayInterventionFactory.plannedWorkoutCandidate(
                from: first,
                day: "2026-08-22",
                observedAt: observedAt
            ).fingerprint,
            AdaptiveDayInterventionFactory.plannedWorkoutCandidate(
                from: changedEvidence,
                day: "2026-08-22",
                observedAt: observedAt
            ).fingerprint
        )
    }

    func testStalePlannedWorkoutDeliveryIsRemovedAndGlobalCooldownRecomputed() {
        let older = date().addingTimeInterval(-2 * 60 * 60)
        let planned = date().addingTimeInterval(-60 * 60)
        let state = ContextualInterventionState(
            lastGlobalDelivery: planned,
            deliveries: [
                ContextualInterventionKind.adaptiveSleepRecovery.rawValue: .init(
                    at: older,
                    fingerprint: "sleep-a"
                ),
                ContextualInterventionKind.adaptivePlannedWorkout.rawValue: .init(
                    at: planned,
                    fingerprint: "planned-a"
                ),
            ]
        )

        let reconciled = ContextualInterventionCenter.reconciledPlannedWorkoutState(
            state,
            keepingFingerprint: nil
        )

        XCTAssertNil(
            reconciled.deliveries[
                ContextualInterventionKind.adaptivePlannedWorkout.rawValue
            ]
        )
        XCTAssertEqual(reconciled.lastGlobalDelivery, older)
        XCTAssertEqual(
            ContextualInterventionCenter.reconciledPlannedWorkoutState(
                state,
                keepingFingerprint: "planned-a"
            ),
            state
        )
    }

    func testSleepOnlyPlannedWorkoutCandidateDoesNotClaimReadinessEvidence() {
        let observedAt = date()
        let candidate = AdaptiveDayInterventionFactory.plannedWorkoutCandidate(
            from: .init(
                startSec: Int(observedAt.timeIntervalSince1970) + 60 * 60,
                durationMinutes: 60,
                reason: .sleepDeficit,
                measuredSleepMinutes: 372,
                referenceSleepMinutes: 450,
                sleepDeficitMinutes: 78,
                sleepReference: .personalUsual,
                confidence: .solid
            ),
            day: "2026-08-22",
            observedAt: observedAt
        )

        XCTAssertTrue(candidate.evidence.contains(String(localized: "daily_plan.workout_adjustment.sleep_label")))
        XCTAssertFalse(candidate.evidence.contains(String(localized: "daily_plan.evidence.readiness")))
    }

    func testWorkoutCautionNotificationHasRestartSafeCooldown() {
        let now = date()
        XCTAssertTrue(WorkoutCautionNotificationPolicy.shouldDeliver(
            state: .init(lastPostedAt: nil),
            now: now
        ))
        XCTAssertFalse(WorkoutCautionNotificationPolicy.shouldDeliver(
            state: .init(lastPostedAt: now),
            now: now.addingTimeInterval(599)
        ))
        XCTAssertTrue(WorkoutCautionNotificationPolicy.shouldDeliver(
            state: .init(lastPostedAt: now),
            now: now.addingTimeInterval(600)
        ))
    }

    func testOxygenNeedsTwoDistinctFreshLowDays() {
        let now = date()
        let rows = [
            SourcedDailyMetric(metric: daily("2026-08-20", spo2: 94.4), source: .whoopImport),
            SourcedDailyMetric(metric: daily("2026-08-21", spo2: 93.8), source: .appleHealth),
        ]

        let result = ContextualVitalPolicy.oxygenCandidate(
            sourceRows: rows,
            now: now,
            calendar: calendar
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .oxygenTrend)
        XCTAssertNil(ContextualVitalPolicy.oxygenCandidate(
            sourceRows: [rows[1]],
            now: now,
            calendar: calendar
        ))
        XCTAssertNil(ContextualVitalPolicy.oxygenCandidate(
            sourceRows: [
                rows[0],
                SourcedDailyMetric(metric: daily("2026-08-21", spo2: 97), source: .appleHealth),
            ],
            now: now,
            calendar: calendar
        ))
    }

    func testOxygenDeduplicatesSameDayByVitalSourcePriorityAndRejectsStalePairs() {
        let now = date()
        let sameDayConflict = [
            SourcedDailyMetric(metric: daily("2026-08-20", spo2: 97), source: .whoopImport),
            SourcedDailyMetric(metric: daily("2026-08-20", spo2: 92), source: .appleHealth),
            SourcedDailyMetric(metric: daily("2026-08-21", spo2: 92), source: .appleHealth),
        ]
        XCTAssertNil(ContextualVitalPolicy.oxygenCandidate(
            sourceRows: sameDayConflict,
            now: now,
            calendar: calendar
        ))

        let stale = [
            SourcedDailyMetric(metric: daily("2026-08-17", spo2: 92), source: .whoopImport),
            SourcedDailyMetric(metric: daily("2026-08-18", spo2: 93), source: .whoopImport),
        ]
        XCTAssertNil(ContextualVitalPolicy.oxygenCandidate(
            sourceRows: stale,
            now: now,
            calendar: calendar
        ))
    }

    func testVO2NeedsFreshMeaningfulChangeOverAtLeastThreeWeeks() {
        let now = date()
        let meaningful = ContextualVitalPolicy.vo2Candidate(
            measured: [
                .init(day: "2026-07-20", value: 40),
                .init(day: "2026-08-15", value: 44),
                .init(day: "2026-08-22", value: 44.5),
            ],
            estimated: [],
            now: now,
            calendar: calendar
        )
        XCTAssertNotNil(meaningful)
        XCTAssertEqual(meaningful?.kind, .vo2Trend)

        XCTAssertNil(ContextualVitalPolicy.vo2Candidate(
            measured: [
                .init(day: "2026-07-20", value: 40),
                .init(day: "2026-08-15", value: 42.5),
                .init(day: "2026-08-22", value: 42.5),
            ],
            estimated: [],
            now: now,
            calendar: calendar
        ))
        XCTAssertNil(ContextualVitalPolicy.vo2Candidate(
            measured: [
                .init(day: "2026-08-10", value: 40),
                .init(day: "2026-08-17", value: 44),
                .init(day: "2026-08-22", value: 44),
            ],
            estimated: [],
            now: now,
            calendar: calendar
        ))
    }

    func testVO2RejectsOneIsolatedShift() {
        XCTAssertNil(ContextualVitalPolicy.vo2Candidate(
            measured: [
                .init(day: "2026-07-20", value: 40),
                .init(day: "2026-08-15", value: 40.5),
                .init(day: "2026-08-22", value: 45),
            ],
            estimated: [],
            now: date(),
            calendar: calendar
        ))
    }

    func testBodyTemperatureIsFreshAbsoluteConflictAwareAndRecheckOnly() {
        let candidate = ContextualVitalPolicy.bodyTemperatureCandidate(
            points: [
                .init(day: "2026-08-22", valueC: 38.2, source: "apple-health", sourcePriority: 0),
            ],
            now: date(),
            calendar: calendar
        )
        XCTAssertEqual(candidate?.kind, .bodyTemperatureReview)
        XCTAssertTrue(candidate?.body.lowercased().contains("recheck") == true)

        XCTAssertNil(ContextualVitalPolicy.bodyTemperatureCandidate(
            points: [
                .init(day: "2026-08-22", valueC: 38.2, source: "apple-health", sourcePriority: 0),
                .init(day: "2026-08-22", valueC: 36.8, source: "health-connect", sourcePriority: 1),
            ],
            now: date(),
            calendar: calendar
        ))
        XCTAssertNil(ContextualVitalPolicy.bodyTemperatureCandidate(
            points: [
                .init(day: "2026-08-19", valueC: 39.0, source: "apple-health", sourcePriority: 0),
            ],
            now: date(),
            calendar: calendar
        ))
    }

    func testCaffeinePlanSchedulesCutoffOrPromptsOnlyAfterLateIntake() {
        let morning = date(2026, 8, 22, 10)
        let morningIntake = CaffeineIntake(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            at: date(2026, 8, 22, 9),
            mg: 100
        )
        let scheduled = CaffeineReminderPolicy.plan(
            intakes: [morningIntake],
            bedtimeMinutes: 23 * 60,
            now: morning,
            calendar: calendar
        )
        guard case .schedule(let cutoff) = scheduled else {
            return XCTFail("Expected a cutoff schedule.")
        }
        XCTAssertEqual(cutoff, date(2026, 8, 22, 12))

        let afternoon = date(2026, 8, 22, 13)
        let late = CaffeineIntake(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            at: date(2026, 8, 22, 12, 30),
            mg: nil
        )
        guard case .notifyNow(let prompt) = CaffeineReminderPolicy.plan(
            intakes: [late],
            bedtimeMinutes: 23 * 60,
            now: afternoon,
            calendar: calendar
        ) else {
            return XCTFail("Expected an immediate late-intake prompt.")
        }
        XCTAssertEqual(prompt.kind, .caffeineCutoff)

        XCTAssertEqual(
            CaffeineReminderPolicy.plan(
                intakes: [morningIntake],
                bedtimeMinutes: 23 * 60,
                now: afternoon,
                calendar: calendar
            ),
            .none
        )
    }

    func testWristMotionRequiresDenseRecentSamples() {
        let nowSec = Int(date().timeIntervalSince1970)
        let dense = (0...12).map { index in
            GravitySample(
                ts: nowSec - 60 + index * 5,
                x: index.isMultiple(of: 2) ? 0 : 0.002,
                y: 0,
                z: 1
            )
        }
        let evidence = WristMotionEvidencePolicy.derive(gravity: dense, nowSec: nowSec)
        XCTAssertNotNil(evidence)
        XCTAssertEqual(evidence?.sampleCount, dense.count)

        let sparse = (0..<8).map {
            GravitySample(ts: nowSec - 105 + $0 * 15, x: 0, y: 0, z: 1)
        }
        XCTAssertNil(WristMotionEvidencePolicy.derive(gravity: sparse, nowSec: nowSec))

        let stale = (0..<8).map {
            GravitySample(ts: nowSec - 120 + $0 * 4, x: 0, y: 0, z: 1)
        }
        XCTAssertNil(WristMotionEvidencePolicy.derive(gravity: stale, nowSec: nowSec))
        XCTAssertNil(WristMotionEvidencePolicy.derive(
            gravity: Array(dense.prefix(7)),
            nowSec: nowSec
        ))
    }

    func testStressEvidenceRejectsBandOffUnencryptedAndStalePhysiology() throws {
        let now = date()
        let rrAt = now.addingTimeInterval(-5)
        let hrAt = now.addingTimeInterval(-4)
        let motion = TimestampedWristMotionEvidence(
            movementG: 0.01,
            observedAt: now.addingTimeInterval(-3),
            sampleCount: 12
        )
        func value(
            rr: Date? = rrAt,
            hr: Date? = hrAt,
            evidence: TimestampedWristMotionEvidence? = motion,
            connected: Bool = true,
            bonded: Bool = true,
            encrypted: Bool = true,
            worn: Bool = true
        ) -> Double? {
            StressEvidencePolicy.qualifiedMotion(
                now: now,
                rrReceivedAt: rr,
                heartRateReceivedAt: hr,
                motion: evidence,
                connected: connected,
                bonded: bonded,
                encryptedBond: encrypted,
                worn: worn
            )
        }

        XCTAssertEqual(try XCTUnwrap(value()), 0.01, accuracy: 1e-12)
        XCTAssertNil(value(connected: false))
        XCTAssertNil(value(bonded: false))
        XCTAssertNil(value(encrypted: false))
        XCTAssertNil(value(worn: false))
        XCTAssertNil(value(rr: now.addingTimeInterval(-16)))
        XCTAssertNil(value(hr: now.addingTimeInterval(-16)))
        XCTAssertNil(value(rr: now.addingTimeInterval(1)))
        XCTAssertNil(value(evidence: .init(
            movementG: 0.01,
            observedAt: now.addingTimeInterval(-100),
            sampleCount: 12
        )))
    }

    func testStressRRBufferCannotBridgeTransportGapOrClockJump() {
        let now = date()
        XCTAssertFalse(StressEvidencePolicy.shouldResetRRBuffer(
            previousReceivedAt: nil,
            currentReceivedAt: now
        ))
        XCTAssertFalse(StressEvidencePolicy.shouldResetRRBuffer(
            previousReceivedAt: now.addingTimeInterval(-30),
            currentReceivedAt: now
        ))
        XCTAssertTrue(StressEvidencePolicy.shouldResetRRBuffer(
            previousReceivedAt: now.addingTimeInterval(-31),
            currentReceivedAt: now
        ))
        XCTAssertTrue(StressEvidencePolicy.shouldResetRRBuffer(
            previousReceivedAt: now.addingTimeInterval(1),
            currentReceivedAt: now
        ))
    }
}
