import XCTest
@testable import Strand

final class PlannedWorkoutCalendarTests: XCTestCase {
    func testSnapshotBridgesCivilWorkoutIntoLogicalPlanningDayWithoutChangingTime() {
        let snapshot = PlannedWorkoutCalendarSnapshot(
            day: "2026-09-10",
            startSec: 1_789_060_200,
            endSec: 1_789_063_800,
            observedAtSec: 1_789_010_000,
            revision: 3
        )

        let workout = snapshot.plannedWorkout(forPlanningDay: "2026-09-09")

        XCTAssertEqual(workout.day, "2026-09-09")
        XCTAssertEqual(workout.startSec, snapshot.startSec)
        XCTAssertEqual(workout.endSec, snapshot.endSec)
    }

    @MainActor
    func testProviderChangeRequestsFreshGuidanceEvaluationWhenEnabled() async {
        let defaults = UserDefaults.standard
        let adaptiveKey = ContextualInterventionSettings.adaptiveDayGuidanceEnabledKey
        let calendarKey = PlannedWorkoutCalendarSettings.enabledKey
        let priorAdaptive = defaults.object(forKey: adaptiveKey)
        let priorCalendar = defaults.object(forKey: calendarKey)
        defer {
            if let priorAdaptive {
                defaults.set(priorAdaptive, forKey: adaptiveKey)
            } else {
                defaults.removeObject(forKey: adaptiveKey)
            }
            if let priorCalendar {
                defaults.set(priorCalendar, forKey: calendarKey)
            } else {
                defaults.removeObject(forKey: calendarKey)
            }
            PlannedWorkoutCalendarStore.shared.clear()
        }
        defaults.set(true, forKey: adaptiveKey)
        defaults.set(true, forKey: calendarKey)

        let requested = expectation(description: "calendar provider change")
        let observer = NotificationCenter.default.addObserver(
            forName: PlannedWorkoutCalendarStore.providerDidChange,
            object: nil,
            queue: .main
        ) { _ in
            requested.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await PlannedWorkoutCalendarStore.shared.handleProviderChange()

        await fulfillment(of: [requested], timeout: 1)
    }

    func testUserPlannerInputsRequestFreshGuidanceEvaluation() throws {
        let appModel = try source("Strand/App/AppModel.swift")
        let behavior = try source("Strand/Data/BehaviorStore.swift")
        let windDown = try source("Strand/System/WindDownNudge.swift")

        XCTAssertTrue(appModel.contains(
            "publisher(for: ContextualInterventionInputs.didChange)"
        ))
        XCTAssertTrue(behavior.contains("ContextualInterventionInputs.notifyChanged()"))
        XCTAssertTrue(windDown.contains("let wasExplicit = hasExplicitSleepNeed"))
        XCTAssertTrue(windDown.contains("if !wasExplicit || next != prior"))
        XCTAssertTrue(windDown.contains("ContextualInterventionInputs.notifyChanged()"))
    }

    func testAdaptiveEvaluationStopsAfterCalendarRefreshWhenCancelled() throws {
        let source = try source("Strand/App/AppModel.swift")
        let method = try XCTUnwrap(
            source.range(of: "private func evaluateAdaptiveDayGuidance")
        )
        let tail = source[method.lowerBound...]
        let refresh = try XCTUnwrap(
            tail.range(of: "await PlannedWorkoutCalendarStore.shared.refresh")
        )
        let cancellation = try XCTUnwrap(
            tail.range(
                of: "guard !Task.isCancelled else { return }",
                range: refresh.upperBound..<tail.endIndex
            )
        )
        let plan = try XCTUnwrap(
            tail.range(
                of: "let plan = DailyActionPlanner.plan",
                range: cancellation.upperBound..<tail.endIndex
            )
        )
        XCTAssertLessThan(cancellation.lowerBound, plan.lowerBound)
    }

    func testCalendarAuthorizationIsCheckedBeforeCachedSnapshotCanReturn() throws {
        let source = try source("Strand/System/PlannedWorkoutCalendar.swift")
        let method = try XCTUnwrap(
            source.range(of: "func refresh(now: Date = Date(), force: Bool = false)")
        )
        let tail = source[method.lowerBound...]
        let authorization = try XCTUnwrap(
            tail.range(of: "let authorization = Self.authorizationCategory()")
        )
        let accessGuard = try XCTUnwrap(
            tail.range(
                of: "guard authorization == \"full_access\" else",
                range: authorization.upperBound..<tail.endIndex
            )
        )
        let cachedReturn = try XCTUnwrap(
            tail.range(
                of: "return snapshot",
                range: accessGuard.upperBound..<tail.endIndex
            )
        )

        XCTAssertLessThan(authorization.lowerBound, accessGuard.lowerBound)
        XCTAssertLessThan(accessGuard.lowerBound, cachedReturn.lowerBound)
    }

    func testAdaptiveEvaluationSchedulesTheTwoHourBoundaryAndCancelsBeforeLiveDelivery() throws {
        let source = try source("Strand/App/AppModel.swift")
        let method = try XCTUnwrap(
            source.range(of: "private func evaluateAdaptiveDayGuidance")
        )
        let tail = source[method.lowerBound...]
        let schedule = try XCTUnwrap(
            tail.range(of: "AdaptivePlannedWorkoutScheduler.schedule")
        )
        let cancel = try XCTUnwrap(
            tail.range(
                of: "AdaptivePlannedWorkoutScheduler.cancelPending()",
                range: schedule.upperBound..<tail.endIndex
            )
        )
        let post = try XCTUnwrap(
            tail.range(
                of: "ContextualInterventionCenter.post",
                range: cancel.upperBound..<tail.endIndex
            )
        )

        XCTAssertLessThan(schedule.lowerBound, cancel.lowerBound)
        XCTAssertLessThan(cancel.lowerBound, post.lowerBound)
    }

    func testBoundarySchedulerReevaluatesConsentInsteadOfPreloadingNotificationCopy() throws {
        let source = try source("Strand/System/ContextualInterventions.swift")
        let start = try XCTUnwrap(
            source.range(of: "enum AdaptivePlannedWorkoutScheduler")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "struct WorkoutCautionNotificationState",
                range: start.upperBound..<source.endIndex
            )
        )
        let scheduler = source[start.lowerBound..<end.lowerBound]
        let accessCheck = try XCTUnwrap(
            scheduler.range(of: "PlannedWorkoutCalendarStore.hasCurrentReadAccess()")
        )
        let reevaluation = try XCTUnwrap(
            scheduler.range(
                of: "await onBoundary()",
                range: accessCheck.upperBound..<scheduler.endIndex
            )
        )

        XCTAssertFalse(scheduler.contains("UNTimeIntervalNotificationTrigger"))
        XCTAssertTrue(scheduler.contains("BackgroundSyncScheduler.requestWake"))
        XCTAssertLessThan(accessCheck.lowerBound, reevaluation.lowerBound)
    }

