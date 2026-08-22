import StrandDesign
import SwiftUI
import WhoopStore

/// A local-first meal log backed by `nutritionEntry`. Individual nutrients stay nullable: logging
/// protein alone never invents zero calories, carbs, or fat. Imported CSV daily summaries are clearly
/// labeled and remain separate from editable manual meals.
struct NutritionLogView: View {
    private struct EditorContext: Identifiable {
        let id = UUID()
        let entry: NutritionEntryRow?
        let day: Date
        let catalogItem: NutritionCatalogItemRow?
    }

    @EnvironmentObject private var repo: Repository

    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var entries: [NutritionEntryRow] = []
    @State private var recentEntries: [NutritionEntryRow] = []
    @State private var totals = NutritionDailyTotals(
        day: Repository.localDayKey(Date()),
        caloriesKcal: nil,
        proteinG: nil,
        carbsG: nil,
        fatG: nil
    )
    @State private var loading = true
    @State private var editor: EditorContext?
    @State private var deleteCandidate: NutritionEntryRow?
    @State private var errorMessage: String?
    @State private var quickSavingID: String?
    @State private var reloadToken = 0
    @State private var barcodeLookupPresented = false
    @State private var libraryPresented = false

    private var dayKey: String { Repository.localDayKey(selectedDay) }
    private var isToday: Bool { Calendar.current.isDateInToday(selectedDay) }

