import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Auto-detected workout prompt (Today screen)
//
// Today surface for automatic-activity modes. Ask presents the existing Save/dismiss nudge.
// A dormant future auto-save path may persist only a calibrated confidence-gated candidate, then presents
// a durable Keep / Not a workout review. A weaker candidate still asks. Off performs no scan.

struct AutoWorkoutCard: View {

    @EnvironmentObject var repo: Repository

    /// Empty invokes the legacy-safe resolver (old true → Ask, old false → Off, fresh → Ask).
    @AppStorage(PuffinExperiment.autoWorkoutModeKey) private var storedModeRaw = ""

    /// The current suggestion, loaded in `.task`. nil → nothing to show.
    @State private var candidate: DetectedWorkout?
    @State private var autoSavedReview: AutoWorkoutReview?
    /// Hide immediately on Save/X without waiting for the next reload (avoids a flash of the old card).
    @State private var handledThisSession = false
    /// Guards the Save button while the write is in flight.
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        Group {
            if !handledThisSession, let review = autoSavedReview {
                reviewCard(review)
            } else if currentMode != .off, !handledThisSession, let w = candidate {
                card(for: w)
            }
        }
        // Re-scan whenever data refreshes or the three-way mode changes.
        .task(id: AutoWorkoutLoadKey(seq: repo.refreshSeq, mode: currentMode.rawValue)) {
            await reload()
        }
        .alert("Workout wasn't saved", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "Please try again.")
        }
    }

    private var currentMode: PuffinExperiment.AutoWorkoutMode {
        // Keep the AppStorage dependency so the card reloads when Settings changes, but resolve through
        // the side-effect-free migration seam: a retired `autoSave` value behaves as approval-first Ask.
        _ = storedModeRaw
        return PuffinExperiment.resolvedAutoWorkoutMode()
    }

    @ViewBuilder
    private func card(for w: DetectedWorkout) -> some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(suggestionTitle(w))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button {
                        dismiss(w)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(NoopMetrics.space1)
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                    .accessibilityLabel("Dismiss this workout suggestion")
                }

                Text(promptText(w))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = w.suggestedClass, let confidence = w.suggestionConfidence {
                    Text("Experimental type hint · \(className(hint)) · \(Int((confidence * 100).rounded()))% signal confidence")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: NoopMetrics.space3) {
                    Button {
                        save(w)
                    } label: {
                        Label(w.suggestedClass.map { "Save as \(className($0))" } ?? "Save it",
                              systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(saving)

                    Button("Not a workout") { dismiss(w) }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func reviewCard(_ review: AutoWorkoutReview) -> some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Workout saved automatically")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                }

                Text(reviewText(review))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Keep it here, mark it as not a workout, or edit its time and activity type anytime in Workouts. Detected workouts are labelled NOOP, not Manual.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: NoopMetrics.space3) {
                    Button("Keep") { keep(review) }
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)
                        .disabled(saving)

                    Button("Not a workout", role: .destructive) { undo(review) }
                        .buttonStyle(.bordered)
                        .disabled(saving)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func reviewText(_ review: AutoWorkoutReview) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(review.startSec))
        let end = Date(timeIntervalSince1970: TimeInterval(review.endSec))
        let duration = max(1, (review.endSec - review.startSec) / 60)
        return String(localized: "NOOP detected \(review.sport) from \(Self.timeFmt.string(from: start))-\(Self.timeFmt.string(from: end)) (avg HR \(review.avgBpm), \(duration) min).")
    }

    /// "Looks like a workout [yesterday ]around 14:05–14:32 (avg HR 148, 27 min). Save it?"
    /// Three whole-phrase variants (today / yesterday / dated, #719) so translators see complete
    /// sentences rather than a stitched day-label fragment.
    private func promptText(_ w: DetectedWorkout) -> String {
        let startDate = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        let start = Self.timeFmt.string(from: startDate)
        let end = Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(w.endSec)))
        let cal = Calendar.current
        if cal.isDateInToday(startDate) {
            return String(localized: "Looks like a workout around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
        }
        if cal.isDateInYesterday(startDate) {
            return String(localized: "Looks like a workout yesterday around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
        }
        return String(localized: "Looks like a workout on \(Self.dateFmt.string(from: startDate)) around \(start)-\(end) (avg HR \(w.avgBpm), \(w.durationMin) min). Save it?")
    }

    private func suggestionTitle(_ w: DetectedWorkout) -> String {
        w.suggestedClass.map { "Possible \(className($0))" } ?? String(localized: "Looks like a workout")
    }

    private func className(_ value: CoarseWorkoutClass) -> String {
        switch value {
        case .walk: return String(localized: "Walk")
        case .run: return String(localized: "Run")
        case .strength: return String(localized: "Strength")
        case .cycle: return String(localized: "Cycling")
        case .ski: return String(localized: "Skiing")
        case .other: return String(localized: "Workout")
        }
    }

    private func reload() async {
        if let pending = await repo.pendingAutoWorkoutReview() {
            autoSavedReview = pending
            candidate = nil
            handledThisSession = false
            return
        }
        autoSavedReview = nil
        guard currentMode != .off else { candidate = nil; return }
        let next = await repo.autoDetectCandidate()
        if currentMode == .autoSave,
           let next,
           AutoWorkoutAutomationPolicy.shouldAutoSave(next) {
            if await repo.saveDetectedWorkout(next, markForReview: true) {
                AutoWorkoutNotifications.removeHandled()
                await repo.refresh()
                await AutoWorkoutNotifications.postAutoSavedIfAuthorized(
                    startSec: next.startSec, endSec: next.endSec)
                autoSavedReview = await repo.pendingAutoWorkoutReview()
                candidate = nil
                handledThisSession = false
                return
            }
        }
        // A fresh scan resets the session guard so a NEW window can surface after one is handled.
        if next != candidate { handledThisSession = false }
        candidate = next
    }

    private func save(_ w: DetectedWorkout) {
        saving = true
        Task {
            if await repo.saveDetectedWorkout(w) {
                AutoWorkoutNotifications.removeHandled()
                handledThisSession = true
                candidate = nil
                await repo.refresh()   // surfaces the new workout + drops it from re-suggestion
            } else {
                // Keep the suggestion visible so a failed local write is never mistaken for success.
                saveError = "NOOP could not save this workout locally. The suggestion is still here so you can retry."
            }
            saving = false
        }
    }

    private func dismiss(_ w: DetectedWorkout) {
        guard !saving else { return }
        repo.dismissDetectedSuggestion(w)
        AutoWorkoutNotifications.removeHandled()
        handledThisSession = true
        candidate = nil
    }

    private func keep(_ review: AutoWorkoutReview) {
        guard !saving else { return }
        AutoWorkoutReviewStore.clear(startSec: review.startSec)
        AutoWorkoutNotifications.removeHandled()
        autoSavedReview = nil
        handledThisSession = true
    }

    private func undo(_ review: AutoWorkoutReview) {
        guard !saving else { return }
        saving = true
        Task {
            await repo.dismissDetected(review.row)
            AutoWorkoutReviewStore.clear(startSec: review.startSec)
            AutoWorkoutNotifications.removeHandled()
            autoSavedReview = nil
            handledThisSession = true
            await repo.refresh()
            saving = false
        }
    }

    /// HH:mm in the user's locale/timezone.
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Localized medium date ("Jun 23, 2026") for a bout older than yesterday.
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Reload key: a new sync (seq) or a toggle flip re-runs detection.
private struct AutoWorkoutLoadKey: Equatable {
    let seq: Int
    let mode: String
}