    func testImmediateDeliveryRechecksCalendarConsentAcrossNotificationAwaits() throws {
        let source = try source("Strand/System/ContextualInterventions.swift")
        let start = try XCTUnwrap(
            source.range(of: "private static func deliver(")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private static func deliveryConsentCurrent",
                range: start.upperBound..<source.endIndex
            )
        )
        let delivery = source[start.lowerBound..<end.lowerBound]
        let ensureCategory = try XCTUnwrap(
            delivery.range(of: "await DailyReviewNotifications.ensurePrivacyCategory")
        )
        let schedule = try XCTUnwrap(
            delivery.range(
                of: "try await LocalNotificationLifecycle.schedule",
                range: ensureCategory.upperBound..<delivery.endIndex
            )
        )
        let postScheduleConsent = try XCTUnwrap(
            delivery.range(
                of: "guard deliveryConsentCurrent(for: candidate)",
                range: schedule.upperBound..<delivery.endIndex
            )
        )
        let action = try XCTUnwrap(
            delivery.range(
                of: "ContextualActionCenter.shared.presentRecovery",
                range: postScheduleConsent.upperBound..<delivery.endIndex
            )
        )

        XCTAssertTrue(
            delivery[ensureCategory.upperBound..<schedule.lowerBound]
                .contains("deliveryConsentCurrent(for: candidate)")
        )
        XCTAssertLessThan(schedule.lowerBound, postScheduleConsent.lowerBound)
        XCTAssertLessThan(postScheduleConsent.lowerBound, action.lowerBound)
        XCTAssertTrue(source.contains("PlannedWorkoutCalendarStore.hasCurrentReadAccess()"))
        XCTAssertTrue(source.contains("PlannedWorkoutCalendarSettings.enabled"))
        XCTAssertTrue(source.contains(
            "currentPlannedWorkoutFingerprint == candidate.fingerprint"
        ))
    }

    func testChangedInputsInvalidateQueuedWorkoutGuidanceBeforeReevaluation() throws {
        let source = try source("Strand/System/ContextualInterventions.swift")
        let notifyStart = try XCTUnwrap(
            source.range(of: "static func notifyChanged()")
        )
        let notifyTail = source[notifyStart.lowerBound...]
        let invalidate = try XCTUnwrap(
            notifyTail.range(of: "invalidatePlannedWorkoutCandidate()")
        )
        let publish = try XCTUnwrap(
            notifyTail.range(
                of: "NotificationCenter.default.post",
                range: invalidate.upperBound..<notifyTail.endIndex
            )
        )

        XCTAssertLessThan(invalidate.lowerBound, publish.lowerBound)
        XCTAssertTrue(source.contains(
            "currentPlannedWorkoutFingerprint = keepingFingerprint"
        ))
    }

    func testRepositoryHealthInputsInvalidateWorkoutBeforeReevaluation() throws {
        let source = try source("Strand/App/AppModel.swift")

        for publisher in [
            "repo.$days.sink",
            "repo.$refreshSeq.dropFirst().sink"
        ] {
            let publisherStart = try XCTUnwrap(source.range(of: publisher))
            let publisherEnd = try XCTUnwrap(
                source.range(
                    of: "}.store(in: &hrCancellables)",
                    range: publisherStart.upperBound..<source.endIndex
                )
            )
            let subscription =
                source[publisherStart.lowerBound..<publisherEnd.upperBound]
            let invalidate = try XCTUnwrap(
                subscription.range(
                    of: "ContextualInterventionCenter.invalidatePlannedWorkoutCandidate()"
                )
            )
            let schedule = try XCTUnwrap(
                subscription.range(
                    of: "scheduleContextualInterventionEvaluation()",
                    range: invalidate.upperBound..<subscription.endIndex
                )
            )

            XCTAssertLessThan(invalidate.lowerBound, schedule.lowerBound)
        }
    }

    func testQueuedWorkoutReplacementKeepsItsDeliveryGateUntilQueueDrains() throws {
        let source = try source("Strand/System/ContextualInterventions.swift")
        let drainStart = try XCTUnwrap(
            source.range(of: "private static func drainPendingDeliveries() async")
        )
        let drainTail = source[drainStart.lowerBound...]
        let sameKindPending = try XCTUnwrap(
            drainTail.range(of: "pendingDeliveries.contains(where:")
        )
        let removeGate = try XCTUnwrap(
            drainTail.range(
                of: "deliveriesInFlight.remove(pending.candidate.kind)",
                range: sameKindPending.upperBound..<drainTail.endIndex
            )
        )

        XCTAssertLessThan(sameKindPending.lowerBound, removeGate.lowerBound)
    }

    func testRejectedStaleWorkoutDoesNotClearANewerCandidate() throws {
        let source = try source("Strand/System/ContextualInterventions.swift")
        let rejectStart = try XCTUnwrap(
            source.range(of: "private static func rejectDelivery(")
        )
        let rejectEnd = try XCTUnwrap(
            source.range(
                of: "static func loadState(",
                range: rejectStart.upperBound..<source.endIndex
            )
        )
        let rejection = source[rejectStart.lowerBound..<rejectEnd.lowerBound]
        let currentGate = try XCTUnwrap(
            rejection.range(
                of: "plannedWorkoutCandidateIsCurrent(candidate.fingerprint)"
            )
        )
        let cleanup = try XCTUnwrap(
            rejection.range(
                of: "reconcilePlannedWorkoutArtifacts(",
                range: currentGate.upperBound..<rejection.endIndex
            )
        )

        XCTAssertLessThan(currentGate.lowerBound, cleanup.lowerBound)
    }

    func testBoundaryScheduleStopsAfterNotificationSettingsWhenSuperseded() throws {
        let source = try source("Strand/System/ContextualInterventions.swift")
        let schedulerStart = try XCTUnwrap(
            source.range(of: "enum AdaptivePlannedWorkoutScheduler")
        )
        let schedulerTail = source[schedulerStart.lowerBound...]
        let scheduleStart = try XCTUnwrap(
            schedulerTail.range(of: "static func schedule(")
        )
        let scheduleTail = schedulerTail[scheduleStart.lowerBound...]
        let settings = try XCTUnwrap(
            scheduleTail.range(of: "let settings = await center.notificationSettings()")
        )
        let cancellation = try XCTUnwrap(
            scheduleTail.range(
                of: "guard !Task.isCancelled",
                range: settings.upperBound..<scheduleTail.endIndex
            )
        )
        let currentCandidate = try XCTUnwrap(
            scheduleTail.range(
                of: "ContextualInterventionCenter.plannedWorkoutCandidateIsCurrent(",
                range: cancellation.upperBound..<scheduleTail.endIndex
            )
        )
        let metadataWrite = try XCTUnwrap(
            scheduleTail.range(
                of: "defaults.set(adjustment.startSec",
                range: currentCandidate.upperBound..<scheduleTail.endIndex
            )
        )

        XCTAssertLessThan(settings.lowerBound, cancellation.lowerBound)
        XCTAssertLessThan(cancellation.lowerBound, currentCandidate.lowerBound)
        XCTAssertLessThan(currentCandidate.lowerBound, metadataWrite.lowerBound)
    }

    func testDeliveredPlannedWorkoutHasStartTimeCleanupAndRestartWake() throws {
        let schedulerSource = try source("Strand/System/ContextualInterventions.swift")
        let start = try XCTUnwrap(
            schedulerSource.range(of: "enum AdaptivePlannedWorkoutScheduler")
        )
        let end = try XCTUnwrap(
            schedulerSource.range(
                of: "struct WorkoutCautionNotificationState",
                range: start.upperBound..<schedulerSource.endIndex
            )
        )
        let scheduler = schedulerSource[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(scheduler.contains("scheduleDeliveryExpiry"))
        XCTAssertTrue(scheduler.contains("deliveredStartSecKey"))
        XCTAssertTrue(scheduler.contains("deliveredFingerprintKey"))
        XCTAssertTrue(scheduler.contains("ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts"))
        XCTAssertTrue(scheduler.contains("BackgroundSyncScheduler.requestWake"))

        let appModel = try source("Strand/App/AppModel.swift")
        XCTAssertTrue(appModel.contains("if leadSeconds <= 0"))
    }

    func testEventKitQueryRejectsCurrentUserDeclinedInvitations() throws {
        let source = try source("Strand/System/PlannedWorkoutCalendar.swift")
        XCTAssertTrue(source.contains("!plannedWorkoutWasDeclinedByCurrentUser(event)"))
        XCTAssertTrue(source.contains("participant.isCurrentUser"))
        XCTAssertTrue(source.contains("participant.participantStatus == .declined"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
