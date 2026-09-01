import StrandDesign
import SwiftUI
import WhoopStore
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(iOS)
import UIKit
#endif

/// Local-first strength logging. Generic `WorkoutRow` history remains the imported/cardio summary
/// layer; this screen owns normalized exercises, routines, sessions, and sets.
struct StrengthTrainerView: View {
    private enum GymTab: String, CaseIterable, Identifiable {
        case today
        case plan
        case library
        case progress

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .today: "appwide.gym.tab_today"
            case .plan: "appwide.gym.tab_plan"
            case .library: "appwide.gym.tab_library"
            case .progress: "appwide.gym.tab_progress"
            }
        }
    }

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

    private struct RoutineEditorTarget: Identifiable {
        let routine: StrengthRoutineSnapshot?
        let id: String

        init(_ routine: StrengthRoutineSnapshot? = nil) {
            self.routine = routine
            id = routine?.routine.id ?? "new"
        }
    }

    private struct TodayExercisePlan: Identifiable {
        let prescription: StrengthRoutineExerciseRow
        let exercise: StrengthExerciseRow
        let workout: StrengthWorkoutPrescription

        var id: String { prescription.id }
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
    @State private var exerciseGuide = Self.initialExerciseGuide
    @State private var deleteCandidate: StrengthSessionSnapshot?
    @State private var selectedTab = GymTab.today
    @State private var routineEditor: RoutineEditorTarget?
    @State private var showingProgramBuilder = false
    @State private var didOfferProgramBuilder = false
    @State private var showingCustomExercise = false
    @State private var libraryQuery = ""
    @State private var libraryMuscle = "all"
    @State private var libraryEquipment = "all"
    @State private var bodyMapMode = StrengthBodyMapMode.load
    @State private var selectedFocusMuscle: String?
    @State private var selectedFocusExerciseIDs = Set<String>()
    @State private var errorMessage: String?
    @State private var reloadToken = 0
    @AppStorage("strength.goal.weeklySessions") private var weeklySessionGoal = 3
    @AppStorage("strength.goal.weeklySets") private var weeklySetGoal = 12
    @AppStorage("strength.profile.experience") private var experienceRaw =
        StrengthTrainingExperience.beginner.rawValue
    @AppStorage("strength.profile.style") private var trainingStyleRaw =
        StrengthTrainingStyle.balanced.rawValue
    @AppStorage("strength.profile.sessionMinutes") private var sessionMinutes = 45
    #if DEBUG
    @State private var didHandleDemoEditorRoute = false
    #endif

    private static var initialExerciseGuide: StrengthExerciseRow? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--demo-strength-guide") else { return nil }
        let requestedID = index + 1 < arguments.count
            ? arguments[index + 1]
            : "barbell_back_squat"
        return StrengthTrainingContract.builtInExercises.first { $0.id == requestedID }
        #else
        return nil
        #endif
    }

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
                subtitle: "Routines, sets, reps, rest, and factual records-private on this device.",
                onRefresh: { await load() },
                topBackground: liquidScaffoldSky()
            ) {
                if let snapshot {
                    gymTabPicker
                    switch selectedTab {
                    case .today:
                        if let active = snapshot.activeSession {
                            activeSessionCard(active)
                        }
                        todayPlanSection(snapshot)
                        muscleCoachSection(snapshot)
                        startSection(snapshot)
                        weeklyGoalsSection(snapshot)
                        historySection(snapshot)
                    case .plan:
                        weekScheduleSection(snapshot)
                        routineManagementSection(snapshot)
                    case .library:
                        exerciseLibrarySection(snapshot)
                    case .progress:
                        summarySection(snapshot.summary)
                        muscleFocusSection(snapshot)
                        exerciseProgressSection(snapshot)
                    }
                    if selectedTab == .progress { honestyCard }
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
                    history: snapshot.sessions,
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
        .sheet(item: $exerciseGuide) { exercise in
            StrengthExerciseGuidePreview(exercise: exercise)
            #if os(iOS)
            .noopSheetPresentation(largeFirst: false)
            #endif
        }
        .sheet(item: $routineEditor, onDismiss: { reloadToken += 1 }) { target in
            if let snapshot {
                StrengthRoutineEditor(
                    initial: target.routine,
                    exercises: snapshot.exercises,
                    massUnit: massUnit
                )
                .environmentObject(repo)
                .interactiveDismissDisabled()
                #if os(iOS)
                .noopSheetPresentation(largeFirst: true)
                #endif
            }
        }
        .sheet(isPresented: $showingProgramBuilder, onDismiss: { reloadToken += 1 }) {
            if let snapshot {
                StrengthProgramBuilder(
                    routines: snapshot.routines,
                    onSaved: {
                        showingProgramBuilder = false
                        reloadToken += 1
                    }
                )
                .environmentObject(repo)
                .interactiveDismissDisabled()
                #if os(iOS)
                .noopSheetPresentation(largeFirst: true)
                #endif
            }
        }
        .sheet(isPresented: $showingCustomExercise, onDismiss: { reloadToken += 1 }) {
            StrengthCustomExerciseEditor()
                .environmentObject(repo)
                .interactiveDismissDisabled()
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

    private var gymTabPicker: some View {
        Picker("appwide.gym.gym_view", selection: $selectedTab) {
            ForEach(GymTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("noop.strength.tabs")
    }

    private func todayPlanSection(_ data: StrengthTrainerSnapshot) -> some View {
        let recommendation = adaptiveRecommendation(for: data)
        let routine = recommendation.routineId.flatMap { id in
            data.routines.first { $0.routine.id == id }
        }
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader(
                "appwide.gym.todays_training",
                overline: LocalizedStringKey(Date().formatted(.dateTime.weekday(.wide)))
            )
            if recommendation.reason == .completed {
                NoopCard(tint: StrandPalette.statusPositive) {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(StrandPalette.statusPositive)
                            .frame(width: 42, height: 42)
                            .background(StrandPalette.statusPositive.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Today’s strength work is complete")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Your next target will use the sets you actually completed.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            } else if let routine {
                todayRoutineCard(
                    routine,
                    data: data,
                    makeUpDateKey: recommendation.reason == .makeUp
                        ? recommendation.originallyScheduledDateKey
                        : nil
                )
            } else {
                NoopCard {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(width: 42, height: 42)
                            .background(StrandPalette.surfaceInset, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("appwide.gym.no_routine_scheduled")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("appwide.gym.no_routine_scheduled_body")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        Button("appwide.gym.plan") {
                            if data.routines.isEmpty {
                                showingProgramBuilder = true
                            } else {
                                selectedTab = .plan
                            }
                        }
                            .buttonStyle(NoopButtonStyle(.secondary))
                    }
                }
            }
        }
    }

    private func todayRoutineCard(
        _ routine: StrengthRoutineSnapshot,
        data: StrengthTrainerSnapshot,
        makeUpDateKey: String?
    ) -> some View {
        let plans = todayExercisePlans(for: routine, data: data)
        let totalSets = plans.reduce(0) { $0 + $1.workout.sets.count }
        let durationMinutes = max(
            1,
            Int(ceil(Double(estimatedDurationSeconds(for: plans)) / 60))
        )
        let muscleNames = orderedUnique(
            plans.map { strengthDescriptor($0.exercise.primaryMuscle) }
        )
        return NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: "dumbbell.fill")
                        .foregroundStyle(StrandPalette.effortColor)
                        .frame(width: 42, height: 42)
                        .background(StrandPalette.effortColor.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(routine.routine.name)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "%lld exercises · %lld sets · about %lld min"),
                                plans.count,
                                totalSets,
                                durationMinutes
                            )
                        )
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                }

                if let makeUpDateKey {
                    Label(
                        "Moved from \(displayDateKey(makeUpDateKey)); today was a recovery day.",
                        systemImage: "calendar.badge.clock"
                    )
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !muscleNames.isEmpty {
                    Label(
                        muscleNames.joined(separator: " · "),
                        systemImage: "figure.strengthtraining.traditional"
                    )
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                }

                Divider().foregroundStyle(StrandPalette.hairline)

                ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                    HStack(spacing: NoopMetrics.space3) {
                        Text("\(index + 1)")
                            .font(StrandFont.number(15))
                            .foregroundStyle(StrandPalette.effortColor)
                            .frame(width: 30, height: 30)
                            .background(StrandPalette.surfaceInset, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(strengthExerciseName(plan.exercise))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(todayTargetLabel(plan))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Text(strengthDescriptor(plan.exercise.primaryMuscle))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        Button {
                            exerciseGuide = plan.exercise
                        } label: {
                            Image(systemName: "figure.strengthtraining.traditional")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(StrandPalette.effortColor)
                                .frame(width: 42, height: 42)
                                .background(StrandPalette.surfaceInset, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Exercise guide")
                        .help("Exercise guide")
                    }
                    if index < plans.count - 1 {
                        Divider()
                            .padding(.leading, 42)
                            .foregroundStyle(StrandPalette.hairline)
                    }
                }

                NoopButton(
                    "Start today’s workout",
                    systemImage: "play.fill",
                    kind: .primary,
                    fullWidth: true
                ) {
                    Task { await startSession(routine: routine) }
                }
                .disabled(starting || data.activeSession != nil)
            }
        }
    }

    private func weekScheduleSection(_ data: StrengthTrainerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader(
                "appwide.gym.week_schedule",
                overline: "appwide.gym.repeatable_plan"
            )
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(1...7, id: \.self) { day in
                        let assigned = data.routines.filter {
                            StrengthTrainingContract.scheduledWeekdays(
                                from: $0.routine.scheduledWeekdaysJSON
                            ).contains(day)
                        }
                        HStack(spacing: NoopMetrics.space3) {
                            Text(weekdayName(day))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 96, alignment: .leading)
                            if assigned.isEmpty {
                                Text("appwide.gym.rest")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(StrandPalette.surfaceInset, in: Capsule())
                            } else {
                                Text(assigned.map(\.routine.name).joined(separator: " · "))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.effortColor)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(NoopMetrics.space4)
                        if day < 7 {
                            Divider().padding(.leading, NoopMetrics.space4)
                                .foregroundStyle(StrandPalette.hairline)
                        }
                    }
                }
            }
        }
    }

    private func routineManagementSection(_ data: StrengthTrainerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader(
                "Routines",
                overline: "Sets, targets, and progression",
                trailing: data.routines.isEmpty ? nil : "\(data.routines.count)"
            )
            NoopButton(
                "Build a smart plan",
                systemImage: "sparkles",
                kind: .primary,
                fullWidth: true
            ) {
                showingProgramBuilder = true
            }
            NoopButton("New routine", systemImage: "plus", kind: .secondary, fullWidth: true) {
                routineEditor = RoutineEditorTarget()
            }
            if data.routines.isEmpty {
                ScreenStateCard(
                    kind: .empty,
                    title: "Build your first routine",
                    message: "Choose exercises, targets, warmups, rest, and the days you train.",
                    symbol: "calendar.badge.plus"
                )
            } else {
                NoopCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(data.routines.enumerated()), id: \.element.routine.id) { index, routine in
                            Button {
                                routineEditor = RoutineEditorTarget(routine)
                            } label: {
                                HStack(spacing: NoopMetrics.space3) {
                                    Image(systemName: "list.bullet.clipboard")
                                        .foregroundStyle(StrandPalette.effortColor)
                                        .frame(width: 38, height: 38)
                                        .background(StrandPalette.surfaceInset, in: Circle())
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
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                .padding(NoopMetrics.space4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index < data.routines.count - 1 {
                                Divider().padding(.leading, 68)
                                    .foregroundStyle(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private func exerciseLibrarySection(_ data: StrengthTrainerSnapshot) -> some View {
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = data.exercises.filter { exercise in
            (query.isEmpty
                || strengthExerciseName(exercise).localizedCaseInsensitiveContains(query)
                || strengthDescriptorPair(exercise).localizedCaseInsensitiveContains(query))
                && (libraryMuscle == "all" || exercise.primaryMuscle == libraryMuscle)
                && (libraryEquipment == "all" || exercise.equipment == libraryEquipment)
        }
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader(
                "appwide.gym.exercise_library",
                overline: "appwide.gym.search_and_filter",
                trailing: "\(filtered.count)"
            )
            TextField("Search exercises", text: $libraryQuery)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: NoopMetrics.space3) {
                Menu {
                    Picker("appwide.gym.muscle", selection: $libraryMuscle) {
                        Text("appwide.gym.all_muscles").tag("all")
                        ForEach(StrengthTrainingContract.muscles, id: \.self) {
                            Text(strengthDescriptor($0)).tag($0)
                        }
                    }
                } label: {
                    Label(
                        libraryMuscle == "all"
                            ? String(localized: "appwide.gym.all_muscles")
                            : strengthDescriptor(libraryMuscle),
                        systemImage: "figure.arms.open"
                    )
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                Menu {
                    Picker("appwide.gym.equipment", selection: $libraryEquipment) {
                        Text("appwide.gym.any_equipment").tag("all")
                        ForEach(StrengthTrainingContract.equipment, id: \.self) {
                            Text(strengthDescriptor($0)).tag($0)
                        }
                    }
                } label: {
                    Label(
                        libraryEquipment == "all"
                            ? String(localized: "appwide.gym.any_equipment")
                            : strengthDescriptor(libraryEquipment),
                        systemImage: "slider.horizontal.3"
                    )
                }
                .buttonStyle(NoopButtonStyle(.secondary))
            }
            NoopButton(
                "Create exercise",
                systemImage: "plus",
                kind: .primary,
                fullWidth: true
            ) {
                showingCustomExercise = true
            }
            if filtered.isEmpty {
                ScreenStateCard(
                    kind: .empty,
                    title: "No matching exercises",
                    message: "Change the filters or create an exercise for your movement.",
                    symbol: "magnifyingglass"
                )
            } else {
                LazyVStack(spacing: NoopMetrics.space3) {
                    ForEach(filtered) { exercise in
                        NoopCard {
                            HStack(spacing: NoopMetrics.space3) {
                                Image(systemName: exercise.equipment == "bodyweight"
                                      ? "figure.core.training" : "dumbbell.fill")
                                    .foregroundStyle(StrandPalette.effortColor)
                                    .frame(width: 42, height: 42)
                                    .background(StrandPalette.surfaceInset, in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(strengthExerciseName(exercise))
                                        .font(StrandFont.headline)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text(strengthDescriptorPair(exercise))
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                                Spacer()
                                if exercise.isCustom {
                                Text("appwide.gym.custom")
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.accent)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func isoWeekday(_ date: Date) -> Int {
        let apple = Calendar.current.component(.weekday, from: date)
        return ((apple + 5) % 7) + 1
    }

    private func adaptiveRecommendation(
        for data: StrengthTrainerSnapshot,
        now: Date = Date()
    ) -> StrengthDayRecommendation {
        let calendar = Calendar.current
        let today = StrengthScheduleDay(
            dateKey: localDateKey(now),
            isoWeekday: isoWeekday(now)
        )
        let previous = (1...StrengthAdaptivePlanner.maximumMakeUpAgeDays).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: now).map {
                StrengthScheduleDay(dateKey: localDateKey($0), isoWeekday: isoWeekday($0))
            }
        }
        let completions = data.sessions.compactMap { item -> StrengthRoutineCompletion? in
            guard item.session.endedAt != nil, let routineID = item.session.routineId else {
                return nil
            }
            return StrengthRoutineCompletion(
                dateKey: localDateKey(
                    Date(timeIntervalSince1970: TimeInterval(item.session.startedAt))
                ),
                routineId: routineID
            )
        }
        return StrengthAdaptivePlanner.recommendation(
            today: today,
            previousDaysNearestFirst: previous,
            routines: data.routines,
            completions: completions
        )
    }

    private func localDateKey(_ date: Date) -> String {
        let value = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            value.year ?? 0,
            value.month ?? 0,
            value.day ?? 0
        )
    }

    private func displayDateKey(_ key: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: key) else { return key }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func weekdayName(_ isoDay: Int) -> String {
        let index = isoDay % 7
        return Calendar.current.weekdaySymbols[index]
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
                        ? "-"
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

    private func muscleCoachSection(_ data: StrengthTrainerSnapshot) -> some View {
        let statuses = StrengthProgressCalculator.muscleStatus(
            exercises: data.exercises,
            sessions: data.sessions,
            now: Int(Date().timeIntervalSince1970)
        )
        let matching = focusExercises(for: selectedFocusMuscle, in: data.exercises)
        let selectedStatus = statuses.first { $0.muscle == selectedFocusMuscle }
        let selectedExercises = matching.filter { selectedFocusExerciseIDs.contains($0.id) }

        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("Train by muscle", overline: "Load and recovery")
            NoopCard(tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Picker("Body map", selection: $bodyMapMode) {
                        Text("Load").tag(StrengthBodyMapMode.load)
                        Text("Recovery").tag(StrengthBodyMapMode.recovery)
                    }
                    .pickerStyle(.segmented)

                    StrengthBodyMapView(
                        statuses: statuses,
                        mode: bodyMapMode,
                        selectedMuscle: selectedFocusMuscle
                    ) { muscle in
                        selectFocusMuscle(muscle, exercises: data.exercises)
                    }

                    if let muscle = selectedFocusMuscle {
                        Divider().overlay(StrandPalette.hairline)
                        HStack(alignment: .firstTextBaseline) {
                            Text(strengthMuscleName(muscle))
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            if let selectedStatus {
                                Text(bodyStatusLabel(selectedStatus))
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .monospacedDigit()
                            }
                        }

                        Text(
                            bodyMapMode == .load
                                ? "Completed working sets from the last seven days."
                                : "Estimated from logged sets fading over 72 hours, not a physiological readiness score."
                        )
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                        ForEach(matching.prefix(6)) { exercise in
                            HStack(spacing: NoopMetrics.space3) {
                                Button {
                                    toggleFocusExercise(exercise.id)
                                } label: {
                                    HStack(spacing: NoopMetrics.space3) {
                                        Image(
                                            systemName: selectedFocusExerciseIDs.contains(exercise.id)
                                                ? "checkmark.circle.fill"
                                                : "circle"
                                        )
                                        .font(.system(size: 19, weight: .semibold))
                                        .foregroundStyle(
                                            selectedFocusExerciseIDs.contains(exercise.id)
                                                ? StrandPalette.effortColor
                                                : StrandPalette.textTertiary
                                        )
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(strengthExerciseName(exercise))
                                                .font(StrandFont.headline)
                                                .foregroundStyle(StrandPalette.textPrimary)
                                            Text(strengthDescriptorPair(exercise))
                                                .font(StrandFont.caption)
                                                .foregroundStyle(StrandPalette.textSecondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    exerciseGuide = exercise
                                } label: {
                                    Image(systemName: "figure.strengthtraining.traditional")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(StrandPalette.effortColor)
                                        .frame(width: 40, height: 40)
                                        .background(StrandPalette.surfaceInset, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Exercise guide")
                            }
                        }

                        NoopButton(
                            data.activeSession == nil
                                ? "Start \(selectedExercises.count)-exercise focus"
                                : "Resume active workout",
                            systemImage: data.activeSession == nil ? "play.fill" : "arrow.right",
                            kind: .primary,
                            fullWidth: true
                        ) {
                            if let active = data.activeSession {
                                editor = EditorTarget(active)
                            } else {
                                Task {
                                    await startFocusSession(
                                        muscle: muscle,
                                        exercises: selectedExercises,
                                        data: data
                                    )
                                }
                            }
                        }
                        .disabled(
                            starting
                                || (data.activeSession == nil && selectedExercises.isEmpty)
                        )
                    } else {
                        Text("Select a muscle to build an editable focus workout.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    private func focusExercises(
        for muscle: String?,
        in exercises: [StrengthExerciseRow]
    ) -> [StrengthExerciseRow] {
        guard let muscle else { return [] }
        return exercises.filter { exercise in
            exercise.primaryMuscle == muscle
                || (StrengthTrainingContract.secondaryMuscles(
                    from: exercise.secondaryMusclesJSON
                ) ?? []).contains(muscle)
        }
        .sorted { lhs, rhs in
            let lhsPrimary = lhs.primaryMuscle == muscle
            let rhsPrimary = rhs.primaryMuscle == muscle
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            if lhs.isCustom != rhs.isCustom { return !lhs.isCustom }
            return strengthExerciseName(lhs) < strengthExerciseName(rhs)
        }
    }

    private func selectFocusMuscle(
        _ muscle: String,
        exercises: [StrengthExerciseRow]
    ) {
        selectedFocusMuscle = muscle
        let candidates = focusExercises(for: muscle, in: exercises)
        let limit: Int
        switch sessionMinutes {
        case ...30: limit = 3
        case ...45: limit = 4
        case ...60: limit = 5
        default: limit = 6
        }
        selectedFocusExerciseIDs = Set(candidates.prefix(limit).map(\.id))
    }

    private func toggleFocusExercise(_ id: String) {
        if selectedFocusExerciseIDs.contains(id) {
            selectedFocusExerciseIDs.remove(id)
        } else {
            selectedFocusExerciseIDs.insert(id)
        }
    }

    private func bodyStatusLabel(_ status: StrengthMuscleStatus) -> String {
        switch bodyMapMode {
        case .load:
            return String(
                format: "%.1f weighted sets",
                status.sevenDayExposure
            )
        case .recovery:
            return "\(Int((status.recoveryScore * 100).rounded()))% recovered"
        }
    }

    private func startFocusSession(
        muscle: String,
        exercises: [StrengthExerciseRow],
        data: StrengthTrainerSnapshot
    ) async {
        guard !starting, !exercises.isEmpty else { return }
        if let active = data.activeSession {
            editor = EditorTarget(active)
            return
        }
        starting = true
        defer { starting = false }
        do {
            let experience = StrengthTrainingExperience(rawValue: experienceRaw) ?? .beginner
            let style = StrengthTrainingStyle(rawValue: trainingStyleRaw) ?? .balanced
            let templates = StrengthAdaptivePlanner.focusWorkout(
                exercises: exercises,
                experience: experience,
                style: style,
                sessionMinutes: sessionMinutes
            )
            let now = Int(Date().timeIntervalSince1970)
            let sessionID = UUID().uuidString.lowercased()
            let session = StrengthSessionRow(
                id: sessionID,
                name: "\(strengthMuscleName(muscle)) focus",
                startedAt: now,
                createdAt: now,
                updatedAt: now
            )
            let exerciseByID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
            let sets = try templates.enumerated().flatMap { position, template in
                guard let exercise = exerciseByID[template.exerciseId],
                      let planJSON = StrengthTrainingContract.encodeExercisePlan(template.plan)
                else {
                    throw StrengthTrainingContract.ValidationError.invalidRoutineExercise
                }
                let prescription = StrengthRoutineExerciseRow(
                    id: "focus-\(sessionID)-\(position)",
                    routineId: "focus-\(sessionID)",
                    exerciseId: template.exerciseId,
                    position: position,
                    targetSets: template.targetSets,
                    targetRepsMin: template.targetRepsMin,
                    targetRepsMax: template.targetRepsMax,
                    targetRPE: template.targetRPE,
                    restSeconds: template.restSeconds,
                    planJSON: planJSON,
                    createdAt: now,
                    updatedAt: now
                )
                let planned = StrengthWorkoutPlanner.prescription(
                    exercise: exercise,
                    prescription: prescription,
                    history: data.sessions
                )
                return planned.sets.enumerated().map { setPosition, target in
                    StrengthSetRow(
                        id: UUID().uuidString.lowercased(),
                        sessionId: sessionID,
                        exerciseId: template.exerciseId,
                        exercisePosition: position,
                        setPosition: setPosition,
                        setType: target.setType,
                        reps: target.reps,
                        loadKg: target.loadKg,
                        durationS: target.durationS,
                        restSeconds: StrengthWorkoutPlanner.resolvedRestSeconds(
                            for: target,
                            prescriptionRestSeconds: template.restSeconds,
                            continuesSuperset: false
                        ),
                        createdAt: now,
                        updatedAt: now
                    )
                }
            }
            let draft = StrengthSessionSnapshot(session: session, sets: sets)
            editor = EditorTarget(draft)
            starting = false
            let saved = try await repo.saveStrengthSession(session, sets: sets)
            reloadToken += 1
            editor = EditorTarget(saved)
        } catch {
            errorMessage = error.localizedDescription
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
                    message: "Build a workout, then choose Save as routine. Routines store targets-not claims about what you completed.",
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
            let loaded = try await repo.strengthTrainerSnapshot()
            snapshot = loaded
            errorMessage = nil
            if loaded.routines.isEmpty,
               loaded.activeSession == nil,
               !didOfferProgramBuilder {
                didOfferProgramBuilder = true
                showingProgramBuilder = true
            }
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
            let saved = try await repo.startStrengthSession(
                routineID: routine?.routine.id
            ) { prepared in
                editor = EditorTarget(prepared)
                starting = false
            }
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
            let weekday = isoWeekday(Date())
            let scheduled = snapshot.routines.first {
                StrengthTrainingContract.scheduledWeekdays(
                    from: $0.routine.scheduledWeekdaysJSON
                ).contains(weekday)
            }
            await startSession(routine: scheduled ?? snapshot.routines.first)
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

    private func todayExercisePlans(
        for routine: StrengthRoutineSnapshot,
        data: StrengthTrainerSnapshot
    ) -> [TodayExercisePlan] {
        routine.exercises
            .sorted { $0.position < $1.position }
            .compactMap { prescription in
                guard let exercise = data.exercises.first(where: {
                    $0.id == prescription.exerciseId
                }) else { return nil }
                return TodayExercisePlan(
                    prescription: prescription,
                    exercise: exercise,
                    workout: StrengthWorkoutPlanner.prescription(
                        exercise: exercise,
                        prescription: prescription,
                        history: data.sessions
                    )
                )
            }
    }

    private func estimatedDurationSeconds(for plans: [TodayExercisePlan]) -> Int {
        plans.enumerated().reduce(0) { total, item in
            let (exerciseIndex, plan) = item
            let setSeconds = plan.workout.sets.enumerated().reduce(0) { subtotal, setItem in
                let (setIndex, set) = setItem
                let work = set.durationS ?? min(75, max(20, (set.reps ?? 8) * 4))
                let rest = setIndex < plan.workout.sets.count - 1
                    ? (set.restSecondsAfter ?? plan.prescription.restSeconds)
                    : 0
                return subtotal + work + rest
            }
            return total + setSeconds + (exerciseIndex < plans.count - 1 ? 45 : 0)
        }
    }

    private func todayTargetLabel(_ plan: TodayExercisePlan) -> String {
        let working = plan.workout.sets.filter { $0.setType != "warmup" }
        let representative = working.first ?? plan.workout.sets.first
        guard let representative else { return String(localized: "No planned sets") }
        if let seconds = representative.durationS {
            return String.localizedStringWithFormat(
                String(localized: "%lld sets × %lld sec"),
                working.count,
                seconds
            )
        }
        let reps = representative.reps ?? plan.prescription.targetRepsMin ?? 8
        var result = String.localizedStringWithFormat(
            String(localized: "%lld sets × %lld reps"),
            working.count,
            reps
        )
        if let loadKg = representative.loadKg {
            result += " · \(UnitFormatter.massFromKilograms(loadKg, unit: massUnit))"
        }
        let warmups = plan.workout.sets.count - working.count
        if warmups > 0 {
            result += String.localizedStringWithFormat(
                String(localized: " · %lld warm-up"),
                warmups
            )
        }
        return result
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func sessionDetail(
        _ session: StrengthSessionSnapshot,
        exercises: [StrengthExerciseRow]
    ) -> String {
        let completed = session.sets.filter {
            $0.completedAt != nil && $0.setType != "warmup"
        }
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

private struct StrengthExerciseGuidePreview: View {
    @Environment(\.dismiss) private var dismiss

    let exercise: StrengthExerciseRow

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: LocalizedStringKey(strengthExerciseName(exercise)),
                subtitle: LocalizedStringKey(strengthDescriptorPair(exercise)),
                topBackground: liquidScaffoldSky()
            ) {
                StrengthExerciseMotionView(exercise: exercise)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct StrengthExerciseBlock: Identifiable {
    let id: String
    var exercise: StrengthExerciseRow
    var position: Int
    var restSeconds: Int
    var sets: [StrengthSetRow]
    var supersetGroup: Int?
    var sourceRoutineExerciseID: String?
}

private struct StrengthNextSetTarget {
    let block: StrengthExerciseBlock
    let set: StrengthSetRow
}

private struct StrengthExerciseReplacement: Identifiable {
    let blockID: String
    let exercise: StrengthExerciseRow

    var id: String { "\(blockID)-\(exercise.id)" }
}

@MainActor
private final class StrengthVoiceCoach: ObservableObject {
    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif

    func speak(_ text: String) {
        #if canImport(AVFoundation)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
        utterance.rate = 0.48
        synthesizer.speak(utterance)
        #endif
    }

    func stop() {
        #if canImport(AVFoundation)
        synthesizer.stopSpeaking(at: .immediate)
        #endif
    }
}

private struct StrengthProgramBuilder: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    let routines: [StrengthRoutineSnapshot]
    let onSaved: () -> Void

    @AppStorage("strength.profile.dayCount") private var dayCount = 3
    @AppStorage("strength.profile.weekdays") private var weekdaysRaw = ""
    @AppStorage("strength.profile.focusMuscles") private var focusMusclesRaw = ""
    @State private var selectedDays = Set(StrengthAdaptivePlanner.suggestedWeekdays(for: 3))
    @State private var focusMuscles = Set<String>()
    @State private var didRestoreProfile = false
    @State private var replaceSchedule = true
    @State private var saving = false
    @State private var errorMessage: String?
    @AppStorage("strength.profile.experience") private var experienceRaw =
        StrengthTrainingExperience.beginner.rawValue
    @AppStorage("strength.profile.style") private var trainingStyleRaw =
        StrengthTrainingStyle.balanced.rawValue
    @AppStorage("strength.profile.sessionMinutes") private var sessionMinutes = 45

    private var program: [StrengthProgramRoutine] {
        StrengthAdaptivePlanner.program(
            for: StrengthProgramRequest(
                weekdays: Array(selectedDays),
                experience: StrengthTrainingExperience(rawValue: experienceRaw) ?? .beginner,
                style: StrengthTrainingStyle(rawValue: trainingStyleRaw) ?? .balanced,
                sessionMinutes: sessionMinutes,
                focusMuscles: Array(focusMuscles)
            )
        )
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: "Build your training week",
                subtitle: "Tell NOOP how you train. The result stays editable and advances only from work you complete.",
                topBackground: liquidScaffoldSky()
            ) {
                SectionHeader("About your training", overline: "Starting point")
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Picker("Experience", selection: $experienceRaw) {
                            Text("Beginner").tag(StrengthTrainingExperience.beginner.rawValue)
                            Text("Intermediate").tag(
                                StrengthTrainingExperience.intermediate.rawValue
                            )
                            Text("Experienced").tag(
                                StrengthTrainingExperience.experienced.rawValue
                            )
                        }
                        .pickerStyle(.menu)

                        Divider().overlay(StrandPalette.hairline)

                        Picker("Workout style", selection: $trainingStyleRaw) {
                            Text("Balanced fitness").tag(StrengthTrainingStyle.balanced.rawValue)
                            Text("Strength").tag(StrengthTrainingStyle.strength.rawValue)
                            Text("Build muscle").tag(StrengthTrainingStyle.muscle.rawValue)
                            Text("Conditioning").tag(
                                StrengthTrainingStyle.conditioning.rawValue
                            )
                        }
                        .pickerStyle(.menu)

                        Divider().overlay(StrandPalette.hairline)

                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("Time per workout")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Picker("Time per workout", selection: $sessionMinutes) {
                                ForEach([30, 45, 60, 75], id: \.self) {
                                    Text("\($0)m").tag($0)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Divider().overlay(StrandPalette.hairline)

                        Menu {
                            ForEach(StrengthProgressCalculator.bodyMapMuscles, id: \.self) {
                                muscle in
                                Button {
                                    var updated = focusMuscles
                                    if focusMuscles.contains(muscle) {
                                        updated.remove(muscle)
                                    } else if focusMuscles.count < 2 {
                                        updated.insert(muscle)
                                    }
                                    focusMuscles = updated
                                    focusMusclesRaw = encodeStringSet(updated)
                                } label: {
                                    Label(
                                        strengthMuscleName(muscle),
                                        systemImage: focusMuscles.contains(muscle)
                                            ? "checkmark"
                                            : "circle"
                                    )
                                }
                            }
                        } label: {
                            HStack {
                                Label("Priority muscles", systemImage: "figure.arms.open")
                                Spacer()
                                Text(
                                    focusMuscles.isEmpty
                                        ? "Balanced"
                                        : focusMuscles
                                            .sorted()
                                            .map(strengthMuscleName)
                                            .joined(separator: ", ")
                                )
                                .foregroundStyle(StrandPalette.textSecondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .font(StrandFont.subhead)
                        }
                    }
                }

                SectionHeader("Gym days", overline: "Two to six sessions")
                Picker("Days per week", selection: $dayCount) {
                    ForEach(2...6, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: dayCount) { count in
                    let suggested = Set(
                        StrengthAdaptivePlanner.suggestedWeekdays(for: count)
                    )
                    selectedDays = suggested
                    weekdaysRaw = encodeIntSet(suggested)
                }

                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { day in
                        Button {
                            var updated = selectedDays
                            if selectedDays.contains(day) {
                                updated.remove(day)
                            } else if selectedDays.count < dayCount {
                                updated.insert(day)
                            }
                            selectedDays = updated
                            weekdaysRaw = encodeIntSet(updated)
                        } label: {
                            Text(shortWeekdayName(day))
                                .font(StrandFont.caption)
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .foregroundStyle(
                                    selectedDays.contains(day)
                                        ? Color.white
                                        : StrandPalette.textSecondary
                                )
                                .background(
                                    selectedDays.contains(day)
                                        ? StrandPalette.effortColor
                                        : StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(weekdayNameForProgram(day))
                    }
                }

                if selectedDays.count != dayCount {
                    Label(
                        "Choose exactly \(dayCount) gym days.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                }

                SectionHeader("Your program", overline: "Editable after creation")
                ForEach(program, id: \.name) { routine in
                    NoopCard(tint: StrandPalette.effortColor) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("\(weekdayNameForProgram(routine.isoWeekday)) · \(routine.name)")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(
                                routine.exercises.map { item in
                                    StrengthTrainingContract.builtInExercises.first { exercise in
                                        exercise.id == item.exerciseId
                                    }?.name ?? item.exerciseId
                                }.joined(separator: " · ")
                            )
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }

                Toggle(
                    "Replace current weekday assignments",
                    isOn: $replaceSchedule
                )
                .tint(StrandPalette.effortColor)

                NoopButton(
                    "Create \(dayCount)-day plan",
                    systemImage: "sparkles",
                    kind: .primary,
                    fullWidth: true
                ) {
                    Task { await save() }
                }
                .disabled(saving || program.count != dayCount)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert("Couldn’t build plan", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { restoreProfile() }
    }

    private func restoreProfile() {
        guard !didRestoreProfile else { return }
        didRestoreProfile = true
        dayCount = min(max(dayCount, 2), 6)

        let storedDays = Set(
            weekdaysRaw
                .split(separator: ",")
                .compactMap { Int($0) }
                .filter { (1...7).contains($0) }
        )
        selectedDays = storedDays.count == dayCount
            ? storedDays
            : Set(StrengthAdaptivePlanner.suggestedWeekdays(for: dayCount))

        let allowedMuscles = Set(StrengthProgressCalculator.bodyMapMuscles)
        focusMuscles = Set(
            focusMusclesRaw
                .split(separator: ",")
                .map(String.init)
                .filter { allowedMuscles.contains($0) }
                .prefix(2)
        )
        weekdaysRaw = encodeIntSet(selectedDays)
        focusMusclesRaw = encodeStringSet(focusMuscles)
    }

    private func encodeIntSet(_ values: Set<Int>) -> String {
        values.sorted().map(String.init).joined(separator: ",")
    }

    private func encodeStringSet(_ values: Set<String>) -> String {
        values.sorted().joined(separator: ",")
    }

    private func save() async {
        guard program.count == dayCount else { return }
        saving = true
        do {
            if replaceSchedule {
                for item in routines {
                    var unscheduled = item.routine
                    unscheduled.scheduledWeekdaysJSON =
                        StrengthTrainingContract.encodeScheduledWeekdays([])
                    unscheduled.updatedAt = Int(Date().timeIntervalSince1970)
                    _ = try await repo.saveStrengthRoutine(
                        unscheduled,
                        exercises: item.exercises
                    )
                }
            }
            let now = Int(Date().timeIntervalSince1970)
            for template in program {
                let routineID = UUID().uuidString.lowercased()
                let routine = StrengthRoutineRow(
                    id: routineID,
                    name: template.name,
                    note: "Adaptive NOOP plan for \(experienceRaw), \(trainingStyleRaw), \(sessionMinutes)-minute sessions. Change any exercise or target to fit your training.",
                    scheduledWeekdaysJSON: StrengthTrainingContract.encodeScheduledWeekdays(
                        [template.isoWeekday]
                    ),
                    createdAt: now,
                    updatedAt: now
                )
                let rows = try template.exercises.enumerated().map { index, item in
                    guard let planJSON = StrengthTrainingContract.encodeExercisePlan(item.plan) else {
                        throw StrengthTrainingContract.ValidationError.invalidRoutineExercise
                    }
                    return StrengthRoutineExerciseRow(
                        id: UUID().uuidString.lowercased(),
                        routineId: routineID,
                        exerciseId: item.exerciseId,
                        position: index,
                        targetSets: item.targetSets,
                        targetRepsMin: item.targetRepsMin,
                        targetRepsMax: item.targetRepsMax,
                        targetRPE: item.targetRPE,
                        restSeconds: item.restSeconds,
                        planJSON: planJSON,
                        createdAt: now,
                        updatedAt: now
                    )
                }
                _ = try await repo.saveStrengthRoutine(routine, exercises: rows)
            }
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }

    private func shortWeekdayName(_ day: Int) -> String {
        String(weekdayNameForProgram(day).prefix(2))
    }

    private func weekdayNameForProgram(_ isoDay: Int) -> String {
        Calendar.current.weekdaySymbols[isoDay % 7]
    }
}

private struct StrengthSessionEditor: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    let exercises: [StrengthExerciseRow]
    let routines: [StrengthRoutineSnapshot]
    let history: [StrengthSessionSnapshot]
    let massUnit: MassUnit

    @State private var session: StrengthSessionRow
    @State private var blocks: [StrengthExerciseBlock]
    @State private var currentBlockID: String?
    @State private var exercisePicker = false
    @State private var replacementBlockID: String?
    @State private var pendingReplacement: StrengthExerciseReplacement?
    @State private var routineName = ""
    @State private var showingRoutinePrompt = false
    @State private var saving = false
    @State private var pendingSave = false
    @State private var restUntil: Date?
    @State private var workSetID: String?
    @State private var workStartedAt: Date?
    @State private var workUntil: Date?
    @State private var timedCountdownSetID: String?
    @State private var timedCountdownDuration = 0
    @State private var timedCountdownUntil: Date?
    @State private var pacedSetID: String?
    @State private var pacedStartedAt: Date?
    @State private var pacedRepetitions = 0
    @State private var pacedFinished = false
    @State private var errorMessage: String?
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false
    @AppStorage("strength.voiceCoaching") private var voiceCoaching = false
    @AppStorage("strength.repTempoSeconds") private var repTempoSeconds = 4
    @StateObject private var voiceCoach = StrengthVoiceCoach()

    init(
        initial: StrengthSessionSnapshot,
        exercises: [StrengthExerciseRow],
        routines: [StrengthRoutineSnapshot],
        history: [StrengthSessionSnapshot],
        massUnit: MassUnit
    ) {
        self.exercises = exercises
        self.routines = routines
        self.history = history
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
                sets: (grouped[position] ?? []).sorted { $0.setPosition < $1.setPosition },
                supersetGroup: prescription.flatMap {
                    StrengthTrainingContract.exercisePlan(from: $0.planJSON).supersetGroup
                },
                sourceRoutineExerciseID: prescription?.id
            )
        }
        _blocks = State(initialValue: built)
        _currentBlockID = State(
            initialValue: built.first(where: { block in
                block.sets.contains { $0.completedAt == nil }
            })?.id ?? built.first?.id
        )
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: session.endedAt == nil ? "Strength workout" : "Edit strength workout",
                subtitle: "Follow today’s plan one movement at a time. Your set results remain manual and authoritative.",
                topBackground: liquidScaffoldSky()
            ) {
                playerSessionHeader
                if let currentBlock {
                    currentExerciseGuide(currentBlock)
                }
                coachingControls
                timedCountdown
                pacedSetCoach
                workTimer
                restTimer
                if blocks.isEmpty {
                    ScreenStateCard(
                        kind: .empty,
                        title: "Add your first exercise",
                        message: "Choose from NOOP’s small starter catalog. Each exercise begins with three editable sets.",
                        symbol: "dumbbell"
                    )
                } else {
                    if let currentBlock {
                        exerciseCard(currentBlock)
                        exerciseNavigation
                    } else {
                        ScreenStateCard(
                            kind: .empty,
                            title: "Workout complete",
                            message: "Every planned set is marked complete. Finish when you are ready.",
                            symbol: "checkmark.circle"
                        )
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
        .sheet(
            isPresented: $exercisePicker,
            onDismiss: { replacementBlockID = nil }
        ) {
            StrengthExercisePicker(
                exercises: exercises.filter { candidate in
                    !blocks.contains(where: { $0.exercise.id == candidate.id })
                },
                onPick: selectExercise
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
            Text("The routine will store exercise order, set count, rep targets, and rest-not completed results.")
        }
        .confirmationDialog(
            "Use this replacement next time?",
            isPresented: Binding(
                get: { pendingReplacement != nil },
                set: { if !$0 { pendingReplacement = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Today only") {
                guard let choice = pendingReplacement else { return }
                pendingReplacement = nil
                Task { await replaceExercise(choice, updateRoutine: false) }
            }
            if let choice = pendingReplacement,
               blocks.first(where: { $0.id == choice.blockID })?
                .sourceRoutineExerciseID != nil {
                Button("Today and future workouts") {
                    pendingReplacement = nil
                    Task { await replaceExercise(choice, updateRoutine: true) }
                }
            }
            Button("Cancel", role: .cancel) { pendingReplacement = nil }
        } message: {
            Text("Completed sets are never relabeled. Future changes update the routine while keeping this workout’s recorded results authoritative.")
        }
        .alert("Strength Trainer", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            ScreenIdle.keepAwake(false)
            voiceCoach.stop()
        }
        .task(id: workSetID) {
            guard let setID = workSetID, let workUntil else { return }
            let wait = max(0, workUntil.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, workSetID == setID,
                  self.workUntil == workUntil else { return }
            finishTimedSet(id: setID, useTargetDuration: true)
        }
        .task(id: timedCountdownSetID) {
            guard let setID = timedCountdownSetID,
                  let countdownUntil = timedCountdownUntil
            else { return }
            if voiceCoaching {
                for number in stride(from: 3, through: 1, by: -1) {
                    guard !Task.isCancelled, timedCountdownSetID == setID else { return }
                    voiceCoach.speak(String(number))
                    try? await Task.sleep(for: .seconds(1))
                }
            } else {
                let wait = max(0, countdownUntil.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled, timedCountdownSetID == setID else { return }
            let duration = timedCountdownDuration
            clearTimedCountdown()
            activateTimedSet(id: setID, duration: duration)
            if voiceCoaching { voiceCoach.speak(String(localized: "Go")) }
        }
        .task(id: pacedSetID) {
            guard let setID = pacedSetID else { return }
            if voiceCoaching {
                for number in stride(from: 3, through: 1, by: -1) {
                    guard !Task.isCancelled, pacedSetID == setID else { return }
                    voiceCoach.speak(String(number))
                    try? await Task.sleep(for: .seconds(1))
                }
            } else {
                try? await Task.sleep(for: .seconds(3))
            }
            guard !Task.isCancelled, pacedSetID == setID else { return }
            pacedStartedAt = Date()
            for repetition in 1...max(1, pacedRepetitions) {
                guard !Task.isCancelled, pacedSetID == setID else { return }
                if voiceCoaching {
                    voiceCoach.speak(
                        String.localizedStringWithFormat(
                            String(localized: "Rep %lld. Controlled phase, inhale."),
                            repetition
                        )
                    )
                }
                let controlled = Double(repTempoSeconds) * 0.6
                try? await Task.sleep(for: .seconds(controlled))
                guard !Task.isCancelled, pacedSetID == setID else { return }
                if voiceCoaching {
                    voiceCoach.speak(String(localized: "Effort phase, exhale."))
                }
                try? await Task.sleep(
                    for: .seconds(max(0.5, Double(repTempoSeconds) - controlled))
                )
            }
            guard !Task.isCancelled, pacedSetID == setID else { return }
            pacedFinished = true
            if voiceCoaching {
                voiceCoach.speak(String(localized: "Pacing complete. Confirm the set when ready."))
            }
        }
        .task(id: restUntil) {
            guard let restUntil else { return }
            let wait = max(0, restUntil.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, self.restUntil == restUntil else { return }
            if voiceCoaching {
                voiceCoach.speak(String(localized: "Rest complete. Ready for the next set."))
            }
        }
    }

    private var playerSessionHeader: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Workout name (optional)", text: Binding(
                        get: { session.name ?? "" },
                        set: { session.name = $0.isEmpty ? nil : $0 }
                    ))
                    .font(StrandFont.title2)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Workout name")
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedLabel(at: context.date))
                            .font(StrandFont.number(18))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .monospacedDigit()
                    }
                }
                HStack {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "%lld of %lld sets"),
                            completedSetCount,
                            totalSetCount
                        )
                    )
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Exercise %lld of %lld"),
                            currentBlockIndex + 1,
                            blocks.count
                        )
                    )
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.effortColor)
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(StrandPalette.surfaceInset)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(StrandPalette.effortColor)
                                .frame(
                                    width: proxy.size.width
                                        * CGFloat(completedSetCount)
                                        / CGFloat(max(1, totalSetCount))
                                )
                        }
                }
                .frame(height: 5)
            }
        }
    }

    private var coachingControls: some View {
        NoopCard(tint: voiceCoaching ? StrandPalette.metricCyan : nil) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Toggle(isOn: $voiceCoaching) {
                    Label(
                        "Voice coaching",
                        systemImage: voiceCoaching ? "speaker.wave.2.fill" : "speaker.slash.fill"
                    )
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                }
                .tint(StrandPalette.metricCyan)
                if voiceCoaching {
                    Picker("Rep tempo", selection: $repTempoSeconds) {
                        Text("3 sec").tag(3)
                        Text("4 sec").tag(4)
                        Text("5 sec").tag(5)
                        Text("6 sec").tag(6)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    @ViewBuilder private var timedCountdown: some View {
        if let timedCountdownUntil {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let remaining = max(
                    1,
                    Int(ceil(timedCountdownUntil.timeIntervalSince(context.date)))
                )
                NoopCard(tint: StrandPalette.effortColor) {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: "timer")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(StrandPalette.effortColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Get ready")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("\(remaining)")
                                .font(StrandFont.number(28))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("Cancel") { clearTimedCountdown() }
                            .buttonStyle(NoopButtonStyle(.secondary))
                    }
                }
            }
        }
    }

    @ViewBuilder private var pacedSetCoach: some View {
        if let setID = pacedSetID {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let status = pacedStatus(at: context.date)
                NoopCard(tint: StrandPalette.metricCyan) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        HStack(spacing: NoopMetrics.space3) {
                            Image(systemName: "metronome.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(StrandPalette.metricCyan)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(status.title)
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(status.cue)
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer()
                            Button("Cancel") { cancelPacedSet() }
                                .buttonStyle(NoopButtonStyle(.tertiary))
                            Button("Complete set") { completePacedSet(id: setID) }
                                .buttonStyle(NoopButtonStyle(.primary))
                        }
                        GeometryReader { proxy in
                            Capsule()
                                .fill(StrandPalette.surfaceInset)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(StrandPalette.metricCyan)
                                        .frame(width: proxy.size.width * status.progress)
                                }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
    }

    private func pacedStatus(at date: Date) -> (
        title: String,
        cue: String,
        progress: CGFloat
    ) {
        if pacedFinished {
            return (
                String(localized: "Pacing complete"),
                String(localized: "Confirm the set when ready."),
                1
            )
        }
        guard let started = pacedStartedAt else {
            return (
                String(localized: "Get ready"),
                String(localized: "Paced repetitions start after the countdown."),
                0
            )
        }
        let tempo = Double(max(3, repTempoSeconds))
        let elapsed = max(0, date.timeIntervalSince(started))
        let repetition = min(
            max(1, pacedRepetitions),
            Int(elapsed / tempo) + 1
        )
        let phase = elapsed.truncatingRemainder(dividingBy: tempo)
        let controlled = phase < tempo * 0.6
        let total = tempo * Double(max(1, pacedRepetitions))
        return (
            String.localizedStringWithFormat(
                String(localized: "Rep %lld of %lld"),
                repetition,
                pacedRepetitions
            ),
            controlled
                ? String(localized: "Controlled phase · inhale")
                : String(localized: "Effort phase · exhale"),
            CGFloat(min(1, elapsed / max(1, total)))
        )
    }

    private var currentBlock: Binding<StrengthExerciseBlock>? {
        guard !blocks.isEmpty else { return nil }
        let id = currentBlockID ?? blocks.first?.id
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            return $blocks[0]
        }
        return $blocks[index]
    }

    private var currentBlockIndex: Int {
        guard let id = currentBlockID,
              let index = blocks.firstIndex(where: { $0.id == id })
        else { return 0 }
        return index
    }

    private var totalSetCount: Int {
        blocks.reduce(0) { $0 + $1.sets.count }
    }

    private func elapsedLabel(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince1970) - session.startedAt)
        return "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
    }

    private func currentExerciseGuide(
        _ block: Binding<StrengthExerciseBlock>
    ) -> some View {
        let value = block.wrappedValue
        let next = value.sets.first(where: { $0.completedAt == nil })
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(strengthExerciseName(value.exercise))
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(strengthDescriptorPair(value.exercise))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                if let group = value.supersetGroup {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "appwide.gym.superset_format"),
                            supersetLabel(group)
                        )
                    )
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.effortColor)
                }
            }

            StrengthExerciseMotionView(exercise: value.exercise)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 48)
                        .onEnded { gesture in
                            guard abs(gesture.translation.width)
                                    > abs(gesture.translation.height) * 1.25
                            else { return }
                            moveCurrentBlock(by: gesture.translation.width < 0 ? 1 : -1)
                        }
                )

            exercisePerformanceContext(for: value)

            if let guidance = progressionGuidance(for: value) {
                Label(guidance, systemImage: "lightbulb.fill")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.metricCyan)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = routineNote(for: value), !note.isEmpty {
                Label(note, systemImage: "list.bullet.clipboard")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let next {
                NoopCard(tint: StrandPalette.effortColor) {
                    HStack(spacing: NoopMetrics.space3) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("appwide.gym.up_next")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.effortColor)
                            Text(currentTargetLabel(next, in: value))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(strengthSetType(next.setType))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        if next.reps == nil, let duration = next.durationS, duration > 0 {
                            Button {
                                startTimedSet(next, duration: duration)
                            } label: {
                                Image(systemName: "play.fill")
                                    .frame(width: 42, height: 42)
                            }
                            .buttonStyle(NoopButtonStyle(.primary))
                            .disabled(
                                workSetID != nil
                                    || timedCountdownSetID != nil
                                    || pacedSetID != nil
                            )
                            .accessibilityLabel(
                                String.localizedStringWithFormat(
                                    String(localized: "Start %lld second set"),
                                    duration
                                )
                            )
                        } else if let repetitions = next.reps, repetitions > 0 {
                            Button {
                                startPacedSet(next, repetitions: repetitions)
                            } label: {
                                Image(systemName: "waveform")
                                    .frame(width: 42, height: 42)
                            }
                            .buttonStyle(NoopButtonStyle(.secondary))
                            .disabled(
                                workSetID != nil
                                    || timedCountdownSetID != nil
                                    || pacedSetID != nil
                            )
                            .accessibilityLabel(
                                String.localizedStringWithFormat(
                                    String(localized: "Coach %lld repetitions"),
                                    repetitions
                                )
                            )
                        }
                    }
                }
            } else {
                Label("All sets complete", systemImage: "checkmark.circle.fill")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.statusPositive)
            }
        }
    }

    @ViewBuilder
    private func exercisePerformanceContext(
        for block: StrengthExerciseBlock
    ) -> some View {
        let completedSessions = history
            .filter {
                $0.session.id != session.id && $0.session.endedAt != nil
            }
            .sorted { $0.session.startedAt > $1.session.startedAt }
        let lastSets = completedSessions.lazy.compactMap { item -> [StrengthSetRow]? in
            let rows = item.sets
                .filter {
                    $0.exerciseId == block.exercise.id
                        && $0.completedAt != nil
                        && $0.setType != "warmup"
                }
                .sorted { $0.setPosition < $1.setPosition }
            return rows.isEmpty ? nil : rows
        }.first
        let allSets = completedSessions.flatMap(\.sets).filter {
            $0.exerciseId == block.exercise.id
                && $0.completedAt != nil
                && $0.setType != "warmup"
        }
        let best = allSets.max { lhs, rhs in
            performanceValue(lhs) < performanceValue(rhs)
        }

        if lastSets != nil || best != nil {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if let lastSets {
                        performanceRow(
                            title: String(localized: "Last session"),
                            value: lastSets.prefix(3)
                                .map(setPerformanceLabel)
                                .joined(separator: " · ")
                        )
                    }
                    if let best {
                        performanceRow(
                            title: String(localized: "Best set"),
                            value: setPerformanceLabel(best)
                        )
                    }
                }
            }
        }
    }

    private func performanceRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private func performanceValue(_ set: StrengthSetRow) -> Double {
        if let volume = set.volumeKg { return volume * 1_000 }
        if let duration = set.durationS { return Double(duration) }
        return Double(set.reps ?? 0)
    }

    private func setPerformanceLabel(_ set: StrengthSetRow) -> String {
        if let duration = set.durationS, set.reps == nil {
            return String.localizedStringWithFormat(
                String(localized: "%lld sec"),
                duration
            )
        }
        let repetitions = set.reps ?? 0
        if let load = set.loadKg {
            return String.localizedStringWithFormat(
                String(localized: "%lld × %@"),
                repetitions,
                UnitFormatter.massFromKilograms(load, unit: massUnit)
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "%lld reps"),
            repetitions
        )
    }

    private var exerciseNavigation: some View {
        HStack(spacing: NoopMetrics.space3) {
            NoopButton(
                "Previous",
                systemImage: "chevron.left",
                kind: .secondary
            ) {
                moveCurrentBlock(by: -1)
            }
            .disabled(currentBlockIndex == 0)

            Spacer()

            Text("\(currentBlockIndex + 1) / \(blocks.count)")
                .font(StrandFont.number(17))
                .foregroundStyle(StrandPalette.textSecondary)
                .monospacedDigit()

            Spacer()

            NoopButton(
                "Next",
                systemImage: "chevron.right",
                kind: .secondary
            ) {
                moveCurrentBlock(by: 1)
            }
            .disabled(currentBlockIndex >= blocks.count - 1)
        }
    }

    @ViewBuilder private var workTimer: some View {
        if let workSetID, let workStartedAt, let workUntil {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let total = max(1, workUntil.timeIntervalSince(workStartedAt))
                let remaining = max(0, workUntil.timeIntervalSince(context.date))
                NoopCard(tint: StrandPalette.effortColor) {
                    VStack(spacing: NoopMetrics.space3) {
                        HStack(spacing: NoopMetrics.space3) {
                            Image(systemName: "timer")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(StrandPalette.effortColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Timed set")
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(
                                    String.localizedStringWithFormat(
                                        String(localized: "%lld seconds"),
                                        Int(ceil(remaining))
                                    )
                                )
                                .font(StrandFont.number(24))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .monospacedDigit()
                            }
                            Spacer()
                            Button("Cancel") { cancelTimedSet() }
                                .buttonStyle(NoopButtonStyle(.tertiary))
                            Button("Done") {
                                finishTimedSet(id: workSetID, useTargetDuration: false)
                            }
                            .buttonStyle(NoopButtonStyle(.primary))
                        }
                        GeometryReader { proxy in
                            Capsule()
                                .fill(StrandPalette.surfaceInset)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(StrandPalette.effortColor)
                                        .frame(
                                            width: proxy.size.width
                                                * CGFloat(max(0, min(1, remaining / total)))
                                        )
                                }
                        }
                        .frame(height: 5)
                    }
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

    @ViewBuilder private var nextSetGuide: some View {
        if let target = setQueue.first(where: { $0.set.completedAt == nil }) {
            NoopCard(tint: StrandPalette.effortColor) {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: "play.fill")
                        .foregroundStyle(StrandPalette.effortColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("appwide.gym.up_next")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.effortColor)
                        Text(strengthExerciseName(target.block.exercise))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(nextSetDetail(target))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var setQueue: [StrengthNextSetTarget] {
        let ordered = blocks.sorted { $0.position < $1.position }
        var handledGroups = Set<Int>()
        var result: [StrengthNextSetTarget] = []
        for block in ordered {
            guard let group = block.supersetGroup else {
                result.append(contentsOf: block.sets.sorted {
                    $0.setPosition < $1.setPosition
                }.map { StrengthNextSetTarget(block: block, set: $0) })
                continue
            }
            guard handledGroups.insert(group).inserted else { continue }
            let members = ordered.filter { $0.supersetGroup == group }
            for member in members {
                result.append(contentsOf: member.sets
                    .filter { $0.setType == "warmup" }
                    .map { StrengthNextSetTarget(block: member, set: $0) })
            }
            let workSets = Dictionary(
                uniqueKeysWithValues: members.map { member in
                    (member.id, member.sets.filter { $0.setType != "warmup" })
                }
            )
            let setCount = workSets.values.map(\.count).max() ?? 0
            for setIndex in 0..<setCount {
                for member in members {
                    guard let sets = workSets[member.id], sets.indices.contains(setIndex) else {
                        continue
                    }
                    result.append(
                        StrengthNextSetTarget(block: member, set: sets[setIndex])
                    )
                }
            }
        }
        return result
    }

    private func nextSetDetail(_ target: StrengthNextSetTarget) -> String {
        var parts: [String] = []
        if let group = target.block.supersetGroup {
            parts.append(
                String.localizedStringWithFormat(
                    String(localized: "appwide.gym.superset_format"),
                    supersetLabel(group)
                )
            )
        }
        parts.append(
            String.localizedStringWithFormat(
                String(localized: "appwide.gym.set_guide_format"),
                target.set.setPosition + 1,
                strengthSetType(target.set.setType)
            )
        )
        return parts.joined(separator: " · ")
    }

    private func supersetLabel(_ group: Int) -> String {
        guard group >= 1, group <= 26,
              let scalar = UnicodeScalar(64 + group)
        else { return "\(group)" }
        return String(Character(scalar))
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
                    if let group = block.wrappedValue.supersetGroup {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "appwide.gym.superset_format"),
                                supersetLabel(group)
                            )
                        )
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.effortColor)
                    }
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
                        Button("Replace exercise", systemImage: "arrow.triangle.2.circlepath") {
                            beginExerciseReplacement(blockID: block.wrappedValue.id)
                        }
                        Button("Move earlier", systemImage: "arrow.up") {
                            reorderExercise(id: block.wrappedValue.id, offset: -1)
                        }
                        .disabled(block.wrappedValue.position == 0)
                        Button("Move later", systemImage: "arrow.down") {
                            reorderExercise(id: block.wrappedValue.id, offset: 1)
                        }
                        .disabled(block.wrappedValue.position >= blocks.count - 1)
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
                toggleCompleted(
                    set: set,
                    restSeconds: set.wrappedValue.restSeconds ?? block.wrappedValue.restSeconds
                )
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
                    Text(strengthSetType("rest_pause")).tag("rest_pause")
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

    private func beginExerciseReplacement(blockID: String) {
        guard let block = blocks.first(where: { $0.id == blockID }) else { return }
        guard block.sets.allSatisfy({ $0.completedAt == nil }) else {
            errorMessage = String(
                localized: "Completed sets keep their original exercise. Add another exercise for any remaining work."
            )
            return
        }
        guard workSetID == nil,
              timedCountdownSetID == nil,
              pacedSetID == nil else {
            errorMessage = String(localized: "Finish or cancel the active timer before replacing this exercise.")
            return
        }
        replacementBlockID = blockID
        exercisePicker = true
    }

    private func selectExercise(_ exercise: StrengthExerciseRow) {
        if let blockID = replacementBlockID {
            pendingReplacement = StrengthExerciseReplacement(
                blockID: blockID,
                exercise: exercise
            )
            exercisePicker = false
        } else {
            addExercise(exercise)
        }
    }

    private func replaceExercise(
        _ choice: StrengthExerciseReplacement,
        updateRoutine: Bool
    ) async {
        guard let blockIndex = blocks.firstIndex(where: { $0.id == choice.blockID }),
              blocks[blockIndex].sets.allSatisfy({ $0.completedAt == nil })
        else {
            errorMessage = String(
                localized: "Completed sets keep their original exercise. Add another exercise for any remaining work."
            )
            return
        }

        if updateRoutine {
            guard let routineID = session.routineId,
                  let sourceID = blocks[blockIndex].sourceRoutineExerciseID,
                  let sourceRoutine = routines.first(where: { $0.routine.id == routineID }),
                  let sourceIndex = sourceRoutine.exercises.firstIndex(where: {
                      $0.id == sourceID
                  })
            else {
                errorMessage = String(localized: "NOOP could not find the source routine for this exercise.")
                return
            }
            var routine = sourceRoutine.routine
            var prescriptions = sourceRoutine.exercises
            let now = Int(Date().timeIntervalSince1970)
            routine.updatedAt = now
            prescriptions[sourceIndex].exerciseId = choice.exercise.id
            prescriptions[sourceIndex].updatedAt = now
            do {
                _ = try await repo.saveStrengthRoutine(routine, exercises: prescriptions)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        let now = Int(Date().timeIntervalSince1970)
        blocks[blockIndex].exercise = choice.exercise
        for setIndex in blocks[blockIndex].sets.indices {
            blocks[blockIndex].sets[setIndex].exerciseId = choice.exercise.id
            blocks[blockIndex].sets[setIndex].updatedAt = now
        }
        _ = await persist(silently: false)
    }

    private func reorderExercise(id: String, offset: Int) {
        guard let source = blocks.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(0, source + offset), blocks.count - 1)
        guard source != destination else { return }
        let block = blocks.remove(at: source)
        blocks.insert(block, at: destination)
        normalizePositions()
        Task { await persist(silently: true) }
    }

    private func addExercise(_ exercise: StrengthExerciseRow) {
        exercisePicker = false
        let now = Int(Date().timeIntervalSince1970)
        let recordedAt = session.endedAt ?? now
        let position = blocks.count
        let sets = (0..<3).map { index in
            StrengthSetRow(
                id: UUID().uuidString.lowercased(),
                sessionId: session.id,
                exerciseId: exercise.id,
                exercisePosition: position,
                setPosition: index,
                setType: exercise.equipment == "bodyweight" ? "bodyweight" : "working",
                createdAt: recordedAt,
                updatedAt: now
            )
        }
        blocks.append(
            StrengthExerciseBlock(
                id: "\(position)-\(exercise.id)",
                exercise: exercise,
                position: position,
                restSeconds: 120,
                sets: sets,
                supersetGroup: nil,
                sourceRoutineExerciseID: nil
            )
        )
        if currentBlockID == nil {
            currentBlockID = blocks.last?.id
        }
        Task { await persist(silently: true) }
    }

    private func addSet(to blockID: String) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let now = Int(Date().timeIntervalSince1970)
        let recordedAt = session.endedAt ?? now
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
                createdAt: recordedAt,
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
        let removedIndex = blocks.firstIndex(where: { $0.id == id })
        let removedCurrent = currentBlockID == id
        blocks.removeAll { $0.id == id }
        normalizePositions()
        if removedCurrent {
            guard !blocks.isEmpty else {
                currentBlockID = nil
                Task { await persist(silently: true) }
                return
            }
            currentBlockID = blocks[min(removedIndex ?? 0, blocks.count - 1)].id
        }
        Task { await persist(silently: true) }
    }

    private func normalizePositions() {
        for blockIndex in blocks.indices {
            blocks[blockIndex].position = blockIndex
            for setIndex in blocks[blockIndex].sets.indices {
                blocks[blockIndex].sets[setIndex].exercisePosition = blockIndex
                blocks[blockIndex].sets[setIndex].setPosition = setIndex
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
        if pacedSetID == set.wrappedValue.id {
            cancelPacedSet()
        }
        if set.wrappedValue.completedAt != nil {
            set.wrappedValue.completedAt = nil
            Task { await persist(silently: true) }
            return
        }
        let now = Int(Date().timeIntervalSince1970)
        var completed = set.wrappedValue
        completed.completedAt = session.endedAt ?? now
        completed.updatedAt = now
        do {
            completed = try StrengthTrainingContract.validated(completed)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        set.wrappedValue = completed
        if restSeconds > 0 { restUntil = Date().addingTimeInterval(TimeInterval(restSeconds)) }
        advanceIfCurrentExerciseFinished(afterCompleting: completed.id)
        Task { await persist(silently: true) }
    }

    private func saveAndDismiss() async {
        if await persist(silently: false) { dismiss() }
    }

    private func finish() async {
        guard completedSetCount > 0 else { return }
        if session.endedAt == nil {
            let now = Int(Date().timeIntervalSince1970)
            let latestCompleted = blocks.flatMap(\.sets).compactMap(\.completedAt).max() ?? now
            session.endedAt = now - session.startedAt <= StrengthTrainingContract.maxDurationSeconds
                ? now
                : min(latestCompleted, session.startedAt + StrengthTrainingContract.maxDurationSeconds)
        }
        if await persist(silently: false) { dismiss() }
    }

    @discardableResult
    private func persist(silently: Bool) async -> Bool {
        if saving {
            pendingSave = true
            if silently { return true }
            while saving {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        var succeeded = true
        repeat {
            pendingSave = false
            saving = true
            let now = Int(Date().timeIntervalSince1970)
            session.updatedAt = now
            let rows = blocks.flatMap { block in
                block.sets.map { row in
                    var copy = row
                    copy.updatedAt = now
                    return copy
                }
            }
            do {
                _ = try await repo.saveStrengthSession(session, sets: rows)
            } catch {
                if !silently { errorMessage = error.localizedDescription }
                succeeded = false
            }
            saving = false
        } while succeeded && pendingSave

        if !succeeded { pendingSave = false }
        return succeeded
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
        let sourceRoutine = routines.first { $0.routine.id == session.routineId }
        do {
            let prescriptions = try blocks.map { block -> StrengthRoutineExerciseRow in
                let source = sourceRoutine?.exercises.first {
                    $0.position == block.position && $0.exerciseId == block.exercise.id
                }
                let baseSets = routineBaseSets(for: block)
                let reps = baseSets.compactMap(\.reps)
                let plan = routinePlan(for: block, source: source, baseSets: baseSets)
                guard let planJSON = StrengthTrainingContract.encodeExercisePlan(plan) else {
                    throw StrengthTrainingContract.ValidationError.invalidRoutineExercise
                }
                return StrengthRoutineExerciseRow(
                    id: UUID().uuidString.lowercased(),
                    routineId: routineID,
                    exerciseId: block.exercise.id,
                    position: block.position,
                    targetSets: max(1, baseSets.count),
                    targetRepsMin: plan.mode == "timed" ? nil : reps.min(),
                    targetRepsMax: plan.mode == "timed" ? nil : reps.max(),
                    targetRPE: source?.targetRPE,
                    restSeconds: source?.restSeconds ?? block.restSeconds,
                    note: source?.note,
                    planJSON: planJSON,
                    createdAt: now,
                    updatedAt: now
                )
            }
            _ = try await repo.saveStrengthRoutine(routine, exercises: prescriptions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func routineBaseSets(for block: StrengthExerciseBlock) -> [StrengthSetRow] {
        let base = block.sets.filter {
            !["warmup", "drop", "rest_pause"].contains($0.setType)
        }
        if !base.isEmpty { return base }
        let nonWarmups = block.sets.filter { $0.setType != "warmup" }
        return nonWarmups.isEmpty ? block.sets : nonWarmups
    }

    private func routinePlan(
        for block: StrengthExerciseBlock,
        source: StrengthRoutineExerciseRow?,
        baseSets: [StrengthSetRow]
    ) -> StrengthExercisePlan {
        var plan = source.map {
            StrengthTrainingContract.exercisePlan(from: $0.planJSON)
        } ?? StrengthExercisePlan()
        let timed = block.exercise.movementPattern == "cardio"
            || (baseSets.contains { $0.durationS != nil } && !baseSets.contains { $0.reps != nil })
        plan.mode = timed ? "timed" : "reps"
        plan.supersetGroup = block.supersetGroup

        if timed {
            if !["none", "time"].contains(plan.progression) { plan.progression = "time" }
            plan.targetDurationS = baseSets.compactMap(\.durationS).max()
                ?? plan.targetDurationS
                ?? 30
            plan.warmupSets = 0
            plan.setStyle = "straight"
            return plan
        }

        if plan.progression == "time" { plan.progression = "double_progression" }
        plan.targetDurationS = nil
        plan.targetLoadKg = baseSets.compactMap(\.loadKg).max() ?? plan.targetLoadKg
        plan.warmupSets = min(5, block.sets.filter { $0.setType == "warmup" }.count)
        if block.sets.contains(where: { $0.setType == "drop" }) {
            plan.setStyle = "drop"
            if let workLoad = baseSets.compactMap(\.loadKg).max(),
               let dropLoad = block.sets.first(where: { $0.setType == "drop" })?.loadKg,
               workLoad > 0, dropLoad < workLoad {
                plan.dropPercent = min(
                    50,
                    max(5, Int(((1 - dropLoad / workLoad) * 100).rounded()))
                )
            }
        } else if let restPauseIndex = block.sets.firstIndex(where: {
            $0.setType == "rest_pause"
        }) {
            plan.setStyle = "rest_pause"
            if restPauseIndex > 0,
               let pause = block.sets[restPauseIndex - 1].restSeconds {
                plan.restPauseSeconds = min(60, max(5, pause))
            }
        } else {
            plan.setStyle = "straight"
        }
        return plan
    }

    private func moveCurrentBlock(by offset: Int) {
        guard !blocks.isEmpty else { return }
        let next = min(max(0, currentBlockIndex + offset), blocks.count - 1)
        guard next != currentBlockIndex else { return }
        currentBlockID = blocks[next].id
    }

    private func advanceIfCurrentExerciseFinished(afterCompleting setID: String) {
        guard let completedBlockIndex = blocks.firstIndex(where: { block in
            block.sets.contains(where: { $0.id == setID })
        }), blocks[completedBlockIndex].sets.allSatisfy({ $0.completedAt != nil }),
        currentBlockID == blocks[completedBlockIndex].id
        else { return }

        let later = blocks.indices.dropFirst(completedBlockIndex + 1).first {
            blocks[$0].sets.contains { $0.completedAt == nil }
        }
        let earlier = blocks.indices.prefix(completedBlockIndex).first {
            blocks[$0].sets.contains { $0.completedAt == nil }
        }
        if let next = later ?? earlier {
            currentBlockID = blocks[next].id
        }
    }

    private func startTimedSet(_ set: StrengthSetRow, duration: Int) {
        guard workSetID == nil, pacedSetID == nil,
              timedCountdownSetID == nil, duration > 0
        else { return }
        if voiceCoaching {
            restUntil = nil
            timedCountdownDuration = duration
            timedCountdownUntil = Date().addingTimeInterval(3)
            timedCountdownSetID = set.id
        } else {
            activateTimedSet(id: set.id, duration: duration)
        }
    }

    private func activateTimedSet(id: String, duration: Int) {
        guard blocks.contains(where: { block in
            block.sets.contains(where: { $0.id == id && $0.completedAt == nil })
        }), workSetID == nil, duration > 0
        else { return }
        let now = Date()
        restUntil = nil
        workStartedAt = now
        workUntil = now.addingTimeInterval(TimeInterval(duration))
        workSetID = id
    }

    private func clearTimedCountdown() {
        timedCountdownSetID = nil
        timedCountdownDuration = 0
        timedCountdownUntil = nil
    }

    private func cancelTimedSet() {
        workSetID = nil
        workStartedAt = nil
        workUntil = nil
    }

    private func startPacedSet(_ set: StrengthSetRow, repetitions: Int) {
        guard pacedSetID == nil, workSetID == nil,
              timedCountdownSetID == nil, repetitions > 0
        else { return }
        restUntil = nil
        pacedRepetitions = repetitions
        pacedStartedAt = nil
        pacedFinished = false
        pacedSetID = set.id
    }

    private func cancelPacedSet() {
        pacedSetID = nil
        pacedStartedAt = nil
        pacedRepetitions = 0
        pacedFinished = false
        voiceCoach.stop()
    }

    private func completePacedSet(id: String) {
        guard let blockIndex = blocks.firstIndex(where: { block in
            block.sets.contains(where: { $0.id == id })
        }), let setIndex = blocks[blockIndex].sets.firstIndex(where: { $0.id == id })
        else {
            cancelPacedSet()
            return
        }
        let restSeconds = blocks[blockIndex].sets[setIndex].restSeconds
            ?? blocks[blockIndex].restSeconds
        let binding = Binding<StrengthSetRow>(
            get: { blocks[blockIndex].sets[setIndex] },
            set: { blocks[blockIndex].sets[setIndex] = $0 }
        )
        cancelPacedSet()
        toggleCompleted(set: binding, restSeconds: restSeconds)
    }

    private func finishTimedSet(id: String, useTargetDuration: Bool) {
        guard let blockIndex = blocks.firstIndex(where: { block in
            block.sets.contains(where: { $0.id == id })
        }), let setIndex = blocks[blockIndex].sets.firstIndex(where: { $0.id == id })
        else {
            cancelTimedSet()
            return
        }
        let target = blocks[blockIndex].sets[setIndex].durationS ?? 1
        let elapsed = workStartedAt.map {
            max(1, Int(Date().timeIntervalSince($0).rounded(.down)))
        } ?? target
        blocks[blockIndex].sets[setIndex].durationS = useTargetDuration
            ? target
            : min(target, elapsed)
        let restSeconds = blocks[blockIndex].sets[setIndex].restSeconds
            ?? blocks[blockIndex].restSeconds
        let binding = Binding<StrengthSetRow>(
            get: { blocks[blockIndex].sets[setIndex] },
            set: { blocks[blockIndex].sets[setIndex] = $0 }
        )
        cancelTimedSet()
        toggleCompleted(set: binding, restSeconds: restSeconds)
        if voiceCoaching {
            voiceCoach.speak(String(localized: "Timed set complete."))
        }
    }

    private func currentTargetLabel(
        _ set: StrengthSetRow,
        in block: StrengthExerciseBlock
    ) -> String {
        var target = String.localizedStringWithFormat(
            String(localized: "Set %lld"),
            set.setPosition + 1
        )
        if let duration = set.durationS, set.reps == nil {
            target += String.localizedStringWithFormat(
                String(localized: " · %lld seconds"),
                duration
            )
            return target
        }
        if let load = set.loadKg {
            let display = massUnit == .pounds ? UnitFormatter.kgToPounds(load) : load
            target += " · \(formatNumber(display)) \(massUnit.rawValue)"
        } else if block.exercise.equipment == "bodyweight" {
            target += " · \(String(localized: "Bodyweight"))"
        }
        if let reps = set.reps {
            target += String.localizedStringWithFormat(
                String(localized: " × %lld reps"),
                reps
            )
        }
        return target
    }

    private func sourceRoutineExercise(
        for block: StrengthExerciseBlock
    ) -> StrengthRoutineExerciseRow? {
        routines.first(where: { $0.routine.id == session.routineId })?.exercises.first {
            $0.position == block.position && $0.exerciseId == block.exercise.id
        }
    }

    private func routineNote(for block: StrengthExerciseBlock) -> String? {
        sourceRoutineExercise(for: block)?.note?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func progressionGuidance(for block: StrengthExerciseBlock) -> String? {
        guard let prescription = sourceRoutineExercise(for: block) else {
            return String(localized: "Freestyle target · adjust each set to match the work you do.")
        }
        let planned = StrengthWorkoutPlanner.prescription(
            exercise: block.exercise,
            prescription: prescription,
            history: history
        )
        switch planned.reason {
        case .firstSession:
            return String(localized: "Starting target from this routine. Adjust it if today’s session differs.")
        case .repeatLoad:
            return String(localized: "Target carries forward your latest completed session.")
        case .repRangeAdvanced:
            return String(localized: "You reached the top of the rep range, so today’s load advances one step.")
        case .linearAdvanced:
            return String(localized: "Your completed working sets support the routine’s next linear load step.")
        case .timeAdvanced:
            return String(localized: "You completed the prior hold target, so today adds five seconds.")
        case .bodyweightRepProgress:
            return String(localized: "You completed the prior bodyweight target, so today adds repetitions.")
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

private struct StrengthRoutineExerciseDraft: Identifiable {
    let id: String
    var exercise: StrengthExerciseRow
    var targetSets: Int
    var targetRepsMin: Int
    var targetRepsMax: Int
    var targetRPE: Double?
    var restSeconds: Int
    var note: String
    var plan: StrengthExercisePlan
    var createdAt: Int
}

private struct StrengthRoutineEditor: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    let exercises: [StrengthExerciseRow]
    let massUnit: MassUnit

    @State private var routineID: String
    @State private var createdAt: Int
    @State private var name: String
    @State private var note: String
    @State private var weekdays: Set<Int>
    @State private var items: [StrengthRoutineExerciseDraft]
    @State private var exercisePicker = false
    @State private var saving = false
    @State private var errorMessage: String?

    init(
        initial: StrengthRoutineSnapshot?,
        exercises: [StrengthExerciseRow],
        massUnit: MassUnit
    ) {
        self.exercises = exercises
        self.massUnit = massUnit
        let now = Int(Date().timeIntervalSince1970)
        let byID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        _routineID = State(initialValue: initial?.routine.id ?? UUID().uuidString.lowercased())
        _createdAt = State(initialValue: initial?.routine.createdAt ?? now)
        _name = State(initialValue: initial?.routine.name ?? "")
        _note = State(initialValue: initial?.routine.note ?? "")
        _weekdays = State(initialValue: Set(
            StrengthTrainingContract.scheduledWeekdays(
                from: initial?.routine.scheduledWeekdaysJSON
            )
        ))
        _items = State(initialValue: initial?.exercises.compactMap { row in
            guard let exercise = byID[row.exerciseId] else { return nil }
            return StrengthRoutineExerciseDraft(
                id: row.id,
                exercise: exercise,
                targetSets: row.targetSets,
                targetRepsMin: row.targetRepsMin ?? 8,
                targetRepsMax: row.targetRepsMax ?? row.targetRepsMin ?? 8,
                targetRPE: row.targetRPE,
                restSeconds: row.restSeconds,
                note: row.note ?? "",
                plan: StrengthTrainingContract.exercisePlan(from: row.planJSON),
                createdAt: row.createdAt
            )
        } ?? [])
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: LocalizedStringKey(
                    name.isEmpty ? "appwide.gym.new_routine" : name
                ),
                subtitle: "appwide.gym.routine_editor_subtitle",
                topBackground: liquidScaffoldSky()
            ) {
                NoopCard(tint: StrandPalette.effortColor) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        TextField("Routine name", text: $name)
                            .textFieldStyle(.roundedBorder)
                        TextField("appwide.gym.notes_optional", text: $note, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                    }
                }

                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    SectionHeader(
                        "appwide.gym.training_days",
                        overline: "appwide.gym.weekly_schedule"
                    )
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { day in
                            Button {
                                if weekdays.contains(day) {
                                    weekdays.remove(day)
                                } else {
                                    weekdays.insert(day)
                                }
                            } label: {
                                Text(shortWeekday(day))
                                    .font(StrandFont.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .foregroundStyle(
                                        weekdays.contains(day)
                                            ? Color.white
                                            : StrandPalette.textSecondary
                                    )
                                    .background(
                                        weekdays.contains(day)
                                            ? StrandPalette.effortColor
                                            : StrandPalette.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                String.localizedStringWithFormat(
                                    String(localized: "appwide.gym.training_day_format"),
                                    fullWeekday(day)
                                )
                            )
                            .accessibilityValue(weekdays.contains(day) ? "Selected" : "Not selected")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    SectionHeader(
                        "appwide.gym.exercises",
                        overline: "appwide.gym.ordered_prescription",
                        trailing: items.isEmpty ? nil : "\(items.count)"
                    )
                    if items.isEmpty {
                        ScreenStateCard(
                            kind: .empty,
                            title: "appwide.gym.add_first_exercise",
                            message: "appwide.gym.add_first_exercise_body",
                            symbol: "dumbbell"
                        )
                    } else {
                        ForEach($items) { $item in
                            routineExerciseCard($item)
                        }
                    }
                    NoopButton(
                        "Add exercise",
                        systemImage: "plus",
                        kind: .secondary,
                        fullWidth: true
                    ) {
                        exercisePicker = true
                    }
                }

                NoopButton("Save routine", systemImage: "checkmark", kind: .primary, fullWidth: true) {
                    Task { await save() }
                }
                .disabled(
                    saving
                        || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || items.isEmpty
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $exercisePicker) {
            StrengthExercisePicker(
                exercises: exercises.filter { exercise in
                    !items.contains(where: { $0.exercise.id == exercise.id })
                },
                onPick: addExercise
            )
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #endif
        }
        .alert("appwide.gym.routine", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func routineExerciseCard(
        _ item: Binding<StrengthRoutineExerciseDraft>
    ) -> some View {
        let timed = item.wrappedValue.plan.mode == "timed"
            || item.wrappedValue.exercise.movementPattern == "cardio"
        return NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: timed ? "timer" : "dumbbell.fill")
                        .foregroundStyle(StrandPalette.effortColor)
                        .frame(width: 38, height: 38)
                        .background(StrandPalette.surfaceInset, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(strengthExerciseName(item.wrappedValue.exercise))
                            .font(StrandFont.headline)
                        Text(strengthDescriptorPair(item.wrappedValue.exercise))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Menu {
                        Button("appwide.gym.move_exercise_up") {
                            move(item.wrappedValue.id, by: -1)
                        }
                        Button("appwide.gym.move_exercise_down") {
                            move(item.wrappedValue.id, by: 1)
                        }
                        Button("Remove", role: .destructive) {
                            items.removeAll { $0.id == item.wrappedValue.id }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Exercise actions")
                }

                Picker("appwide.gym.mode", selection: modeBinding(item)) {
                    Text("Reps").tag("reps")
                    Text("appwide.gym.timed").tag("timed")
                }
                .pickerStyle(.segmented)
                .disabled(item.wrappedValue.exercise.movementPattern == "cardio")

                HStack(spacing: NoopMetrics.space3) {
                    compactStepper(
                        "appwide.gym.sets",
                        value: item.targetSets,
                        range: 1...StrengthTrainingContract.maxTargetSets
                    )
                    if timed {
                        compactStepper(
                            "appwide.gym.seconds",
                            value: optionalInt(item.plan.targetDurationS, fallback: 30),
                            range: 5...3_600,
                            step: 5
                        )
                    } else {
                        compactStepper(
                            "appwide.gym.min_reps",
                            value: item.targetRepsMin,
                            range: 1...100
                        )
                        compactStepper(
                            "appwide.gym.max_reps",
                            value: item.targetRepsMax,
                            range: 1...100
                        )
                    }
                }

                if !timed {
                    HStack(spacing: NoopMetrics.space3) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "appwide.gym.starting_load_format"),
                                    massUnit.rawValue
                                )
                            )
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                            TextField("Optional", text: loadBinding(item.plan.targetLoadKg))
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("appwide.gym.load_step_kg")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                            TextField("2.5", text: decimalText(item.plan.loadStepKg))
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                        }
                        compactStepper(
                            "appwide.gym.warmups",
                            value: item.plan.warmupSets,
                            range: 0...5
                        )
                    }
                    Toggle("appwide.gym.reps_per_side", isOn: item.plan.repsPerSide)
                        .font(StrandFont.subhead)
                }

                HStack(spacing: NoopMetrics.space3) {
                    Menu {
                        Picker("Rest", selection: item.restSeconds) {
                            Text("No timer").tag(0)
                            Text("appwide.gym.rest_60_short").tag(60)
                            Text("appwide.gym.rest_90_short").tag(90)
                            Text("appwide.gym.rest_2_min_short").tag(120)
                            Text("appwide.gym.rest_3_min_short").tag(180)
                            Text("appwide.gym.rest_5_min_short").tag(300)
                        }
                    } label: {
                        Label(restLabel(item.wrappedValue.restSeconds), systemImage: "timer")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))

                    Menu {
                        Picker("appwide.gym.progression", selection: item.plan.progression) {
                            if timed {
                                Text("appwide.gym.add_time").tag("time")
                            } else {
                                Text("appwide.gym.double_progression")
                                    .tag("double_progression")
                                Text("appwide.gym.linear_load").tag("linear")
                            }
                            Text("appwide.gym.no_automatic_change").tag("none")
                        }
                    } label: {
                        Label(progressionLabel(item.wrappedValue.plan.progression),
                              systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))

                    Menu {
                        Picker("appwide.gym.superset", selection: item.plan.supersetGroup) {
                            Text("appwide.gym.no_superset").tag(Int?.none)
                            ForEach(1...4, id: \.self) { group in
                                Text(
                                    String.localizedStringWithFormat(
                                        String(localized: "appwide.gym.superset_format"),
                                        supersetName(group)
                                    )
                                )
                                .tag(Int?.some(group))
                            }
                        }
                    } label: {
                        Label(
                            item.wrappedValue.plan.supersetGroup.map {
                                String.localizedStringWithFormat(
                                    String(localized: "appwide.gym.superset_format"),
                                    supersetName($0)
                                )
                            } ?? String(localized: "appwide.gym.no_superset"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                }

                if !timed {
                    Picker("appwide.gym.final_set_style", selection: item.plan.setStyle) {
                        Text("appwide.gym.straight").tag("straight")
                        Text("appwide.gym.drop_set").tag("drop")
                        Text("appwide.gym.rest_pause").tag("rest_pause")
                    }
                    .pickerStyle(.segmented)
                    if item.wrappedValue.plan.setStyle == "drop" {
                        compactStepper(
                            "appwide.gym.drop_load_percent",
                            value: item.plan.dropPercent,
                            range: 5...50,
                            step: 5
                        )
                    } else if item.wrappedValue.plan.setStyle == "rest_pause" {
                        compactStepper(
                            "appwide.gym.pause_seconds",
                            value: item.plan.restPauseSeconds,
                            range: 5...60,
                            step: 5
                        )
                    }
                }
            }
        }
    }

    private func compactStepper(
        _ title: LocalizedStringKey,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(StrandFont.bodyNumber)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionalInt(_ binding: Binding<Int?>, fallback: Int) -> Binding<Int> {
        Binding(
            get: { binding.wrappedValue ?? fallback },
            set: { binding.wrappedValue = $0 }
        )
    }

    private func loadBinding(_ binding: Binding<Double?>) -> Binding<String> {
        Binding(
            get: {
                guard let kg = binding.wrappedValue else { return "" }
                let display = massUnit == .pounds ? UnitFormatter.kgToPounds(kg) : kg
                return display.formatted(.number.precision(.fractionLength(0...1)))
            },
            set: { text in
                let separator = Locale.current.decimalSeparator ?? "."
                let value = Double(
                    text.replacingOccurrences(of: separator, with: ".")
                        .filter { $0.isNumber || $0 == "." }
                )
                binding.wrappedValue = value.map {
                    massUnit == .pounds ? $0 / UnitFormatter.poundsPerKilogram : $0
                }
            }
        )
    }

    private func decimalText(_ binding: Binding<Double>) -> Binding<String> {
        Binding(
            get: {
                binding.wrappedValue.formatted(
                    .number.precision(.fractionLength(0...1))
                )
            },
            set: { text in
                let separator = Locale.current.decimalSeparator ?? "."
                let value = Double(
                    text.replacingOccurrences(of: separator, with: ".")
                        .filter { $0.isNumber || $0 == "." }
                )
                if let value, value.isFinite {
                    binding.wrappedValue = min(100, max(0.1, value))
                }
            }
        )
    }

    private func addExercise(_ exercise: StrengthExerciseRow) {
        let now = Int(Date().timeIntervalSince1970)
        let timed = exercise.movementPattern == "cardio"
        items.append(
            StrengthRoutineExerciseDraft(
                id: UUID().uuidString.lowercased(),
                exercise: exercise,
                targetSets: timed ? 1 : 3,
                targetRepsMin: 8,
                targetRepsMax: 12,
                targetRPE: nil,
                restSeconds: timed ? 0 : 120,
                note: "",
                plan: StrengthExercisePlan(
                    mode: timed ? "timed" : "reps",
                    targetDurationS: timed ? 1_200 : nil,
                    progression: timed ? "time" : "double_progression",
                    warmupSets: 0
                ),
                createdAt: now
            )
        )
        exercisePicker = false
    }

    private func move(_ id: String, by offset: Int) {
        guard let source = items.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(0, source + offset), items.count - 1)
        guard source != destination else { return }
        items.move(fromOffsets: IndexSet(integer: source), toOffset: destination > source
                   ? destination + 1 : destination)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let now = Int(Date().timeIntervalSince1970)
        let routine = StrengthRoutineRow(
            id: routineID,
            name: name,
            note: note.isEmpty ? nil : note,
            scheduledWeekdaysJSON: StrengthTrainingContract.encodeScheduledWeekdays(
                Array(weekdays)
            ),
            createdAt: createdAt,
            updatedAt: now
        )
        do {
            let rows = try items.enumerated().map { position, item in
                guard let planJSON = StrengthTrainingContract.encodeExercisePlan(item.plan) else {
                    throw StrengthTrainingContract.ValidationError.invalidRoutineExercise
                }
                return StrengthRoutineExerciseRow(
                    id: item.id,
                    routineId: routineID,
                    exerciseId: item.exercise.id,
                    position: position,
                    targetSets: item.targetSets,
                    targetRepsMin: item.plan.mode == "timed" ? nil : item.targetRepsMin,
                    targetRepsMax: item.plan.mode == "timed"
                        ? nil
                        : max(item.targetRepsMin, item.targetRepsMax),
                    targetRPE: item.targetRPE,
                    restSeconds: item.restSeconds,
                    note: item.note.isEmpty ? nil : item.note,
                    planJSON: planJSON,
                    createdAt: item.createdAt,
                    updatedAt: now
                )
            }
            _ = try await repo.saveStrengthRoutine(routine, exercises: rows)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shortWeekday(_ iso: Int) -> String {
        String(fullWeekday(iso).prefix(2)).uppercased()
    }

    private func fullWeekday(_ iso: Int) -> String {
        Calendar.current.weekdaySymbols[iso % 7]
    }

    private func modeBinding(
        _ item: Binding<StrengthRoutineExerciseDraft>
    ) -> Binding<String> {
        Binding(
            get: { item.wrappedValue.plan.mode },
            set: { requestedMode in
                let timed = requestedMode == "timed"
                    || item.wrappedValue.exercise.movementPattern == "cardio"
                item.wrappedValue.plan.mode = timed ? "timed" : "reps"
                if timed {
                    if !["none", "time"].contains(item.wrappedValue.plan.progression) {
                        item.wrappedValue.plan.progression = "time"
                    }
                    item.wrappedValue.plan.targetDurationS =
                        item.wrappedValue.plan.targetDurationS ?? 30
                } else {
                    if item.wrappedValue.plan.progression == "time" {
                        item.wrappedValue.plan.progression = "double_progression"
                    }
                    item.wrappedValue.plan.targetDurationS = nil
                }
            }
        )
    }

    private func restLabel(_ seconds: Int) -> String {
        seconds == 0 ? "No rest" : seconds < 120 ? "\(seconds)s rest" : "\(seconds / 60)m rest"
    }

    private func progressionLabel(_ value: String) -> String {
        switch value {
        case "linear": return "Linear"
        case "time": return "Add time"
        case "none": return "Manual"
        default: return "Rep range"
        }
    }

    private func supersetName(_ group: Int) -> String {
        guard group >= 1, group <= 26,
              let scalar = UnicodeScalar(64 + group)
        else { return "\(group)" }
        return String(Character(scalar))
    }
}

private struct StrengthCustomExerciseEditor: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var muscle = "other"
    @State private var equipment = "other"
    @State private var pattern = "other"
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("appwide.gym.exercise") {
                    TextField("Name", text: $name)
                    Picker("appwide.gym.primary_muscle", selection: $muscle) {
                        ForEach(StrengthTrainingContract.muscles, id: \.self) {
                            Text(strengthDescriptor($0)).tag($0)
                        }
                    }
                    Picker("appwide.gym.equipment", selection: $equipment) {
                        ForEach(StrengthTrainingContract.equipment, id: \.self) {
                            Text(strengthDescriptor($0)).tag($0)
                        }
                    }
                    Picker("Movement", selection: $pattern) {
                        ForEach(StrengthTrainingContract.movementPatterns, id: \.self) {
                            Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0)
                        }
                    }
                }
                Section {
                    Text("appwide.gym.custom_exercise_body")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .navigationTitle("appwide.gym.create_exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(
                            saving
                                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
        .alert("appwide.gym.exercise", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let now = Int(Date().timeIntervalSince1970)
        let exercise = StrengthExerciseRow(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: name,
            primaryMuscle: muscle,
            secondaryMusclesJSON: "[]",
            equipment: equipment,
            movementPattern: pattern,
            isCustom: true,
            createdAt: now,
            updatedAt: now
        )
        do {
            _ = try await repo.saveStrengthExercise(exercise)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
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
                            } ?? "-",
                            caption: "external load",
                            accent: StrandPalette.effortColor
                        )
                        StatTile(
                            label: "Most reps",
                            value: mostReps.map(String.init) ?? "-",
                            caption: "one completed set",
                            accent: StrandPalette.accent
                        )
                        StatTile(
                            label: "Best set volume",
                            value: bestSetVolumeKg.map {
                                UnitFormatter.massFromKilograms($0, unit: massUnit)
                            } ?? "-",
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

func strengthExerciseName(_ exercise: StrengthExerciseRow) -> String {
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
    default:
        guard !exercise.isCustom else { return exercise.name }
        let key = "appwide.gym.exercise.\(exercise.id)"
        let localized = String(localized: String.LocalizationValue(key))
        return localized == key ? exercise.name : localized
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
    case "rest_pause":
        return String(localized: "appwide.gym.rest_pause", defaultValue: "Rest-pause")
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
