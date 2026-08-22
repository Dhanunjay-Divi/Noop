import SwiftUI
import StrandDesign

/// Phone-owned strength routines with a real Watch-to-phone start handoff.
struct WatchStrengthView: View {
    @EnvironmentObject private var store: WatchScoreStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("watch.strength.title", systemImage: "dumbbell.fill")
                    .font(StrandFont.rounded(18, weight: .semibold))
                    .foregroundStyle(StrandPalette.effortColor)

                if let plan = store.strengthPlan {
                    if plan.activeSessionName != nil {
                        activeCard(plan)
                    } else if plan.routines.isEmpty {
                        emptyState
                    } else {
                        ForEach(plan.routines.prefix(5)) { routine in
                            routineButton(routine)
                        }
                    }
                } else {
                    emptyState
                }

                if let message = store.strengthHandoffMessage {
                    Text(message)
                        .font(StrandFont.caption)
                        .foregroundStyle(
                            message == "Started on iPhone"
                                ? StrandPalette.statusPositive
                                : StrandPalette.textSecondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    private func activeCard(_ plan: WatchStrengthPlan) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("watch.strength.in_progress")
                .font(StrandFont.overlineScaled(9))
                .foregroundStyle(StrandPalette.statusWarning)
            Text(plan.activeSessionName ?? String(localized: "watch.strength.workout"))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2)
            Text(String(
                format: String(localized: "watch.strength.set_progress"),
                plan.activeCompletedSets,
                plan.activeTargetSets
            ))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .monospacedDigit()
            ProgressView(
                value: Double(plan.activeCompletedSets),
                total: Double(max(plan.activeTargetSets, 1))
            )
            .tint(StrandPalette.effortColor)
            Text("watch.strength.continue_iphone")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func routineButton(_ routine: WatchStrengthRoutine) -> some View {
        Button {
            store.startStrengthRoutine(id: routine.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(routine.name)
                        .font(StrandFont.subhead)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(String(
                    format: String(localized: "watch.strength.routine_summary"),
                    routine.targetSetCount,
                    routine.exerciseNames.prefix(2).joined(separator: ", ")
                ))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(StrandPalette.effortColor)
        .accessibilityHint(Text("watch.strength.start_hint"))
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "iphone")
                .font(.system(size: 22))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("watch.strength.create_iphone")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("watch.strength.sync_help")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