    var body: some View {
        ScreenScaffold(
            title: "nutrition.title",
            subtitle: "nutrition.subtitle",
            onRefresh: { await load() },
            topBackground: liquidScaffoldSky()
        ) {
            dateNavigator
            totalsCard
            entrySection
            provenanceCard
        }
        .task(id: "\(dayKey)-\(reloadToken)") { await load() }
        .sheet(item: $editor) { context in
            NutritionEntryEditor(
                entry: context.entry,
                day: context.day,
                catalogItem: context.catalogItem,
                onSave: { row, catalogItem in
                    try await repo.saveNutritionEntry(row)
                    if let catalogItem {
                        try await repo.saveNutritionCatalogItem(catalogItem)
                    }
                    if let sourceID = context.catalogItem?.id {
                        try await repo.markNutritionCatalogItemUsed(
                            id: sourceID,
                            at: Int(Date().timeIntervalSince1970)
                        )
                    }
                    reloadToken += 1
                }
            )
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #endif
        }
        .sheet(isPresented: $barcodeLookupPresented) {
            NutritionBarcodeLookupView { item in
                barcodeLookupPresented = false
                editor = EditorContext(
                    entry: nil,
                    day: selectedDay,
                    catalogItem: item
                )
            }
            .environmentObject(repo)
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #endif
        }
        .sheet(isPresented: $libraryPresented) {
            NutritionLibraryPicker { item in
                libraryPresented = false
                editor = EditorContext(
                    entry: nil,
                    day: selectedDay,
                    catalogItem: item
                )
            }
            .environmentObject(repo)
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #endif
        }
        .confirmationDialog(
            "nutrition.delete.title",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("nutrition.delete.action", role: .destructive) {
                guard let candidate = deleteCandidate else { return }
                deleteCandidate = nil
                Task { await delete(candidate) }
            }
            Button("nutrition.cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text(deleteCandidate?.origin == NutritionLogContract.csvOrigin
                 ? String(localized: "nutrition.delete.imported_body")
                 : String(localized: "nutrition.delete.manual_body"))
        }
        .alert("nutrition.alert.title", isPresented: errorBinding) {
            Button("nutrition.ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var dateNavigator: some View {
        NoopCard {
            HStack(spacing: NoopMetrics.space3) {
                Button {
                    stepDay(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel(Text("nutrition.date.previous"))

                DatePicker(
                    "nutrition.date.pick",
                    selection: $selectedDay,
                    in: ...Calendar.current.startOfDay(for: Date()),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(maxWidth: .infinity)

                Button {
                    stepDay(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isToday ? StrandPalette.textTertiary : StrandPalette.accent)
                .disabled(isToday)
                .accessibilityLabel(Text("nutrition.date.next"))
            }
        }
    }

    private var totalsCard: some View {
        NoopCard(tint: StrandPalette.statusPositive) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isToday
                             ? String(localized: "nutrition.intake.today")
                             : selectedDay.formatted(date: .abbreviated, time: .omitted))
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(formatted(totals.caloriesKcal, maximumFractionDigits: 0))
                            .font(StrandFont.rounded(42, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(totals.caloriesKcal == nil
                         ? String(localized: "nutrition.intake.no_calories")
                         : "kcal")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                HStack(spacing: NoopMetrics.space3) {
                    macroCell("nutrition.nutrient.protein", value: totals.proteinG, tint: StrandPalette.statusPositive)
                    macroCell("nutrition.nutrient.carbs", value: totals.carbsG, tint: StrandPalette.accent)
                    macroCell("nutrition.nutrient.fat", value: totals.fatG, tint: StrandPalette.statusWarning)
                }

                Text(totalsExplanation)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .redacted(reason: loading ? .placeholder : [])
        .accessibilityElement(children: .combine)
    }

    private func macroCell(_ label: LocalizedStringKey, value: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value.map { "\(formatted($0, maximumFractionDigits: 1)) g" } ?? "—")
                .font(StrandFont.rounded(17, weight: .semibold))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var totalsExplanation: String {
        if totals.hasMixedSources {
            return String(localized:
                "nutrition.totals.mixed")
        }
        if totals.hasImportedSummary {
            return String(localized:
                "nutrition.totals.imported")
        }
        if totals.hasManualEntries {
            return String(localized:
                "nutrition.totals.manual")
        }
        return String(localized: "nutrition.totals.empty")
    }

    private var entrySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .center) {
                SectionHeader("nutrition.entries.title", overline: "nutrition.entries.overline")
                Spacer(minLength: 12)
                Button {
                    barcodeLookupPresented = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel(Text("nutrition.actions.scan"))
                .help(String(localized: "nutrition.actions.scan"))

                Button {
                    libraryPresented = true
                } label: {
                    Image(systemName: "books.vertical.fill")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel(Text("nutrition.actions.library"))
                .help(String(localized: "nutrition.actions.library"))

                Button {
                    editor = EditorContext(entry: nil, day: selectedDay, catalogItem: nil)
                } label: {
                    Label("nutrition.entries.add", systemImage: "plus")
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                .accessibilityLabel(Text("nutrition.entries.add_accessibility"))
            }

            if !recentEntries.isEmpty {
                quickRepeatSection
            }

            if !recentEntries.isEmpty && !entries.isEmpty {
                Text("nutrition.entries.saved_title")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, NoopMetrics.space2)
                    .accessibilityAddTraits(.isHeader)
            }

            if loading && entries.isEmpty {
                ScreenStateCard(
                    kind: .loading,
                    title: "nutrition.state.loading_title",
                    message: "nutrition.state.loading_body"
                )
            } else if entries.isEmpty {
                ScreenStateCard(
                    kind: .empty,
                    title: "nutrition.state.empty_title",
                    message: "nutrition.state.empty_body",
                    symbol: "fork.knife.circle"
                )
            } else {
                NoopCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry)
                            if index < entries.count - 1 {
                                Divider()
                                    .padding(.leading, 58)
                                    .foregroundStyle(StrandPalette.hairline)
                            }
                        }
                    }
                }
            }
        }
    }

    private var quickRepeatSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text("nutrition.repeat.title")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("nutrition.repeat.overline")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text("nutrition.repeat.body")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NoopMetrics.space3) {
                    ForEach(recentEntries) { entry in
                        Button {
                            Task { await repeatEntry(entry) }
                        } label: {
                            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                                HStack {
                                    Image(systemName: mealIcon(entry.mealType))
                                        .foregroundStyle(StrandPalette.accent)
                                        .accessibilityHidden(true)
                                    Spacer(minLength: 8)
                                    if quickSavingID == entry.id {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(StrandPalette.accent)
                                            .accessibilityHidden(true)
                                    }
                                }
                                Text(entryTitle(entry))
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .lineLimit(1)
                                Text(repeatDetail(entry))
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(NoopMetrics.space3)
                            .frame(width: 170, alignment: .leading)
                            .frame(minHeight: 96, alignment: .leading)
                            .background(
                                StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(StrandPalette.hairline, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(quickSavingID != nil)
                        .accessibilityLabel(
                            nutritionFormat(
                                String(localized: "nutrition.repeat.action_format"),
                                entryTitle(entry)
                            )
                        )
                        .accessibilityHint(Text("nutrition.repeat.hint"))
                    }
                }
            }
        }
        .padding(.vertical, NoopMetrics.space2)
    }

    private func entryRow(_ entry: NutritionEntryRow) -> some View {
        let imported = entry.origin == NutritionLogContract.csvOrigin
        return HStack(spacing: NoopMetrics.space3) {
            Image(systemName: imported ? "square.and.arrow.down.fill" : mealIcon(entry.mealType))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(imported ? StrandPalette.textSecondary : StrandPalette.accent)
                .frame(width: 34, height: 34)
                .background(StrandPalette.surfaceInset, in: Circle())
                .accessibilityHidden(true)

            Button {
                if !imported {
                    editor = EditorContext(
                        entry: entry,
                        day: selectedDay,
                        catalogItem: nil
                    )
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(entryTitle(entry))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        if imported {
                            Text("nutrition.entry.imported_badge")
                                .font(StrandFont.caption.weight(.semibold))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(StrandPalette.surfaceInset, in: Capsule())
                        }
                    }
                    Text(entryDetail(entry))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(imported)
            .accessibilityHint(
                Text(imported ? "nutrition.entry.imported_hint" : "nutrition.entry.edit_hint")
            )

            Button(role: .destructive) {
                deleteCandidate = entry
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                nutritionFormat(
                    String(localized: "nutrition.entry.delete_format"),
                    entryTitle(entry)
                )
            )
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private var provenanceCard: some View {
        NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("nutrition.privacy.title")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("nutrition.privacy.body")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func stepDay(_ delta: Int) {
        guard let candidate = Calendar.current.date(byAdding: .day, value: delta, to: selectedDay) else {
            return
        }
        selectedDay = min(
            Calendar.current.startOfDay(for: candidate),
            Calendar.current.startOfDay(for: Date())
        )
    }

    @MainActor
    private func load() async {
        let requestedDay = dayKey
        loading = true
        do {
            let snapshot = try await repo.nutritionLogSnapshot(day: requestedDay)
            guard requestedDay == dayKey else {
                #if DEBUG
                if AppleDemoSeeder.nutritionRequested {
                    NSLog(
                        "Nutrition demo snapshot discarded requested=\(requestedDay) current=\(dayKey)"
                    )
                }
                #endif
                return
            }
            entries = snapshot.entries
            totals = snapshot.totals
            recentEntries = snapshot.recentManualEntries
            #if DEBUG
            if AppleDemoSeeder.nutritionRequested {
                NSLog(
                    "Nutrition demo state applied entries=\(entries.count) " +
                    "recent=\(recentEntries.count) mixed=\(totals.hasMixedSources)"
                )
            }
            #endif
        } catch {
            guard requestedDay == dayKey else { return }
            errorMessage = error.localizedDescription
        }
        if requestedDay == dayKey { loading = false }
    }

    @MainActor
    private func delete(_ entry: NutritionEntryRow) async {
        do {
            try await repo.removeNutritionEntry(id: entry.id)
            reloadToken += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func repeatEntry(_ source: NutritionEntryRow) async {
        guard quickSavingID == nil else { return }
        quickSavingID = source.id
        defer { quickSavingID = nil }
        do {
            let timestamp = Int(Date().timeIntervalSince1970)
            let row = try NutritionLogContract.repeatedManualEntry(
                from: source,
                id: UUID().uuidString.lowercased(),
                day: dayKey,
                occurredAt: Int(repeatDate(for: source).timeIntervalSince1970),
                timestamp: timestamp
            )
            try await repo.saveNutritionEntry(row)
            reloadToken += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func repeatDate(for source: NutritionEntryRow) -> Date {
        if isToday { return Date() }
        let sourceDate = Date(timeIntervalSince1970: TimeInterval(source.occurredAt))
        let time = Calendar.current.dateComponents([.hour, .minute], from: sourceDate)
        return Calendar.current.date(
            bySettingHour: time.hour ?? 12,
            minute: time.minute ?? 0,
            second: 0,
            of: selectedDay
        ) ?? selectedDay
    }

    private func entryTitle(_ entry: NutritionEntryRow) -> String {
        if let label = entry.label, !label.isEmpty { return label }
        if entry.mealType == "daily_total" {
            return String(localized: "nutrition.entry.imported_total")
        }
        return mealLabel(entry.mealType)
    }

    private func entryDetail(_ entry: NutritionEntryRow) -> String {
        var pieces: [String] = []
        if entry.mealType != "daily_total" {
            pieces.append(Date(timeIntervalSince1970: TimeInterval(entry.occurredAt))
                .formatted(date: .omitted, time: .shortened))
        }
        if let value = entry.caloriesKcal {
            pieces.append("\(formatted(value, maximumFractionDigits: 0)) kcal")
        }
        if let value = entry.proteinG { pieces.append("P \(formatted(value, maximumFractionDigits: 1)) g") }
        if let value = entry.carbsG { pieces.append("C \(formatted(value, maximumFractionDigits: 1)) g") }
        if let value = entry.fatG { pieces.append("F \(formatted(value, maximumFractionDigits: 1)) g") }
        if pieces.isEmpty {
            pieces.append(entry.note ?? String(localized: "nutrition.entry.no_values"))
        }
        return pieces.joined(separator: " · ")
    }

    private func repeatDetail(_ entry: NutritionEntryRow) -> String {
        var pieces: [String] = []
        if let value = entry.caloriesKcal {
            pieces.append("\(formatted(value, maximumFractionDigits: 0)) kcal")
        }
        if let value = entry.proteinG {
            pieces.append("\(formatted(value, maximumFractionDigits: 1)) g protein")
        }
        return pieces.isEmpty ? mealLabel(entry.mealType) : pieces.joined(separator: " · ")
    }

    private func mealLabel(_ value: String) -> String {
        switch value {
        case "breakfast": return String(localized: "nutrition.meal.breakfast")
        case "lunch": return String(localized: "nutrition.meal.lunch")
        case "dinner": return String(localized: "nutrition.meal.dinner")
        case "snack": return String(localized: "nutrition.meal.snack")
        default: return String(localized: "nutrition.meal.other")
        }
    }

    private func mealIcon(_ value: String) -> String {
        switch value {
        case "breakfast": return "sunrise.fill"
        case "lunch": return "sun.max.fill"
        case "dinner": return "moon.stars.fill"
        case "snack": return "takeoutbag.and.cup.and.straw.fill"
        default: return "fork.knife"
        }
    }

    private func formatted(_ value: Double?, maximumFractionDigits: Int) -> String {
        guard let value else { return "—" }
        return formatted(value, maximumFractionDigits: maximumFractionDigits)
    }

    private func formatted(_ value: Double, maximumFractionDigits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...maximumFractionDigits)))
    }
}

func nutritionFormat(_ template: String, _ arguments: CVarArg...) -> String {
    String(format: template, locale: .current, arguments: arguments)
}

private struct NutritionEntryEditor: View {
    private enum Meal: String, CaseIterable, Identifiable {
        case breakfast, lunch, dinner, snack, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .breakfast: String(localized: "nutrition.meal.breakfast")
            case .lunch: String(localized: "nutrition.meal.lunch")
            case .dinner: String(localized: "nutrition.meal.dinner")
            case .snack: String(localized: "nutrition.meal.snack")
            case .other: String(localized: "nutrition.meal.other")
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    let entry: NutritionEntryRow?
    let day: Date
    let catalogItem: NutritionCatalogItemRow?
    let onSave: (NutritionEntryRow, NutritionCatalogItemRow?) async throws -> Void

    @State private var meal: Meal
    @State private var occurredAt: Date
    @State private var label: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String
    @State private var note: String
    @State private var saveToLibrary: Bool
    @State private var saving = false
    @State private var errorMessage: String?

    init(
        entry: NutritionEntryRow?,
        day: Date,
        catalogItem: NutritionCatalogItemRow?,
        onSave: @escaping (NutritionEntryRow, NutritionCatalogItemRow?) async throws -> Void
    ) {
        self.entry = entry
        self.day = day
        self.catalogItem = catalogItem
        self.onSave = onSave
        _meal = State(
            initialValue: Meal(rawValue: entry?.mealType ?? catalogItem?.mealType ?? "") ?? .other
        )
        let initialTime = entry.map { Date(timeIntervalSince1970: TimeInterval($0.occurredAt)) }
            ?? NutritionEntryEditor.defaultTime(on: day)
        _occurredAt = State(initialValue: initialTime)
        _label = State(initialValue: entry?.label ?? catalogItem?.name ?? "")
        _calories = State(initialValue: Self.fieldText(entry?.caloriesKcal ?? catalogItem?.caloriesKcal))
        _protein = State(initialValue: Self.fieldText(entry?.proteinG ?? catalogItem?.proteinG))
        _carbs = State(initialValue: Self.fieldText(entry?.carbsG ?? catalogItem?.carbsG))
        _fat = State(initialValue: Self.fieldText(entry?.fatG ?? catalogItem?.fatG))
        _note = State(initialValue: entry?.note ?? "")
        _saveToLibrary = State(initialValue: false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                            Picker("nutrition.editor.meal", selection: $meal) {
                                ForEach(Meal.allCases) { Text($0.label).tag($0) }
                            }
                            DatePicker("nutrition.editor.time", selection: $occurredAt, displayedComponents: .hourAndMinute)
                            TextField("nutrition.editor.name_optional", text: $label)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if entry == nil && catalogItem?.isSaved != true {
                        NoopCard {
                            Toggle(
                                catalogItem == nil
                                    ? "nutrition.editor.save_library"
                                    : "nutrition.editor.save_food_library",
                                isOn: $saveToLibrary
                            )
                            .tint(StrandPalette.accent)
                        }
                    }

                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        SectionHeader("nutrition.editor.known_title", overline: "nutrition.title")
                        NoopCard {
                            LazyVGrid(
                                columns: [GridItem(.flexible()), GridItem(.flexible())],
                                spacing: NoopMetrics.space3
                            ) {
                                nutrientField("nutrition.nutrient.calories", unit: "kcal", text: $calories)
                                nutrientField("nutrition.nutrient.protein", unit: "g", text: $protein)
                                nutrientField("nutrition.nutrient.carbs", unit: "g", text: $carbs)
                                nutrientField("nutrition.nutrient.fat", unit: "g", text: $fat)
                            }
                            Text("nutrition.editor.unknown_body")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .padding(.top, NoopMetrics.space3)
                        }
                    }

                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("nutrition.editor.notes")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            TextField("nutrition.editor.notes_optional", text: $note, axis: .vertical)
                                .lineLimit(3...6)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(20)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(
                entry == nil
                    ? String(localized: "nutrition.editor.add")
                    : String(localized: "nutrition.editor.edit")
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("nutrition.cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        saving
                            ? String(localized: "nutrition.editor.saving")
                            : String(localized: "nutrition.editor.save")
                    ) { save() }
                        .disabled(saving)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 560)
        .alert("nutrition.editor.save_error", isPresented: errorBinding) {
            Button("nutrition.ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func nutrientField(
        _ title: LocalizedStringKey,
        unit: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 6) {
                TextField("—", text: text)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        guard !saving else { return }
        do {
            let caloriesValue = try parse(
                calories,
                field: String(localized: "nutrition.nutrient.calories")
            )
            let proteinValue = try parse(
                protein,
                field: String(localized: "nutrition.nutrient.protein")
            )
            let carbsValue = try parse(
                carbs,
                field: String(localized: "nutrition.nutrient.carbs")
            )
            let fatValue = try parse(
                fat,
                field: String(localized: "nutrition.nutrient.fat")
            )
            let timestamp = Int(Date().timeIntervalSince1970)
            let occurrence = Self.combine(day: day, time: occurredAt)
            let row = NutritionEntryRow(
                id: entry?.id ?? UUID().uuidString.lowercased(),
                origin: NutritionLogContract.manualOrigin,
                day: Repository.localDayKey(day),
                occurredAt: Int(occurrence.timeIntervalSince1970),
                mealType: meal.rawValue,
                label: label,
                caloriesKcal: caloriesValue,
                proteinG: proteinValue,
                carbsG: carbsValue,
                fatG: fatValue,
                note: note,
                createdAt: entry?.createdAt ?? timestamp,
                updatedAt: max(timestamp, entry?.createdAt ?? timestamp)
            )
            _ = try NutritionLogContract.validated(row)
            saving = true
            Task { @MainActor in
                do {
                    try await onSave(row, try catalogRow(from: row, timestamp: timestamp))
                    dismiss()
                } catch {
                    saving = false
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func catalogRow(
        from row: NutritionEntryRow,
        timestamp: Int
    ) throws -> NutritionCatalogItemRow? {
        guard entry == nil, saveToLibrary else { return nil }
        if var existing = catalogItem {
            existing.name = row.label ?? existing.name
            existing.caloriesKcal = row.caloriesKcal
            existing.proteinG = row.proteinG
            existing.carbsG = row.carbsG
            existing.fatG = row.fatG
            existing.mealType = row.mealType
            existing.isSaved = true
            existing.lastUsedAt = timestamp
            existing.updatedAt = max(timestamp, existing.createdAt)
            return try NutritionCatalogContract.validated(existing)
        }
        return try NutritionCatalogContract.validated(NutritionCatalogItemRow(
            id: "meal:\(UUID().uuidString.lowercased())",
            kind: NutritionCatalogContract.mealKind,
            name: row.label ?? "",
            caloriesKcal: row.caloriesKcal,
            proteinG: row.proteinG,
            carbsG: row.carbsG,
            fatG: row.fatG,
            mealType: row.mealType,
            source: NutritionCatalogContract.manualSource,
            isSaved: true,
            lastUsedAt: timestamp,
            createdAt: timestamp,
            updatedAt: timestamp
        ))
    }

    private func parse(_ text: String, field: String) throws -> Double? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard let value = NutritionLogContract.parseUserNumber(clean),
              value >= 0
        else {
            throw NutritionEditorError.invalidNumber(field)
        }
        return value
    }

    private static func defaultTime(on day: Date) -> Date {
        let now = Date()
        let time = Calendar.current.dateComponents([.hour, .minute], from: now)
        return Calendar.current.date(
            bySettingHour: time.hour ?? 12,
            minute: time.minute ?? 0,
            second: 0,
            of: day
        ) ?? day
    }

    private static func combine(day: Date, time: Date) -> Date {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.date(
            bySettingHour: components.hour ?? 12,
            minute: components.minute ?? 0,
            second: 0,
            of: day
        ) ?? day
    }

    private static func fieldText(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

private enum NutritionEditorError: LocalizedError {
    case invalidNumber(String)

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let field):
            return nutritionFormat(
                String(localized: "nutrition.editor.invalid_number_format"),
                field
            )
        }
    }
}
