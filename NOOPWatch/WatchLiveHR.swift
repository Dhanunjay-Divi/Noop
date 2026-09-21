import Foundation
import Combine
#if canImport(HealthKit)
import HealthKit

private enum WatchLiveHRPolicy {
    static let maximumSampleAge: TimeInterval = 30
    static let plausibleBPM = 30...220
}
#endif

// MARK: - WatchLiveHR — the watch's own live heart rate
//
// This is the one number the watch measures itself rather than receiving from the phone: the wrist's
// current heart rate, read from HealthKit via a streaming HKAnchoredObjectQuery. It is GUARDED at every
// step. The glance may check existing authorization when it appears, but only a user tap may open the
// Health permission sheet. Historical samples are filtered by their observation time and expire in place.
//
// We deliberately keep this lightweight: an anchored query that delivers the newest samples while the app
// is foregrounded, no HKWorkoutSession. A full session (and the higher-fidelity in-workout stream) is M4.
@MainActor
final class WatchLiveHR: ObservableObject {
    enum AccessState: Equatable {
        case checking
        case needsRequest
        case available
        case noReadableSample
        case queryFailed
        case unavailable
    }

    /// The most recent heart rate in whole BPM, or nil if we have no reading yet.
    @Published private(set) var bpm: Int?
    @Published private(set) var accessState: AccessState = .checking
    @Published private(set) var isRequesting = false

