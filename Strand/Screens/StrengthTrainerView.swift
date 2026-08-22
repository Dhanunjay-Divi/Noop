import StrandDesign
import SwiftUI
import WhoopStore
#if os(iOS)
import UIKit
#endif

/// Local-first strength logging. Generic `WorkoutRow` history remains the imported/cardio summary
/// layer; this screen owns normalized exercises, routines, sessions, and sets.
struct StrengthTrainerView: View {
    private struct EditorTarget: Identifiable {
        let snapshot: StrengthSessionSnapshot
        let id: String

        init(_ snapshot: StrengthSessionSnapshot) {
            self.snapshot = snapshot
            id = snapshot.session.id
        }
    }

    private struct ExerciseDetailTarget: Identifiable {
        let exercise: StrengthExerciseRow
        let history: [StrengthExerciseHistoryPoint]

        var id: String { exercise.id }
    }

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.massKey) private var massUnitRaw = ""

    @State private var snapshot: StrengthTrainerSnapshot?
    @State private var loading = true
    @State private var starting = false
    @State private var editor: EditorTarget?
    @State private var exerciseDetail: ExerciseDetailTarget?
    @State private var deleteCandidate: StrengthSessionSnapshot?
    @State private var errorMessage: String?
    @State private var reloadToken = 0
    @AppStorage("strength.goal.weeklySessions") private var weeklySessionGoal = 3
    @AppStorage("strength.goal.weeklySets") private var weeklySetGoal = 12
    #if DEBUG
    @State private var didHandleDemoEditorRoute = false
    #endif

    private var massUnit: MassUnit {
        UnitPrefs.resolveMass(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: massUnitRaw
        )
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: "Strength Trainer",
                subtitle: "Routines, sets, reps, rest, and factual records—private on this device.",
                onRefresh: { await load() },
                topBackground: liquidScaffoldSky()
            ) {
                if let snapshot {
                    if let active = snapshot.activeSession {
                        activeSessionCard(active)
                    }
                    startSection(snapshot)
                    weeklyGoalsSection(snapshot)
                    summarySection(snapshot.summary)
                    muscleFocusSection(snapshot)
                    routineSection(snapshot)
                    exerciseProgressSection(snapshot)
                    historySection(snapshot)
                    honestyCard
                } else if loading {
                    ScreenStateCard(
                        kind: .loading,
                        title: "Loading strength log",
                        message: "Reading your private routines, sessions, and sets from this device."
                    )
                } else {
                    ScreenStateCard(
                        kind: .error,
                        title: "Strength log unavailable",
                        message: "NOOP could not read the private strength log on this device.",
                        actionTitle: "Try again",
                        action: { Task { await load() } }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: reloadToken) {
            await load()
            #if DEBUG
            await openDemoEditorIfNeeded()
            #endif
        }
        .sheet(item: $editor, onDismiss: { reloadToken += 1 }) { target in
            if let snapshot {
                StrengthSessionEditor(
                    initial: target.snapshot,
                    exercises: snapshot.exercises,
                    routines: snapshot.routines,
                    massUnit: massUnit
                )
                .environmentObject(repo)
                #if os(iOS)
                .noopSheetPresentation(largeFirst: true)
                #else
                .frame(minWidth: 720, idealWidth: 820, minHeight: 680, idealHeight: 820)
                #endif
            }
        }
        .sheet(item: $exerciseDetail) { target in
            StrengthExerciseProgressView(
                exercise: target.exercise,
                history: target.history,
                massUnit: massUnit
            )
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #endif
        }
        .confirmationDialog(
            "Delete this strength session?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete session", role: .destructive) {
                guard let candidate = deleteCandidate else { return }
                deleteCandidate = nil
                Task { await delete(candidate) }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("This removes its exercises and sets from the private strength log. Imported workout history is unchanged.")
        }
        .alert("Strength Trainer", isPresented: Binding(
            get: { errorMessage != nil && snapshot != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func startSection(_ data: StrengthTrainerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("Start training", overline: "Manual log")
            NoopCard(tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    HStack(alignment: .top, spacing: NoopMetrics.space3) {
                        SemanticBodyIllustration(
                            .workout(systemImage: "figure.strengthtraining.traditional"),
                            size: 50,
                            tint: StrandPalette.effortColor,
                            isActive: data.activeSession != nil
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Log the work you actually did")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Add exercises and complete sets by hand. NOOP does not infer reps or load from noisy motion data.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    NoopButton(
                        data.activeSession == nil ? "Start empty workout" : "Resume active workout",
                        systemImage: data.activeSession == nil ? "plus" : "play.fill",
                        kind: .primary,
                        fullWidth: true
                    ) {
                        if let active = data.activeSession {
                            editor = EditorTarget(active)
                        } else {
                            Task { await startSession(routine: nil) }
                        }
                    }
                    .disabled(starting)
                }
            }
        }
    }

    private func activeSessionCard(_ active: StrengthSessionSnapshot) -> some View {
        NoopCard(tint: StrandPalette.statusWarning) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "timer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(StrandPalette.statusWarning)
                    .frame(width: 42, height: 42)
                    .background(StrandPalette.statusWarning.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workout in progress")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(String.localizedStringWithFormat(
                        String(localized: "%lld completed sets · started %@"),
                        active.sets.filter { $0.completedAt != nil }.count,
                        date(active.session.startedAt)
                    ))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Button("Resume") { editor = EditorTarget(active) }
                    .buttonStyle(NoopButtonStyle(.secondary))
            }
        }
    }

    private func summarySection(_ summary: StrengthSummary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("All-time work", overline: "Strength summary")
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: NoopMetrics.space3
            ) {
                StatTile(label: "Sessions", value: "\(summary.sessionCount)",
                         caption: "finished", accent: StrandPalette.effortColor)
                StatTile(label: "Completed sets", value: "\(summary.completedSetCount)",
                         caption: "manual", accent: StrandPalette.accent)
                StatTile(label: "Reps", value: summary.totalReps.formatted(),
                         caption: "recorded", accent: StrandPalette.metricCyan)
                StatTile(
                    label: "Loaded volume",
                    value: summary.loadedVolumeSetCount == 0
                        ? "—"
                        : UnitFormatter.massFromKilograms(summary.loadedVolumeKg, unit: massUnit),
                    caption: summary.loadedVolumeSetCount == 0
                        ? "needs load + reps"
                        : String.localizedStringWithFormat(
                            String(localized: "%lld loaded sets"),
                            summary.loadedVolumeSetCount
                        ),
                    accent: StrandPalette.metricPurple
                )
            }
        }
    }

    private func weeklyGoalsSection(_ data: StrengthTrainerSnapshot) -> some View {
        let range = currentWeekRange
        let progress = StrengthProgressCalculator.weeklyProgress(
            sessions: data.sessions,
            from: range.from,
            to: range.to
        )
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("This week", overline: "Your goals")
            NoopCard(tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    goalRow(
                        title: "Strength sessions",
                        completed: progress.sessionCount,
                        goal: weeklySessionGoal,
                        range: 1...14,
                        decrementLabel: "Reduce weekly session goal",
                        incrementLabel: "Increase weekly session goal",
                        onChange: { weeklySessionGoal = $0 }
                    )
                    Divider().overlay(StrandPalette.hairline)
                    goalRow(
                        title: "Completed sets",
                        completed: progress.completedSetCount,
                        goal: weeklySetGoal,
                        range: 1...100,
                        decrementLabel: "Reduce weekly set goal",
                        incrementLabel: "Increase weekly set goal",
                        onChange: { weeklySetGoal = $0 }
                    )
                    HStack(spacing: NoopMetrics.space4) {
                        Label(
                            String.localizedStringWithFormat(
                                String(localized: "appwide.strength.reps_format"),
                                progress.totalReps
                            ),
                            systemImage: "repeat"
                        )
                        if progress.loadedVolumeKg > 0 {
                            Label(
                                UnitFormatter.massFromKilograms(
                                    progress.loadedVolumeKg,
                                    unit: massUnit
                                ),
                                systemImage: "scalemass"
                            )
                        }
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func goalRow(
        title: String,
        completed: Int,
        goal: Int,
        range: ClosedRange<Int>,
        decrementLabel: String,
        incrementLabel: String,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(completed) of \(goal)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        onChange(max(range.lowerBound, goal - 1))
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .disabled(goal <= range.lowerBound)
                    .accessibilityLabel(decrementLabel)
                    Text("\(goal)")
                        .font(StrandFont.number(17))
                        .frame(minWidth: 28)
                        .monospacedDigit()
                    Button {
                        onChange(min(range.upperBound, goal + 1))
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .disabled(goal >= range.upperBound)
                    .accessibilityLabel(incrementLabel)
                }
                .foregroundStyle(StrandPalette.accent)
            }
            ProgressView(
                value: Double(min(completed, goal)),
                total: Double(max(goal, 1))
            )
            .tint(completed >= goal ? StrandPalette.statusPositive : StrandPalette.effortColor)
        }
    }

    private func muscleFocusSection(_ data: StrengthTrainerSnapshot) -> some View {
        let range = currentWeekRange
        let focus = StrengthProgressCalculator.muscleFocus(
            exercises: data.exercises,
            sessions: data.sessions,
            from: range.from,
            to: range.to
        )
        let maximum = max(focus.first?.weightedSetExposure ?? 0, 1)
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("appwide.strength.muscle_map", overline: "This week's set exposure")
            if focus.isEmpty {
                ScreenStateCard(
                    kind: .empty,
                    title: "No muscle exposure logged this week",
                    message: "Complete manual sets to see where your training has been concentrated.",
                    symbol: "figure.strengthtraining.traditional"
                )
            } else {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        HStack(alignment: .top, spacing: NoopMetrics.space3) {
                            Image(systemName: "figure.arms.open")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(StrandPalette.effortColor)
                                .frame(width: 48, height: 48)
                                .background(StrandPalette.surfaceInset, in: Circle())
                                .accessibilityHidden(true)
                            Text("appwide.strength.muscle_map_explanation")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(focus.prefix(8)) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(strengthMuscleName(item.muscle))
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Spacer()
                                    Text(
                                        item.weightedSetExposure.formatted(
                                            .number.precision(.fractionLength(0...1))
                                        )
                                    )
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .monospacedDigit()
                                }
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(StrandPalette.surfaceInset)
                                        .overlay(alignment: .leading) {
                                            Capsule()
                                                .fill(StrandPalette.effortColor)
                                                .frame(
                                                    width: proxy.size.width
                                                        * item.weightedSetExposure / maximum
                                                )
                                        }
                                }
                                .frame(height: 7)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    private func exerciseProgressSection(_ data: StrengthTrainerSnapshot) -> some View {
        let rows = data.exercises.compactMap { exercise -> ExerciseDetailTarget? in
            let history = StrengthProgressCalculator.exerciseHistory(
                exerciseId: exercise.id,
                sessions: data.sessions
            )
            return history.isEmpty ? nil : ExerciseDetailTarget(exercise: exercise, history: history)
        }
        .sorted {
            let lhs = $0.history.first?.startedAt ?? 0
            let rhs = $1.history.first?.startedAt ?? 0
            if lhs != rhs { return lhs > rhs }
            return $0.exercise.name < $1.exercise.name
        }

        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader(
                "appwide.strength.exercise_records",
                overline: "History and PRs",
                trailing: rows.isEmpty ? nil : "\(rows.count)"
            )
            if rows.isEmpty {
                ScreenStateCard(
                    kind: .empty,
                    title: "No exercise records yet",
                    message: "Finish a workout to build factual load, rep, and set-volume records.",
                    symbol: "chart.line.uptrend.xyaxis"
                )
            } else {
                NoopCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, target in
                            Button {
                                exerciseDetail = target
                            } label: {
                                HStack(spacing: NoopMetrics.space3) {
                                    Image(systemName: "chart.line.uptrend.xyaxis")
                                        .foregroundStyle(StrandPalette.effortColor)
                                        .frame(width: 34, height: 34)
                                        .background(StrandPalette.surfaceInset, in: Circle())
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(strengthExerciseName(target.exercise))
                                            .font(StrandFont.headline)
                                            .foregroundStyle(StrandPalette.textPrimary)
                                        Text(exerciseRecordSummary(target.history))
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                .padding(NoopMetrics.space4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index < rows.count - 1 {
                                Divider().padding(.leading, 68)
                                    .foregroundStyle(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private var currentWeekRange: (from: Int, to: Int) {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .weekOfYear, for: Date())
        let start = interval?.start ?? calendar.startOfDay(for: Date())
        let end = interval?.end.addingTimeInterval(-1) ?? Date()
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }

    private func exerciseRecordSummary(_ history: [StrengthExerciseHistoryPoint]) -> String {
        let maxLoad = history.compactMap(\.maxLoadKg).max()
        let maxReps = history.map(\.totalReps).max()
        var parts = ["\(history.count) sessions"]
        if let maxLoad {
            parts.append("heaviest \(UnitFormatter.massFromKilograms(maxLoad, unit: massUnit))")
        }
        if let maxReps { parts.append("up to \(maxReps) reps/session") }
        return parts.joined(separator: " · ")
    }

    private func routineSection(_ data: StrengthTrainerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader(
                "Routines",
                overline: "Repeatable plans",
                trailing: data.routines.isEmpty ? nil : "\(data.routines.count)"
            )
            if data.routines.isEmpty {
                ScreenStateCard(
                    kind: .empty,
                    title: "No routines yet",
                    message: "Build a workout, then choose Save as routine. Routines store targets—not claims about what you completed.",
                    symbol: "list.bullet.clipboard"
                )
            } else {
                NoopCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(data.routines.enumerated()), id: \.element.routine.id) { index, routine in
                            Button {
                                Task { await startSession(routine: routine) }
                            } label: {
                                HStack(spacing: NoopMetrics.space3) {
                                    Image(systemName: "list.bullet.rectangle")
                                        .foregroundStyle(StrandPalette.effortColor)
                                        .frame(width: 34, height: 34)
                                        .background(StrandPalette.surfaceInset, in: Circle())
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(routine.routine.name)
                                            .font(StrandFont.headline)
                                            .foregroundStyle(StrandPalette.textPrimary)
                                        Text(routineDetail(routine, exercises: data.exercises))
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(StrandPalette.effortColor)
                                }
                                .padding(NoopMetrics.space4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(starting || data.activeSession != nil)
                            if index < data.routines.count - 1 {
                                Divider().padding(.leading, 68).foregroundStyle(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private func historySection(_ data: StrengthTrainerSnapshot) -> some View {
        let finished = data.sessions.filter { $0.session.endedAt != nil }
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader(
                "Recent sessions",
                overline: "Editable history",
                trailing: finished.isEmpty ? nil : "\(finished.count)"
            )
            if finished.isEmpty {
                ScreenStateCard(
                    kind: .empty,
                    title: "No finished strength sessions",
                    message: "Your completed workouts will appear here with sets, reps, and external load.",
                    symbol: "dumbbell"
                )
            } else {
                NoopCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(finished.prefix(20).enumerated()), id: \.element.session.id) { index, session in
                            HStack(spacing: NoopMetrics.space3) {
                                Button {
                                    editor = EditorTarget(session)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(session.session.name ?? String(localized: "Strength workout"))
                                                .font(StrandFont.headline)
                                                .foregroundStyle(StrandPalette.textPrimary)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(date(session.session.startedAt))
                                                .font(StrandFont.caption)
                                                .foregroundStyle(StrandPalette.textTertiary)
                                        }
                                        Text(sessionDetail(session, exercises: data.exercises))
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Menu {
                                    Button("Edit session") { editor = EditorTarget(session) }
                                    Button("Delete session", role: .destructive) {
                                        deleteCandidate = session
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel("Session actions")
                            }
                            .padding(.horizontal, NoopMetrics.space4)
                            .padding(.vertical, NoopMetrics.space3)
                            if index < min(finished.count, 20) - 1 {
                                Divider().padding(.leading, NoopMetrics.space4)
                                    .foregroundStyle(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private var honestyCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Label("What these numbers mean", systemImage: "checkmark.shield")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Loaded volume is external load × reps for completed sets only. Bodyweight and timed sets still count, but NOOP never invents tonnage or an estimated one-rep max.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() async {
        loading = true
        do {
            snapshot = try await repo.strengthTrainerSnapshot()
            errorMessage = nil
        } catch {
            if snapshot == nil { errorMessage = error.localizedDescription }
        }
        loading = false
    }

    private func startSession(routine: StrengthRoutineSnapshot?) async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let saved = try await repo.startStrengthSession(routineID: routine?.routine.id)
            reloadToken += 1
            editor = EditorTarget(saved)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if DEBUG
    /// Optional simulator/screenshot route. It opens the real editor and uses the same persistence
    /// path as the Start/Resume control, so visual QA covers the production flow rather than a mock.
    private func openDemoEditorIfNeeded() async {
        guard !didHandleDemoEditorRoute,
              ProcessInfo.processInfo.arguments.contains("--demo-strength-editor"),
              let snapshot else { return }
        didHandleDemoEditorRoute = true
        if let active = snapshot.activeSession {
            editor = EditorTarget(active)
        } else {
            await startSession(routine: nil)
        }
    }
    #endif

    private func delete(_ candidate: StrengthSessionSnapshot) async {
        do {
            _ = try await repo.removeStrengthSession(id: candidate.session.id)
            reloadToken += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func routineDetail(
        _ routine: StrengthRoutineSnapshot,
        exercises: [StrengthExerciseRow]
    ) -> String {
        let names = routine.exercises.compactMap { row in
            exercises.first(where: { $0.id == row.exerciseId }).map(strengthExerciseName)
        }
        let sets = routine.exercises.reduce(0) { $0 + $1.targetSets }
        return String.localizedStringWithFormat(
            String(localized: "%@ · %lld target sets"),
            names.joined(separator: " · "),
            sets
        )
    }

    private func sessionDetail(
        _ session: StrengthSessionSnapshot,
        exercises: [StrengthExerciseRow]
    ) -> String {
        let completed = session.sets.filter { $0.completedAt != nil }
        let names = orderedExerciseIDs(session.sets).compactMap { id in
            exercises.first(where: { $0.id == id }).map(strengthExerciseName)
        }
        let volume = completed.compactMap(\.volumeKg).reduce(0, +)
        let reps = completed.compactMap(\.reps).reduce(0, +)
        if volume > 0 {
            return String.localizedStringWithFormat(
                String(localized: "%lld sets · %lld reps · %@ loaded volume · %@"),
                completed.count,
                reps,
                UnitFormatter.massFromKilograms(volume, unit: massUnit),
                names.joined(separator: ", ")
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "%lld sets · %lld reps · %@"),
            completed.count,
            reps,
            names.joined(separator: ", ")
        )
    }

    private func orderedExerciseIDs(_ sets: [StrengthSetRow]) -> [String] {
        var seen = Set<String>()
        return sets.sorted { ($0.exercisePosition, $0.setPosition) < ($1.exercisePosition, $1.setPosition) }
            .compactMap { seen.insert($0.exerciseId).inserted ? $0.exerciseId : nil }
    }

    private func date(_ seconds: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds))
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct StrengthExerciseBlock: Identifiable {
    let id: String
    var exercise: StrengthExerciseRow
    var position: Int
    var restSeconds: Int
    var sets: [StrengthSetRow]
}

private struct StrengthSessionEditor: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    let exercises: [StrengthExerciseRow]
    let routines: [StrengthRoutineSnapshot]
    let massUnit: MassUnit

    @State private var session: StrengthSessionRow
    @State private var blocks: [StrengthExerciseBlock]
    @State private var exercisePicker = false
    @State private var routineName = ""
    @State private var showingRoutinePrompt = false
    @State private var saving = false
    @State private var restUntil: Date?
    @State private var errorMessage: String?

    init(
        initial: StrengthSessionSnapshot,
        exercises: [StrengthExerciseRow],
        routines: [StrengthRoutineSnapshot],
        massUnit: MassUnit
    ) {
        self.exercises = exercises
        self.routines = routines
        self.massUnit = massUnit
        _session = State(initialValue: initial.session)

        let sourceRoutine = routines.first { $0.routine.id == initial.session.routineId }
        let grouped = Dictionary(grouping: initial.sets, by: \.exercisePosition)
        let built = grouped.keys.sorted().compactMap { position -> StrengthExerciseBlock? in
            guard let first = grouped[position]?.first,
                  let exercise = exercises.first(where: { $0.id == first.exerciseId })
            else { return nil }
            let prescription = sourceRoutine?.exercises.first {
                $0.position == position && $0.exerciseId == first.exerciseId
            }
            return StrengthExerciseBlock(
                id: "\(position)-\(first.exerciseId)",
                exercise: exercise,
                position: position,
                restSeconds: first.restSeconds ?? prescription?.restSeconds ?? 120,
                sets: (grouped[position] ?? []).sorted { $0.setPosition < $1.setPosition }
            )
        }
        _blocks = State(initialValue: built)
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: session.endedAt == nil ? "Log strength workout" : "Edit strength workout",
                subtitle: "Manual entries stay authoritative. Load is stored in kilograms and displayed in \(massUnit.rawValue).",
                topBackground: liquidScaffoldSky()
            ) {
                sessionHeader
                restTimer
                if blocks.isEmpty {
                    ScreenStateCard(
                        kind: .empty,
                        title: "Add your first exercise",
                        message: "Choose from NOOP’s small starter catalog. Each exercise begins with three editable sets.",
                        symbol: "dumbbell"
                    )
                } else {
                    ForEach($blocks) { $block in
                        exerciseCard($block)
                    }
                }
                NoopButton("Add exercise", systemImage: "plus", kind: .secondary, fullWidth: true) {
                    exercisePicker = true
                }
                footerActions
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { Task { await saveAndDismiss() } }
                        .disabled(saving)
                }
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $exercisePicker) {
            StrengthExercisePicker(
                exercises: exercises.filter { candidate in
                    !blocks.contains(where: { $0.exercise.id == candidate.id })
                },
                onPick: addExercise
            )
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #endif
        }
        .alert("Save as routine", isPresented: $showingRoutinePrompt) {
            TextField("Routine name", text: $routineName)
            Button("Save") { Task { await saveRoutine() } }
                .disabled(routineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The routine will store exercise order, set count, rep targets, and rest—not completed results.")
        }
        .alert("Strength Trainer", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var sessionHeader: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                TextField("Workout name (optional)", text: Binding(
                    get: { session.name ?? "" },
                    set: { session.name = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Workout name")

                HStack {
                    Label(startedLabel, systemImage: "clock")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text(String.localizedStringWithFormat(
                        String(localized: "%lld completed"),
                        completedSetCount
                    ))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.effortColor)
                }
            }
        }
    }

    @ViewBuilder private var restTimer: some View {
        if let restUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(restUntil.timeIntervalSince(context.date).rounded(.up)))
                let clock = "\(remaining / 60):\(String(format: "%02d", remaining % 60))"
                NoopCard(tint: StrandPalette.metricCyan) {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: remaining == 0 ? "checkmark.circle.fill" : "timer")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(StrandPalette.metricCyan)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(remaining == 0 ? "Rest complete" : "Rest timer")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(remaining == 0
                                 ? String(localized: "appwide.strength.ready")
                                 : String.localizedStringWithFormat(
                                    String(localized: "%@ remaining"),
                                    clock
                                 ))
                                .font(StrandFont.number(18))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        if remaining > 0 {
                            Button("+30s") { self.restUntil = restUntil.addingTimeInterval(30) }
                                .buttonStyle(NoopButtonStyle(.tertiary))
                        }
                        Button(remaining == 0 ? "Done" : "Skip") { self.restUntil = nil }
                            .buttonStyle(NoopButtonStyle(.secondary))
                    }
                }
            }
        }
    }

    private func exerciseCard(_ block: Binding<StrengthExerciseBlock>) -> some View {
        NoopCard(padding: 0, tint: StrandPalette.effortColor) {
            VStack(spacing: 0) {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: exerciseSymbol(block.wrappedValue.exercise))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(StrandPalette.effortColor)
                        .frame(width: 38, height: 38)
                        .background(StrandPalette.surfaceInset, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(strengthExerciseName(block.wrappedValue.exercise))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(strengthDescriptorPair(block.wrappedValue.exercise))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Menu {
                        Picker(
                            "Rest",
                            selection: Binding(
                                get: { block.wrappedValue.restSeconds },
                                set: { updateRest(blockID: block.wrappedValue.id, seconds: $0) }
                            )
                        ) {
                            Text("No timer").tag(0)
                            Text("60 seconds").tag(60)
                            Text("90 seconds").tag(90)
                            Text("2 minutes").tag(120)
                            Text("3 minutes").tag(180)
                            Text("5 minutes").tag(300)
                        }
                        Button("Remove exercise", role: .destructive) {
                            removeExercise(id: block.wrappedValue.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Exercise actions")
                }
                .padding(NoopMetrics.space4)

                Divider().foregroundStyle(StrandPalette.hairline)

                HStack(spacing: 8) {
                    Text(String(localized: "strength.column.set", defaultValue: "SET"))
                        .frame(width: 34)
                    Text(String(localized: "strength.column.reps", defaultValue: "REPS"))
                        .frame(maxWidth: .infinity)
                    Text(massUnit.rawValue.uppercased()).frame(maxWidth: .infinity)
                    Text(String(localized: "strength.column.seconds", defaultValue: "SEC"))
                        .frame(maxWidth: .infinity)
                    Text(String(localized: "strength.field.rpe", defaultValue: "RPE"))
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(width: 30, height: 1)
                }
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, NoopMetrics.space3)
                .padding(.vertical, 8)

                ForEach(block.sets) { set in
                    setRow(set, block: block)
                    Divider().padding(.leading, 52).foregroundStyle(StrandPalette.hairline)
                }

                Button {
                    addSet(to: block.wrappedValue.id)
                } label: {
                    Label("Add set", systemImage: "plus.circle")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.effortColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NoopMetrics.space3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func setRow(
        _ set: Binding<StrengthSetRow>,
        block: Binding<StrengthExerciseBlock>
    ) -> some View {
        let completed = set.wrappedValue.completedAt != nil
        return HStack(spacing: 8) {
            Button {
                toggleCompleted(set: set, restSeconds: block.wrappedValue.restSeconds)
            } label: {
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(completed ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                    .frame(width: 34, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                completed
                    ? String(localized: "Mark set incomplete")
                    : String.localizedStringWithFormat(
                        String(localized: "Complete set %lld"),
                        set.wrappedValue.setPosition + 1
                    )
            )

            StrengthNumberField(
                String(localized: "strength.field.reps", defaultValue: "Reps"),
                text: integerBinding(set.reps),
                keyboard: .numberPad
            )
            StrengthNumberField(massUnit.rawValue, text: loadBinding(set.loadKg), keyboard: .decimalPad)
            StrengthNumberField(
                String(localized: "strength.field.seconds", defaultValue: "Sec"),
                text: integerBinding(set.durationS),
                keyboard: .numberPad
            )
            StrengthNumberField(
                String(localized: "strength.field.rpe", defaultValue: "RPE"),
                text: decimalBinding(set.rpe),
                keyboard: .decimalPad
            )

            Menu {
                Picker("Set type", selection: set.setType) {
                    Text(strengthSetType("working")).tag("working")
                    Text(strengthSetType("warmup")).tag("warmup")
                    Text(strengthSetType("drop")).tag("drop")
                    Text(strengthSetType("failure")).tag("failure")
                    Text(strengthSetType("bodyweight")).tag("bodyweight")
                }
                Button("Delete set", role: .destructive) {
                    removeSet(id: set.wrappedValue.id, blockID: block.wrappedValue.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Set actions")
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, 6)
        .background(completed ? StrandPalette.statusPositive.opacity(0.06) : Color.clear)
    }

    private var footerActions: some View {
        VStack(spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Save as routine", systemImage: "list.bullet.clipboard", kind: .secondary) {
                    routineName = session.name ?? ""
                    showingRoutinePrompt = true
                }
                .disabled(blocks.isEmpty || saving)

                NoopButton("Save & close", systemImage: "square.and.arrow.down", kind: .secondary) {
                    Task { await saveAndDismiss() }
                }
                .disabled(saving)
            }
            NoopButton(
                session.endedAt == nil ? "Finish workout" : "Save changes",
                systemImage: "checkmark",
                kind: .primary,
                fullWidth: true
            ) {
                Task { await finish() }
            }
            .disabled(completedSetCount == 0 || saving)
            Text("The rest timer runs while this screen is open. Your set log is saved locally; NOOP does not promise a background alert.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var completedSetCount: Int {
        blocks.flatMap(\.sets).filter { $0.completedAt != nil }.count
    }

    private var startedLabel: String {
        Date(timeIntervalSince1970: TimeInterval(session.startedAt))
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func addExercise(_ exercise: StrengthExerciseRow) {
        exercisePicker = false
        let now = Int(Date().timeIntervalSince1970)
        let position = blocks.count
        let sets = (0..<3).map { index in
            StrengthSetRow(
                id: UUID().uuidString.lowercased(),
                sessionId: session.id,
                exerciseId: exercise.id,
                exercisePosition: position,
                setPosition: index,
                setType: exercise.equipment == "bodyweight" ? "bodyweight" : "working",
                createdAt: now,
                updatedAt: now
            )
        }
        blocks.append(
            StrengthExerciseBlock(
                id: "\(position)-\(exercise.id)",
                exercise: exercise,
                position: position,
                restSeconds: 120,
                sets: sets
            )
        )
        Task { await persist(silently: true) }
    }

    private func addSet(to blockID: String) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let now = Int(Date().timeIntervalSince1970)
        let previous = blocks[index].sets.last
        blocks[index].sets.append(
            StrengthSetRow(
                id: UUID().uuidString.lowercased(),
                sessionId: session.id,
                exerciseId: blocks[index].exercise.id,
                exercisePosition: blocks[index].position,
                setPosition: blocks[index].sets.count,
                setType: previous?.setType ?? "working",
                reps: previous?.reps,
                loadKg: previous?.loadKg,
                durationS: previous?.durationS,
                rpe: nil,
                restSeconds: blocks[index].restSeconds,
                createdAt: now,
                updatedAt: now
            )
        )
        Task { await persist(silently: true) }
    }

    private func removeSet(id: String, blockID: String) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        blocks[index].sets.removeAll { $0.id == id }
        normalizePositions()
        Task { await persist(silently: true) }
    }

    private func removeExercise(id: String) {
        blocks.removeAll { $0.id == id }
        normalizePositions()
        Task { await persist(silently: true) }
    }

    private func normalizePositions() {
        for blockIndex in blocks.indices {
            blocks[blockIndex].position = blockIndex
            for setIndex in blocks[blockIndex].sets.indices {
                blocks[blockIndex].sets[setIndex].exercisePosition = blockIndex
                blocks[blockIndex].sets[setIndex].setPosition = setIndex
                blocks[blockIndex].sets[setIndex].restSeconds = blocks[blockIndex].restSeconds
            }
        }
    }

    private func updateRest(blockID: String, seconds: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        blocks[index].restSeconds = seconds
        for setIndex in blocks[index].sets.indices {
            blocks[index].sets[setIndex].restSeconds = seconds
        }
        Task { await persist(silently: true) }
    }

    private func toggleCompleted(set: Binding<StrengthSetRow>, restSeconds: Int) {
        if set.wrappedValue.completedAt != nil {
            set.wrappedValue.completedAt = nil
            Task { await persist(silently: true) }
            return
        }
        guard set.wrappedValue.reps != nil || set.wrappedValue.durationS != nil else {
            errorMessage = String(localized: "Add reps or seconds before completing this set.")
            return
        }
        let now = Int(Date().timeIntervalSince1970)
        set.wrappedValue.completedAt = now
        set.wrappedValue.updatedAt = now
        if restSeconds > 0 { restUntil = Date().addingTimeInterval(TimeInterval(restSeconds)) }
        Task { await persist(silently: true) }
    }

    private func saveAndDismiss() async {
        if await persist(silently: false) { dismiss() }
    }

    private func finish() async {
        guard completedSetCount > 0 else { return }
        let now = Int(Date().timeIntervalSince1970)
        let latestCompleted = blocks.flatMap(\.sets).compactMap(\.completedAt).max() ?? now
        session.endedAt = now - session.startedAt <= StrengthTrainingContract.maxDurationSeconds
            ? now
            : min(latestCompleted, session.startedAt + StrengthTrainingContract.maxDurationSeconds)
        if await persist(silently: false) { dismiss() }
    }

    @discardableResult
    private func persist(silently: Bool) async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        let now = Int(Date().timeIntervalSince1970)
        session.updatedAt = now
        let rows = blocks.flatMap { block in
            block.sets.map { row in
                var copy = row
                copy.restSeconds = block.restSeconds
                copy.updatedAt = now
                return copy
            }
        }
        do {
            _ = try await repo.saveStrengthSession(session, sets: rows)
            return true
        } catch {
            if !silently { errorMessage = error.localizedDescription }
            return false
        }
    }

    private func saveRoutine() async {
        let name = routineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        let routineID = UUID().uuidString.lowercased()
        let routine = StrengthRoutineRow(
            id: routineID,
            name: name,
            createdAt: now,
            updatedAt: now
        )
        let prescriptions = blocks.map { block -> StrengthRoutineExerciseRow in
            let reps = block.sets.compactMap(\.reps)
            return StrengthRoutineExerciseRow(
                id: UUID().uuidString.lowercased(),
                routineId: routineID,
                exerciseId: block.exercise.id,
                position: block.position,
                targetSets: max(1, block.sets.count),
                targetRepsMin: reps.min(),
                targetRepsMax: reps.max(),
                restSeconds: block.restSeconds,
                createdAt: now,
                updatedAt: now
            )
        }
        do {
            _ = try await repo.saveStrengthRoutine(routine, exercises: prescriptions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func integerBinding(_ value: Binding<Int?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { value.wrappedValue = Int($0.filter(\.isNumber)) }
        )
    }

    private func decimalBinding(_ value: Binding<Double?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue.map { formatNumber($0) } ?? "" },
            set: { value.wrappedValue = parseDecimal($0) }
        )
    }

    private func loadBinding(_ value: Binding<Double?>) -> Binding<String> {
        Binding(
            get: {
                guard let kg = value.wrappedValue else { return "" }
                return formatNumber(massUnit == .pounds ? UnitFormatter.kgToPounds(kg) : kg)
            },
            set: {
                guard let display = parseDecimal($0) else { value.wrappedValue = nil; return }
                value.wrappedValue = massUnit == .pounds
                    ? display / UnitFormatter.poundsPerKilogram
                    : display
            }
        )
    }

    private func parseDecimal(_ text: String) -> Double? {
        let separator = Locale.current.decimalSeparator ?? "."
        let cleaned = text.replacingOccurrences(of: separator, with: ".")
            .filter { $0.isNumber || $0 == "." }
        return Double(cleaned)
    }

    private func formatNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func exerciseSymbol(_ exercise: StrengthExerciseRow) -> String {
        exercise.equipment == "bodyweight" ? "figure.core.training" : "dumbbell.fill"
    }

}

private struct StrengthNumberField: View {
    let label: String
    @Binding var text: String
    let keyboard: UIKeyboardTypeCompat

    init(
        _ label: String,
        text: Binding<String>,
        keyboard: UIKeyboardTypeCompat
    ) {
        self.label = label
        _text = text
        self.keyboard = keyboard
    }

    var body: some View {
        TextField(label, text: $text)
            .font(StrandFont.bodyNumber)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            #if os(iOS)
            .keyboardType(keyboard.value)
            #endif
            .accessibilityLabel(label)
    }
}

private enum UIKeyboardTypeCompat {
    case numberPad
    case decimalPad

    #if os(iOS)
    var value: UIKeyboardType {
        switch self {
        case .numberPad: return .numberPad
        case .decimalPad: return .decimalPad
        }
    }
    #endif
}

private struct StrengthExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    let exercises: [StrengthExerciseRow]
    let onPick: (StrengthExerciseRow) -> Void
    @State private var search = ""

    private var filtered: [StrengthExerciseRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return exercises }
        return exercises.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || strengthExerciseName($0).localizedCaseInsensitiveContains(query)
                || $0.primaryMuscle.localizedCaseInsensitiveContains(query)
                || strengthDescriptor($0.primaryMuscle).localizedCaseInsensitiveContains(query)
                || $0.equipment.localizedCaseInsensitiveContains(query)
                || strengthDescriptor($0.equipment).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { exercise in
                Button {
                    onPick(exercise)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: exercise.equipment == "bodyweight"
                              ? "figure.core.training" : "dumbbell.fill")
                            .foregroundStyle(StrandPalette.effortColor)
                            .frame(width: 34, height: 34)
                            .background(StrandPalette.surfaceInset, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(strengthExerciseName(exercise))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(strengthDescriptorPair(exercise))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Search exercises")
            .navigationTitle("Choose exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("No matching exercises")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Try a muscle, equipment type, or exercise name.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .padding()
                }
            }
        }
    }

}

private struct StrengthExerciseProgressView: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: StrengthExerciseRow
    let history: [StrengthExerciseHistoryPoint]
    let massUnit: MassUnit

    private var heaviestLoadKg: Double? { history.compactMap(\.maxLoadKg).max() }
    private var mostReps: Int? { history.compactMap(\.maxReps).max() }
    private var bestSetVolumeKg: Double? { history.compactMap(\.bestSetVolumeKg).max() }
    private var completedSets: Int { history.reduce(0) { $0 + $1.completedSetCount } }

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: LocalizedStringKey(strengthExerciseName(exercise)),
                subtitle: LocalizedStringKey("appwide.strength.factual_records")
            ) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    SectionHeader("appwide.strength.personal_records", overline: "All time")
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: NoopMetrics.space3
                    ) {
                        StatTile(
                            label: "Heaviest load",
                            value: heaviestLoadKg.map {
                                UnitFormatter.massFromKilograms($0, unit: massUnit)
                            } ?? "—",
                            caption: "external load",
                            accent: StrandPalette.effortColor
                        )
                        StatTile(
                            label: "Most reps",
                            value: mostReps.map(String.init) ?? "—",
                            caption: "one completed set",
                            accent: StrandPalette.accent
                        )
                        StatTile(
                            label: "Best set volume",
                            value: bestSetVolumeKg.map {
                                UnitFormatter.massFromKilograms($0, unit: massUnit)
                            } ?? "—",
                            caption: "load × reps",
                            accent: StrandPalette.metricPurple
                        )
                        StatTile(
                            label: "Completed sets",
                            value: "\(completedSets)",
                            caption: "\(history.count) sessions",
                            accent: StrandPalette.metricCyan
                        )
                    }
                }

                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    SectionHeader("History", overline: "Newest first")
                    NoopCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(history.enumerated()), id: \.element.id) { index, point in
                                HStack(spacing: NoopMetrics.space3) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(
                                            Date(timeIntervalSince1970: TimeInterval(point.startedAt))
                                                .formatted(date: .abbreviated, time: .omitted)
                                        )
                                        .font(StrandFont.headline)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                        Text(historyDetail(point))
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 8)
                                    Text(
                                        String.localizedStringWithFormat(
                                            String(localized: "appwide.strength.sets_format"),
                                            point.completedSetCount
                                        )
                                    )
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .monospacedDigit()
                                }
                                .padding(NoopMetrics.space4)
                                if index < history.count - 1 {
                                    Divider().padding(.leading, NoopMetrics.space4)
                                        .foregroundStyle(StrandPalette.hairline)
                                }
                            }
                        }
                    }
                }

                NoopCard {
                    Label {
                        Text("appwide.strength.direct_records_disclaimer")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } icon: {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(StrandPalette.statusPositive)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func historyDetail(_ point: StrengthExerciseHistoryPoint) -> String {
        var parts = ["\(point.totalReps) reps"]
        if let load = point.maxLoadKg {
            parts.append(
                "heaviest \(UnitFormatter.massFromKilograms(load, unit: massUnit))"
            )
        }
        if let volume = point.bestSetVolumeKg {
            parts.append(
                "best set \(UnitFormatter.massFromKilograms(volume, unit: massUnit))"
            )
        }
        return parts.joined(separator: " · ")
    }
}

private func strengthExerciseName(_ exercise: StrengthExerciseRow) -> String {
    switch exercise.id {
    case "barbell_back_squat":
        return String(localized: "strength.exercise.back_squat", defaultValue: "Back Squat")
    case "barbell_bench_press":
        return String(localized: "strength.exercise.bench_press", defaultValue: "Bench Press")
    case "conventional_deadlift":
        return String(localized: "strength.exercise.deadlift", defaultValue: "Deadlift")
    case "overhead_press":
        return String(localized: "strength.exercise.overhead_press", defaultValue: "Overhead Press")
    case "bent_over_row":
        return String(localized: "strength.exercise.bent_over_row", defaultValue: "Bent-over Row")
    case "pull_up":
        return String(localized: "strength.exercise.pull_up", defaultValue: "Pull-up")
    case "lat_pulldown":
        return String(localized: "strength.exercise.lat_pulldown", defaultValue: "Lat Pulldown")
    case "leg_press":
        return String(localized: "strength.exercise.leg_press", defaultValue: "Leg Press")
    case "romanian_deadlift":
        return String(localized: "strength.exercise.romanian_deadlift", defaultValue: "Romanian Deadlift")
    case "dumbbell_lunge":
        return String(localized: "strength.exercise.dumbbell_lunge", defaultValue: "Dumbbell Lunge")
    case "biceps_curl":
        return String(localized: "strength.exercise.biceps_curl", defaultValue: "Biceps Curl")
    case "triceps_pushdown":
        return String(localized: "strength.exercise.triceps_pushdown", defaultValue: "Triceps Pushdown")
    case "plank":
        return String(localized: "strength.exercise.plank", defaultValue: "Plank")
    default: return exercise.name
    }
}

private func strengthMuscleName(_ storage: String) -> String {
    strengthDescriptor(storage)
}

private func strengthDescriptor(_ storage: String) -> String {
    switch storage {
    case "chest":
        return String(localized: "strength.descriptor.chest", defaultValue: "Chest")
    case "back":
        return String(localized: "strength.descriptor.back", defaultValue: "Back")
    case "shoulders":
        return String(localized: "strength.descriptor.shoulders", defaultValue: "Shoulders")
    case "biceps":
        return String(localized: "strength.descriptor.biceps", defaultValue: "Biceps")
    case "triceps":
        return String(localized: "strength.descriptor.triceps", defaultValue: "Triceps")
    case "forearms":
        return String(localized: "strength.descriptor.forearms", defaultValue: "Forearms")
    case "core":
        return String(localized: "strength.descriptor.core", defaultValue: "Core")
    case "quadriceps":
        return String(localized: "strength.descriptor.quadriceps", defaultValue: "Quadriceps")
    case "hamstrings":
        return String(localized: "strength.descriptor.hamstrings", defaultValue: "Hamstrings")
    case "glutes":
        return String(localized: "strength.descriptor.glutes", defaultValue: "Glutes")
    case "calves":
        return String(localized: "strength.descriptor.calves", defaultValue: "Calves")
    case "full_body":
        return String(localized: "strength.descriptor.full_body", defaultValue: "Full body")
    case "barbell":
        return String(localized: "strength.descriptor.barbell", defaultValue: "Barbell")
    case "dumbbell":
        return String(localized: "strength.descriptor.dumbbell", defaultValue: "Dumbbell")
    case "kettlebell":
        return String(localized: "strength.descriptor.kettlebell", defaultValue: "Kettlebell")
    case "cable":
        return String(localized: "strength.descriptor.cable", defaultValue: "Cable")
    case "machine":
        return String(localized: "strength.descriptor.machine", defaultValue: "Machine")
    case "bodyweight":
        return String(localized: "strength.descriptor.bodyweight", defaultValue: "Bodyweight")
    case "band":
        return String(localized: "strength.descriptor.band", defaultValue: "Band")
    default:
        return String(localized: "strength.descriptor.other", defaultValue: "Other")
    }
}

private func strengthSetType(_ storage: String) -> String {
    switch storage {
    case "warmup":
        return String(localized: "strength.set_type.warmup", defaultValue: "Warm-up")
    case "drop":
        return String(localized: "strength.set_type.drop", defaultValue: "Drop")
    case "failure":
        return String(localized: "strength.set_type.failure", defaultValue: "To failure")
    case "bodyweight":
        return String(localized: "strength.set_type.bodyweight", defaultValue: "Bodyweight")
    default:
        return String(localized: "strength.set_type.working", defaultValue: "Working")
    }
}

private func strengthDescriptorPair(_ exercise: StrengthExerciseRow) -> String {
    String.localizedStringWithFormat(
        String(localized: "%@ · %@"),
        strengthDescriptor(exercise.primaryMuscle),
        strengthDescriptor(exercise.equipment)
    )
}
