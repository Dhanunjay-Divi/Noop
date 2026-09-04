import SwiftUI
import StrandDesign

/// Private editor for the active-medication context. Medication text stays in Keychain; only the
/// presence of a recent user-entered change date reaches the wellness heads-up engine.
struct MedicationSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let onChanged: () -> Void

    @State private var entries: [MedicationEntry] = []
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var details = ""
    @State private var hasChangeDate = false
    @State private var changeDate = Date()
    @State private var pendingRemoval: MedicationEntry?
    @State private var operationFailed = false

    var body: some View {
        Group {
            #if os(macOS)
            content.frame(minWidth: 520, idealWidth: 600, minHeight: 620, idealHeight: 720)
            #else
            content
            #endif
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .task { reload() }
        .alert("Medication list wasn't updated", isPresented: $operationFailed) {
            Button("OK", role: .cancel) { operationFailed = false }
        } message: {
            Text("The secure store could not be changed. Nothing was assumed or sent anywhere.")
        }
        .confirmationDialog(
            "Remove this medication from your active list?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let entry = pendingRemoval else { return }
                pendingRemoval = nil
                remove(entry)
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                header
                editorCard
                activeList
                privacyCard
            }
            .padding(NoopMetrics.screenPadding)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("Medication context")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Record current medications privately so a recent start or dose change can be shown beside a wearable shift.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .accessibilityLabel("Close medication context")
        }
    }

    private var editorCard: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(editingID == nil ? "Add medication" : "Edit medication")
                    .strandOverline()

                TextField("Medication name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Medication name")

                TextField("Dose or timing (optional)", text: $details)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Dose or timing, optional")

                Toggle("Started or dose changed recently", isOn: $hasChangeDate)
                    .toggleStyle(.noopSwitch)

                if hasChangeDate {
                    DatePicker(
                        "Change date",
                        selection: $changeDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .tint(StrandPalette.accent)
                }

                HStack(spacing: NoopMetrics.space2) {
                    Button(editingID == nil ? "Add" : "Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if editingID != nil {
                        Button("Cancel") { clearDraft() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var activeList: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("Active medications").strandOverline()
                Spacer()
                Text("\(entries.count)")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }

            if entries.isEmpty {
                Text("No medications recorded.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.vertical, NoopMetrics.space2)
            } else {
                ForEach(entries) { entry in
                    NoopCard {
                        HStack(alignment: .top, spacing: NoopMetrics.space3) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name)
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                if !entry.details.isEmpty {
                                    Text(entry.details)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                                Text(changeDescription(entry))
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer(minLength: 8)
                            Menu {
                                Button("Edit") { edit(entry) }
                                Button("Remove", role: .destructive) {
                                    pendingRemoval = entry
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(width: 32, height: 32)
                            }
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel("Actions for \(entry.name)")
                        }
                    }
                }
            }
        }
    }

    private var privacyCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Label("Private context, not medication advice", systemImage: "lock.fill")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Names and notes are encrypted in this device's secure store and are excluded from backups, sync, Coach prompts, analytics, and logs. A recent change is explanatory only: it never lowers an alert, changes a score, checks interactions, recommends a dose, or confirms that a medication was taken.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reload() {
        entries = MedicationStore.active.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func save() {
        let entry = MedicationEntry(
            id: editingID ?? UUID(),
            name: name,
            details: details,
            changeDay: hasChangeDate ? Repository.localDayKey(changeDate) : nil
        )
        guard MedicationStore.upsert(entry) else {
            operationFailed = true
            return
        }
        reload()
        clearDraft()
        onChanged()
    }

    private func remove(_ entry: MedicationEntry) {
        guard MedicationStore.remove(id: entry.id) else {
            operationFailed = true
            return
        }
        if editingID == entry.id { clearDraft() }
        reload()
        onChanged()
    }

    private func edit(_ entry: MedicationEntry) {
        editingID = entry.id
        name = entry.name
        details = entry.details
        if let day = entry.changeDay, let date = Self.dayFormatter.date(from: day) {
            hasChangeDate = true
            changeDate = date
        } else {
            hasChangeDate = false
            changeDate = Date()
        }
    }

    private func clearDraft() {
        editingID = nil
        name = ""
        details = ""
        hasChangeDate = false
        changeDate = Date()
    }

    private func changeDescription(_ entry: MedicationEntry) -> String {
        guard let day = entry.changeDay,
              let date = Self.dayFormatter.date(from: day) else {
            return String(localized: "No recent start or dose change recorded")
        }
        return String(localized: "Start or dose change: \(Self.displayFormatter.string(from: date))")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