    #if canImport(HealthKit)
    private let store = HKHealthStore()
    private let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)
    private var query: HKAnchoredObjectQuery?
    private var streamGeneration: UInt64 = 0
    private var desiredStreaming = false
    private var latestObservation: Date?
    private var expiryTask: Task<Void, Never>?
    #endif

    /// Start only when Health already considers the request resolved. This never presents permission UI.
    func start() {
        #if canImport(HealthKit)
        let generation = desiredStreamingGeneration()
        #if targetEnvironment(simulator)
        accessState = .unavailable
        return
        #else
        guard HKHealthStore.isHealthDataAvailable(), let hrType else {
            accessState = .unavailable
            return
        }
        accessState = .checking
        store.getRequestStatusForAuthorization(toShare: [], read: [hrType]) { [weak self] status, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentStreamingGeneration(generation) else { return }
                switch status {
                case .unnecessary:
                    self.accessState = .available
                    self.beginStreaming(generation: generation)
                case .shouldRequest:
                    self.accessState = .needsRequest
                case .unknown:
                    self.accessState = .unavailable
                @unknown default:
                    self.accessState = .unavailable
                }
            }
        }
        #endif
        #else
        accessState = .unavailable
        #endif
    }

    /// User-initiated Health access request. The glance calls this only from its visible Allow button.
    func requestAuthorization() {
        #if canImport(HealthKit)
        #if targetEnvironment(simulator)
        accessState = .unavailable
        #else
        guard !isRequesting, HKHealthStore.isHealthDataAvailable(), let hrType else {
            accessState = .unavailable
            return
        }
        let generation = desiredStreamingGeneration()
        isRequesting = true
        store.requestAuthorization(toShare: [], read: [hrType]) { [weak self] completed, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentStreamingGeneration(generation) else { return }
                self.isRequesting = false
                guard completed else {
                    self.accessState = .unavailable
                    return
                }
                self.accessState = .checking
                self.beginStreaming(generation: generation)
            }
        }
        #endif
        #else
        accessState = .unavailable
        #endif
    }

    /// Tear the query down when the glance disappears so we are not streaming HR in the background.
    func stop() {
        #if canImport(HealthKit)
        invalidateStreamingGeneration()
        if let query { store.stop(query) }
        query = nil
        expiryTask?.cancel()
        expiryTask = nil
        latestObservation = nil
        bpm = nil
        isRequesting = false
        #endif
    }

    func retry() {
        stop()
        start()
    }

    #if canImport(HealthKit)
    private func desiredStreamingGeneration() -> UInt64 {
        if !desiredStreaming {
            streamGeneration &+= 1
            desiredStreaming = true
        }
        return streamGeneration
    }

    private func invalidateStreamingGeneration() {
        desiredStreaming = false
        streamGeneration &+= 1
    }

    private func isCurrentStreamingGeneration(_ generation: UInt64) -> Bool {
        desiredStreaming && streamGeneration == generation
    }

    private func beginStreaming(generation: UInt64) {
        guard isCurrentStreamingGeneration(generation), let hrType, query == nil else { return }
        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-WatchLiveHRPolicy.maximumSampleAge),
            end: nil,
            options: .strictEndDate
        )
        // Anchored query: an initial results handler plus an updateHandler that fires as new samples land,
        // so the readout tracks the wrist live while the screen is on.
        let q = HKAnchoredObjectQuery(type: hrType,
                                      predicate: predicate,
                                      anchor: nil,
                                      limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, error in
            Self.publishNewest(
                samples,
                error: error,
                reportNoSample: true,
                generation: generation,
                to: self
            )
        }
        q.updateHandler = { [weak self] _, samples, _, _, error in
            Self.publishNewest(
                samples,
                error: error,
                reportNoSample: false,
                generation: generation,
                to: self
            )
        }
        query = q
        store.execute(q)
    }

    nonisolated private static func newestUsableSample(
        _ samples: [HKSample]?,
        now: Date
    ) -> (endDate: Date, bpm: Int)? {
        let unit = HKUnit.count().unitDivided(by: .minute())
        return (samples ?? [])
            .compactMap { sample -> (endDate: Date, bpm: Int)? in
                guard let sample = sample as? HKQuantitySample else { return nil }
                let age = now.timeIntervalSince(sample.endDate)
                guard age >= 0 && age <= WatchLiveHRPolicy.maximumSampleAge else { return nil }

                let value = sample.quantity.doubleValue(for: unit)
                guard let rounded = Int(exactly: value.rounded()),
                      WatchLiveHRPolicy.plausibleBPM.contains(rounded) else {
                    return nil
                }
                return (endDate: sample.endDate, bpm: rounded)
            }
            .max(by: { $0.endDate < $1.endDate })
    }

    /// Pull the newest usable sample out of a batch and publish its BPM. Reads can arrive on a
    /// background queue, so publish on the main actor.
    nonisolated private static func publishNewest(
        _ samples: [HKSample]?,
        error: Error?,
        reportNoSample: Bool,
        generation: UInt64,
        to owner: WatchLiveHR?
    ) {
        if error != nil {
            Task { @MainActor [weak owner] in
                guard let owner, owner.isCurrentStreamingGeneration(generation) else { return }
                owner.bpm = nil
                owner.latestObservation = nil
                owner.accessState = .queryFailed
            }
            return
        }
        let now = Date()
        guard let latest = Self.newestUsableSample(samples, now: now) else {
            guard reportNoSample else { return }
            Task { @MainActor [weak owner] in
                guard let owner, owner.isCurrentStreamingGeneration(generation) else { return }
                owner.bpm = nil
                owner.latestObservation = nil
                owner.accessState = .noReadableSample
            }
            return
        }
        Task { @MainActor [weak owner] in
            guard let owner, owner.isCurrentStreamingGeneration(generation) else { return }
            owner.bpm = latest.bpm
            owner.latestObservation = latest.endDate
            owner.accessState = .available
            owner.scheduleExpiry(observedAt: latest.endDate, generation: generation)
        }
    }

    private func scheduleExpiry(observedAt: Date, generation: UInt64) {
        expiryTask?.cancel()
        let delay = max(
            0,
            observedAt.addingTimeInterval(WatchLiveHRPolicy.maximumSampleAge).timeIntervalSinceNow
        )
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.isCurrentStreamingGeneration(generation),
                  self.latestObservation == observedAt else { return }
            self.bpm = nil
            self.latestObservation = nil
            self.accessState = .noReadableSample
        }
    }
    #endif
}
