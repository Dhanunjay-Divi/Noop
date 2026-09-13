import SwiftUI
import AVFoundation
import Speech
import MarkdownUI
import StrandDesign
import WhoopStore

/// Coach, the one feature in NOOP that talks to the network.
///
/// It is strictly opt-in and bring-your-own-key: the user pastes their own OpenAI
/// or Anthropic API key (stored in the macOS Keychain by `AICoachEngine`), and only
/// a compact text summary of their metrics plus their question ever leaves the Mac.
/// Nothing is sent until a key is saved and a question asked.
///
/// This screen compiles against `AICoachEngine`'s public API (the macos-core agent's
/// contract): `hasKey`, `provider` / `provider.modelOptions`, `model`, `messages`,
/// `sending`, `errorText`, `setKey(_:)`, `clearKey()`, and `send(_:)`.
struct CoachView: View {
    @EnvironmentObject var coach: AICoachEngine
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Draft text in the composer (the question being typed).
    @State private var draft: String = ""
    /// Pending key text in the setup card (never persisted here, handed to `setKey`).
    @State private var keyDraft: String = ""
    /// Whether the model selector is in free-text "Custom…" mode.
    @State private var customModel: Bool = false
    /// The id typed in the "Custom…" field.
    @State private var customModelDraft: String = ""
    /// Whether the editable-system-prompt section is expanded. Collapsed by default so the settings
    /// stay compact; most users never touch the prompt.
    @State private var promptExpanded: Bool = false
    /// Working copy of the system prompt while editing, committed to the engine on change so an edit
    /// takes effect on the next send. Seeded from the engine when the editor opens.
    @State private var promptDraft: String = ""
    @State private var memoryExpanded = false
    @State private var memoryDraft = ""
    @State private var editingMemoryID: String?
    @State private var confirmClearConversation = false
    @StateObject private var dictation = CoachDictationController()
    @State private var checkInEnabled = false
    @State private var checkInMinutes = 18 * 60
    @State private var checkInError: String?
    @State private var showingJournalDraft = false
    @State private var journalDraftText = ""
    @State private var journalSelections = Set<String>()
    @State private var showingRoutineDraft = false
    @State private var routineName = "Coach plan"
    @State private var routineSelections = Set<String>()
    @State private var savingAction = false
    @FocusState private var composerFocused: Bool
    @FocusState private var setupKeyFocused: Bool

    /// Sentinel tag for the "Custom…" entry in the model Picker.
    private let customModelTag = "__custom__"

    private let suggestions = [
        String(localized: "appwide.coach.recovery_prompt"),
        String(localized: "What should today's training look like?"),
        String(localized: "Analyse my sleep"),
        String(localized: "Why am I run down?"),
    ]

    private var usesFocusedNavigationHeader: Bool {
        #if os(iOS)
        composerFocused || setupKeyFocused
        #else
        false
        #endif
    }

    var body: some View {
        ScreenScaffold(title: usesFocusedNavigationHeader ? nil : "Coach",
                       subtitle: usesFocusedNavigationHeader
                            ? nil
                            : "appwide.coach.subtitle",
                       // Liquid finish: the same full-bleed day-of-sky backdrop Today + the other liquid
                       // tabs carry, so Coach sits in one atmosphere. Static + non-interactive; the frosted
                       // message/setup cards below sit on the opaque canvas and stay legible.
                       topBackground: liquidScaffoldSky()) {
            if coach.isConfigured {
                connectedHeader
                consentBar
                // v5: a SECOND opt-in, only meaningful once data access is on, folds a summary of the
                // new on-device signals (your strongest patterns + Lab Book) into the coach context.
                if coach.dataConsent { onDeviceSignalsBar }
                systemPromptBar
                memoryBar
                checkInBar
                transcript
                if let error = coach.errorText, !error.isEmpty {
                    errorBanner(error)
                }
                suggestionChips
                coachActions
                if let error = dictation.errorText, !error.isEmpty {
                    errorBanner(error)
                }
                composer
                privacyFootnote
            } else {
                setupCard
            }
        }
        .toolbar {
            #if os(iOS)
            if usesFocusedNavigationHeader {
                ToolbarItem(placement: .principal) {
                    Text("Coach")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
            #endif
            if coach.isConfigured {
                ToolbarItem {
                    Button(role: .destructive) {
                        coach.disconnect()
                        keyDraft = ""
                    } label: {
                        Label("Disconnect", systemImage: "gearshape")
                    }
                    .help("Forget the saved key and disconnect")
                    .accessibilityLabel("Disconnect provider")
                }
            }
        }
        .task {
            checkInEnabled = CoachCheckInNotifications.isEnabled
            checkInMinutes = CoachCheckInNotifications.minutes
        }
        .onDisappear { dictation.stop() }
        .sheet(isPresented: $showingJournalDraft) {
            journalDraftSheet
        }
        .sheet(isPresented: $showingRoutineDraft) {
            routineDraftSheet
        }
        .confirmationDialog(
            "coach.clear.title",
            isPresented: $confirmClearConversation,
            titleVisibility: .visible
        ) {
            Button("coach.clear.action", role: .destructive) {
                Task { await coach.clearConversation() }
            }
            Button("coach.cancel", role: .cancel) {}
        } message: {
            Text("coach.clear.body")
        }
        #if DEBUG
        // Runtime shell QA needs a real inline text field so keyboard notifications exercise
        // RootTabView instead of a modal that independently covers the floating navigation.
        .task { await runTabShellKeyboardDemoIfRequested() }
        #endif
    }

    /// Explicit, revocable permission for the coach to read & send the user's data. Off by default.
    /// A frosted Charge-tinted card so it reads as part of the green Coach world, not a flat panel.
    private var consentBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.dataConsent ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(coach.dataConsent ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let the coach use my data")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.dataConsent
                         ? "On: a summary of your recovery, effort, sleep, heart and available vital signals, plus workouts, is shared with the provider for tailored coaching."
                         : "Off: the coach answers generally and sends none of your metrics.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.dataConsent)
                    .labelsHidden().toggleStyle(.noopSwitch)
                    .accessibilityLabel("Let the coach use my data")
            }
        }
    }

    /// The v5 second opt-in: include a SUMMARY of the new on-device signals (strongest n-of-1 patterns +
    /// Lab Book markers). Summary-only, never raw readings, so the no-raw-egress posture holds.
    private var onDeviceSignalsBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.includeOnDeviceSignals ? "checklist.checked" : "checklist")
                    .foregroundStyle(coach.includeOnDeviceSignals ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Also share my patterns & Lab Book")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.includeOnDeviceSignals
                         ? "On: a short summary of your strongest patterns and logged health numbers is added. Summaries only, never raw readings."
                         : "Off: only your core metrics are shared, not your patterns or Lab Book.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.includeOnDeviceSignals)
                    .labelsHidden().toggleStyle(.noopSwitch)
                    .accessibilityLabel("Also share my patterns and Lab Book with the coach")
            }
        }
    }

    /// Editable system prompt, the instructions that frame the coach. Collapsed by default; expanding
    /// reveals a TextEditor bound to the engine (edits persist to UserDefaults and take effect on the
    /// next message) plus a Reset-to-default control. Lives inline in the existing settings, NOT a modal.
    private var systemPromptBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: promptExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) {
                        promptExpanded.toggle()
                        if promptExpanded { promptDraft = coach.customSystemPrompt }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.alignleft")
                            .foregroundStyle(coach.hasCustomSystemPrompt ? StrandPalette.accent : StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Coach instructions")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(coach.hasCustomSystemPrompt
                                 ? "Customised. Your edited instructions frame every reply."
                                 : "Edit how the coach thinks and talks. Takes effect on your next message.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: promptExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(promptExpanded ? "Collapse coach instructions" : "Edit coach instructions")

                if promptExpanded {
                    TextEditor(text: $promptDraft)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140, maxHeight: 240)
                        .padding(8)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onChangeCompat(of: promptDraft) { newValue in
                            coach.customSystemPrompt = newValue
                        }
                        .accessibilityLabel("Coach instructions editor")

                    HStack {
                        Spacer()
                        Button {
                            coach.resetSystemPrompt()
                            promptDraft = coach.customSystemPrompt
                        } label: {
                            Label("Reset to default", systemImage: "arrow.uturn.backward")
                                .font(StrandFont.footnote)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                        .disabled(!coach.hasCustomSystemPrompt)
                        .accessibilityLabel("Reset coach instructions to default")
                    }
                }
            }
        }
    }

    // MARK: - Setup (no key yet)

    private var setupCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Connect a provider")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                Text("Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Provider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").strandOverline()
                    providerControl
                }

                // Server URL (Custom / local LLM only)
                if coach.provider == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL").strandOverline()
                        TextField("http://localhost:11434/v1", text: $coach.customBaseURL)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .disableAutocorrection(true)
                            .accessibilityLabel("Server URL")
                        Text("Any OpenAI-compatible server: Ollama, LM Studio, llama.cpp, or your own gateway. The request goes only to the endpoint you choose; use an on-device endpoint when it must stay on \(Platform.deviceNounPhrase).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Key header").strandOverline()
                        Picker("Key header", selection: $coach.customAuthHeader) {
                            ForEach(CustomAIAuthHeader.allCases) { header in
                                Text(header.displayName).tag(header)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Key header")
                        Text("Use Bearer for most local servers; use x-api-key for gateways that require that header.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Model
                modelSelector

                // Key
                VStack(alignment: .leading, spacing: 6) {
                    Text(coach.provider == .custom ? "API key (optional)" : "API key").strandOverline()
                    SecureField(coach.provider == .custom
                                ? "Only if your server requires one"
                                : "Paste your \(coach.provider.displayName) API key", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .focused($setupKeyFocused)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onSubmit { coach.provider == .custom ? connectCustom() : saveKey() }
                        .accessibilityLabel("API key")
                }

                HStack {
                    if coach.provider == .custom {
                        NoopButton("Connect", systemImage: "link", kind: .primary, action: connectCustom)
                            .disabled(coach.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        NoopButton("Save key", systemImage: "key.fill", kind: .primary, action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Spacer()
                }

                Divider().overlay(StrandPalette.hairline)
                privacyFootnote
            }
        }
    }

    private var usesCompactProviderMenu: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder
    private var providerControl: some View {
        if usesCompactProviderMenu {
            Menu {
                ForEach(AIProvider.allCases) { provider in
                    Button {
                        coach.provider = provider
                    } label: {
                        if provider == coach.provider {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(coach.provider.displayName)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Provider")
            .accessibilityValue(coach.provider.displayName)
        } else {
            Picker("Provider", selection: $coach.provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("Provider")
        }
    }

    /// Model selector: a Picker over `coach.availableModels` with a free-text "Custom…" path and a
    /// "Refresh models" button that fetches the provider's live list.
    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model").strandOverline()
                Spacer()
                Button {
                    Task { await coach.refreshModels() }
                } label: {
                    Label("Refresh models", systemImage: "arrow.clockwise")
                        .font(StrandFont.footnote)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .disabled(!coach.hasKey)
                .help("Fetch the available models from \(coach.provider.displayName) using your saved key")
                .accessibilityLabel("Refresh models from provider")
            }

            Picker("Model", selection: modelPickerSelection) {
                ForEach(coach.availableModels, id: \.self) { m in
                    Text(m).tag(m)
                }
                Divider()
                Text("Custom…").tag(customModelTag)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Model")

            if customModel {
                HStack(spacing: 8) {
                    TextField("Enter a model id", text: $customModelDraft)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onSubmit(applyCustomModel)
                        .accessibilityLabel("Custom model id")

                    Button("Use", action: applyCustomModel)
                        .buttonStyle(NoopButtonStyle(.secondary))
                        .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Use custom model")
                }
            }
        }
    }

    /// Bridges the model Picker to `coach.model`, with a "Custom…" sentinel that opens the free-text
    /// field instead of selecting a real id.
    private var modelPickerSelection: Binding<String> {
        Binding(
            get: { customModel ? customModelTag : coach.model },
            set: { newValue in
                if newValue == customModelTag {
                    customModel = true
                    if customModelDraft.isEmpty { customModelDraft = coach.model }
                } else {
                    customModel = false
                    coach.model = newValue
                }
            }
        )
    }

    private func applyCustomModel() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setCustomModel(trimmed)
        customModel = false
    }

    // MARK: - Connected state

    private var connectedHeader: some View {
        HStack(spacing: 10) {
            StatePill("\(coach.provider.displayName) · \(coach.model)", tone: .accent, showsDot: true)
            Spacer()
            if coach.sending {
                StatePill("Thinking", tone: .accent, pulsing: true)
            }
            Button {
                confirmClearConversation = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textSecondary)
            .disabled(coach.messages.isEmpty || coach.sending)
            .help(String(localized: "coach.clear.title"))
            .accessibilityLabel(Text("coach.clear.title"))
        }
    }

    private var memoryBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: memoryExpanded ? 12 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) { memoryExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(StrandPalette.accent)
                        Text("coach.memory.title")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if !coach.memories.isEmpty {
                            Text(String(
                                format: String(localized: "coach.memory.enabled_format"),
                                coach.memories.filter(\.enabled).count
                            ))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        Image(systemName: memoryExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(memoryExpanded
                    ? Text("coach.memory.collapse")
                    : Text("coach.memory.manage"))

                if memoryExpanded {
                    ForEach(coach.memories) { memory in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { memory.enabled },
                                set: { enabled in
                                    Task { await coach.setMemoryEnabled(id: memory.id, enabled: enabled) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.noopSwitch)
                            .accessibilityLabel(Text(String(
                                format: String(localized: "coach.memory.use_format"),
                                memory.text
                            )))

                            Text(memory.text)
                                .font(StrandFont.subhead)
                                .foregroundStyle(memory.enabled
                                    ? StrandPalette.textPrimary
                                    : StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button {
                                editingMemoryID = memory.id
                                memoryDraft = memory.text
                            } label: {
                                Image(systemName: "pencil")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("coach.memory.edit"))
                            Button(role: .destructive) {
                                Task { await coach.deleteMemory(id: memory.id) }
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("coach.memory.delete"))
                        }
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("coach.memory.placeholder", text: $memoryDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...3)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(StrandPalette.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .onChangeCompat(of: memoryDraft) { value in
                                if value.count > CoachStoreContract.maxMemoryCharacters {
                                    memoryDraft = String(value.prefix(CoachStoreContract.maxMemoryCharacters))
                                }
                            }

                        Button {
                            let id = editingMemoryID
                            let text = memoryDraft
                            memoryDraft = ""
                            editingMemoryID = nil
                            Task { await coach.saveMemory(id: id, text: text) }
                        } label: {
                            Image(systemName: editingMemoryID == nil ? "plus" : "checkmark")
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)
                        .disabled(memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(editingMemoryID == nil
                            ? Text("coach.memory.add")
                            : Text("coach.memory.save"))
                    }
                }
            }
        }
    }

    private var checkInBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: checkInEnabled ? 10 : 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(checkInEnabled ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("coach.check_in.title")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("coach.check_in.body")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { checkInEnabled },
                        set: { setCheckInEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.noopSwitch)
                    .accessibilityLabel(Text("coach.check_in.accessibility"))
                }

                if checkInEnabled {
                    HStack {
                        Text("coach.check_in.time")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        DatePicker(
                            "",
                            selection: checkInTimeBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .accessibilityLabel(Text("coach.check_in.time_accessibility"))
                    }
                }

                if let checkInError {
                    Text(checkInError)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
            }
        }
    }

    private var coachActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    Task { await coach.sendTodayBrief() }
                } label: {
                    Label("coach.action.brief", systemImage: "sun.max")
                }
                .disabled(coach.sending)

                Button {
                    journalDraftText = draft
                    journalSelections = Set(CoachJournalDraftPolicy.matches(in: draft))
                    showingJournalDraft = true
                } label: {
                    Label("coach.action.journal", systemImage: "book.closed")
                }

                Button {
                    routineSelections = coach.suggestedRoutineExerciseIDs
                    showingRoutineDraft = true
                } label: {
                    Label("coach.action.routine", systemImage: "figure.strengthtraining.traditional")
                }
            }
            .font(StrandFont.footnote)
            .buttonStyle(.bordered)
            .tint(StrandPalette.accent)
            .padding(.vertical, 1)
        }
    }

    private var journalDraftSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("coach.journal.intro")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("coach.journal.example", text: $journalDraftText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...5)
                        .font(StrandFont.body)
                        .padding(12)
                        .background(StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onChangeCompat(of: journalDraftText) { value in
                            let matches = CoachJournalDraftPolicy.matches(in: value)
                            if !matches.isEmpty { journalSelections.formUnion(matches) }
                        }

                    Button {
                        toggleDictation(existingText: journalDraftText) {
                            journalDraftText = $0
                        }
                    } label: {
                        Label(
                            dictation.isRecording
                                ? String(localized: "coach.dictation.stop")
                                : String(localized: "coach.journal.dictate"),
                            systemImage: dictation.isRecording ? "stop.circle.fill" : "mic.fill"
                        )
                    }
                    .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("coach.journal.review")
                            .strandOverline()
                        ForEach(CoachJournalDraftPolicy.questions, id: \.self) { question in
                            Toggle(question, isOn: Binding(
                                get: { journalSelections.contains(question) },
                                set: { selected in
                                    if selected { journalSelections.insert(question) }
                                    else { journalSelections.remove(question) }
                                }
                            ))
                            .toggleStyle(.noopSwitch)
                        }
                    }
                }
                .padding(20)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text("coach.journal.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("coach.cancel") {
                        dictation.stop()
                        showingJournalDraft = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(savingAction
                        ? String(localized: "coach.saving")
                        : String(
                            format: String(localized: "coach.journal.save_format"),
                            journalSelections.count
                        )) {
                        savingAction = true
                        Task {
                            let saved = await coach.saveJournalDraft(
                                questions: Array(journalSelections),
                                note: journalDraftText
                            )
                            savingAction = false
                            if saved {
                                dictation.stop()
                                showingJournalDraft = false
                            }
                        }
                    }
                    .disabled(journalSelections.isEmpty || savingAction)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 520)
    }

    private var routineDraftSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("coach.routine.intro")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("coach.routine.name", text: $routineName)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .padding(12)
                        .background(StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text("coach.routine.exercises")
                        .strandOverline()
                    ForEach(StrengthTrainingContract.builtInExercises) { exercise in
                        Toggle(exercise.name, isOn: Binding(
                            get: { routineSelections.contains(exercise.id) },
                            set: { selected in
                                if selected { routineSelections.insert(exercise.id) }
                                else { routineSelections.remove(exercise.id) }
                            }
                        ))
                        .toggleStyle(.noopSwitch)
                    }

                    Text("coach.routine.detail")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(20)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text("coach.routine.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("coach.cancel") { showingRoutineDraft = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(savingAction
                        ? String(localized: "coach.saving")
                        : String(localized: "coach.create")) {
                        savingAction = true
                        Task {
                            let saved = await coach.saveRoutineDraft(
                                name: routineName,
                                exerciseIDs: Array(routineSelections)
                            )
                            savingAction = false
                            if saved { showingRoutineDraft = false }
                        }
                    }
                    .disabled(
                        routineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || routineSelections.isEmpty
                        || savingAction
                    )
                }
            }
        }
        .frame(minWidth: 360, minHeight: 520)
    }

    private var transcript: some View {
        StrandCard(padding: 16) {
            if coach.messages.isEmpty {
                emptyTranscript
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Lazy so off-screen bubbles aren't all resident/laid-out at once; with the
                        // `maxStoredMessages` cap the transcript is already bounded, this keeps render cost flat.
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(coach.messages) { message in
                                bubble(message).id(message.id)
                            }
                            if coach.sending {
                                typingIndicator.id("typing")
                            }
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220, maxHeight: 460)
                    .onChangeCompat(of: coach.messages.count) { _ in
                        scrollToEnd(proxy)
                    }
                    .onChangeCompat(of: coach.sending) { _ in
                        scrollToEnd(proxy)
                    }
                }
            }
        }
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask your first question")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Coach reads a summary of your last two weeks plus 30-day averages and recent workouts, then answers in plain language. Try a suggestion below.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(message.text)")
        case .assistant:
            // LLM replies arrive as Markdown (bold, lists, headings, tables),             // rendered with the chat-bubble-sized Strand theme. User bubbles stay
            // verbatim `Text` so typed `*`/`#` never turn into surprise formatting.
            // The reply sits on a frosted Charge-tinted surface, a card, not a flat box.
            HStack {
                Markdown(CustomerFacingBrand.text(message.text))
                    .markdownTheme(.strand)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
                    .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 48)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Coach said: \(CustomerFacingBrand.text(message.text))")
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(StrandPalette.accent)
            Text("Coach is thinking…")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityLabel("Coach is thinking")
    }

    private func errorBanner(_ message: String) -> some View {
        StrandCard(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StrandPalette.statusCritical)
                    .accessibilityHidden(true)
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        Text(prompt)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
                            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    }
                    // Liquid tap response: the physical settle-inward every tappable liquid
                    // affordance gets, replacing the flat `.plain` press.
                    .buttonStyle(LiquidPressStyle())
                    .disabled(coach.sending)
                    .accessibilityLabel("Suggested prompt: \(prompt)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// The input bar, a frosted overlay surface holding the field + Send, so the composer reads as a
    /// distinct docked surface above the canvas rather than two floating controls.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Coach about your data…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(composerFocused ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))
                .onSubmit { send(draft) }
                .accessibilityLabel("Question")

            Button {
                toggleDictation(existingText: draft) { draft = $0 }
            } label: {
                Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(dictation.isRecording
                        ? StrandPalette.statusCritical
                        : StrandPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(coach.sending)
            .help(dictation.isRecording
                ? String(localized: "coach.dictation.stop")
                : String(localized: "coach.dictation.start"))
            .accessibilityLabel(dictation.isRecording
                ? Text("coach.dictation.stop")
                : Text("coach.dictation.question"))

            // Docked icon-only send affordance: a crisp accent-filled square sized to the
            // composer row (not the full 48pt control height), so it routes through the same
            // token fill/label colours as the button system without overpowering the field.
            Button {
                send(draft)
            } label: {
                Group {
                    if coach.sending {
                        ProgressView().controlSize(.small).tint(StrandPalette.goldDeepText)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 38)
                .foregroundStyle(StrandPalette.goldDeepText)
                .background(StrandPalette.accent,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(coach.sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(8)
        .background(StrandPalette.surfaceOverlay, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private var privacyFootnote: some View {
        Label {
            Text(coach.provider == .custom
                 ? String(localized: "Coach talks only to the server URL you set. Point it at a local model (Ollama, LM Studio, llama.cpp) to keep everything on your own machine. Nothing is sent until you ask.")
                 : String(localized: "When enabled, Coach sends a summary of your metrics to \(coach.provider.displayName) using your own key. Nothing is sent until you ask."))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    #if DEBUG
    @MainActor
    private func runTabShellKeyboardDemoIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        let keepsKeyboardVisible = arguments.contains("--demo-shell-keyboard-visible")
        let restoresNavigation = arguments.contains("--demo-shell-keyboard-restored")
        guard keepsKeyboardVisible || restoresNavigation else { return }

        try? await Task.sleep(nanoseconds: 900_000_000)
        guard !Task.isCancelled else { return }
        if coach.isConfigured {
            composerFocused = true
        } else {
            setupKeyFocused = true
        }
        VisualQALog.emit(
            "Tab shell keyboard QA focused mode=" +
                (keepsKeyboardVisible ? "visible" : "restored")
        )

        guard restoresNavigation else { return }
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        guard !Task.isCancelled else { return }
        composerFocused = false
        setupKeyFocused = false
        VisualQALog.emit("Tab shell keyboard QA dismissed mode=restored")
    }
    #endif

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        keyDraft = ""
    }

    /// Commit the Custom (local) provider: save an optional key, then connect on the entered URL.
    private func connectCustom() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            coach.setKey(trimmed)
            keyDraft = ""
        }
        coach.connectCustom()
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coach.sending else { return }
        draft = ""
        composerFocused = false
        Task { await coach.send(trimmed) }
    }

    private var checkInTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: checkInMinutes / 60,
                    minute: checkInMinutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                checkInMinutes = (components.hour ?? 18) * 60 + (components.minute ?? 0)
                guard checkInEnabled else { return }
                Task {
                    let scheduled = await CoachCheckInNotifications.setEnabled(
                        true,
                        minutes: checkInMinutes
                    )
                    if !scheduled {
                        checkInEnabled = false
                        checkInError = String(localized: "coach.check_in.error")
                    }
                }
            }
        )
    }

    private func setCheckInEnabled(_ enabled: Bool) {
        checkInError = nil
        Task {
            let applied = await CoachCheckInNotifications.setEnabled(
                enabled,
                minutes: checkInMinutes
            )
            checkInEnabled = enabled && applied
            if enabled && !applied {
                checkInError = String(localized: "coach.check_in.error")
            }
        }
    }

    private func toggleDictation(
        existingText: String,
        onText: @escaping @MainActor (String) -> Void
    ) {
        if dictation.isRecording {
            dictation.stop()
        } else {
            Task {
                await dictation.start(existingText: existingText, onText: onText)
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(StrandMotion.fade) {
            if coach.sending {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = coach.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

@MainActor
private final class CoachDictationController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var errorText: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var prefix = ""
    private var onText: (@MainActor (String) -> Void)?

    func start(
        existingText: String,
        onText: @escaping @MainActor (String) -> Void
    ) async {
        stop()
        errorText = nil

        guard await speechAccessAllowed() else {
            errorText = "Speech recognition permission is required for dictation."
            return
        }
        guard await microphoneAccessAllowed() else {
            errorText = "Microphone permission is required for dictation."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable
        else {
            errorText = "Dictation is unavailable on this device right now."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        prefix = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onText = onText

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorText = "No microphone input is available."
            recognitionRequest = nil
            return
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            stop()
            errorText = "Couldn't start dictation. Check microphone access and try again."
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let combined: String
                    if self.prefix.isEmpty {
                        combined = spoken
                    } else if spoken.isEmpty {
                        combined = self.prefix
                    } else {
                        combined = self.prefix + " " + spoken
                    }
                    self.onText?(combined)
                    if result.isFinal { self.stop() }
                } else if error != nil {
                    self.stop()
                    self.errorText = "Dictation ended before any speech was recognized."
                }
            }
        }
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        onText = nil
        prefix = ""
        isRecording = false
    }

    private func speechAccessAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization {
                    continuation.resume(returning: $0 == .authorized)
                }
            }
        default:
            return false
        }
    }

    private func microphoneAccessAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) {
                    continuation.resume(returning: $0)
                }
            }
        default:
            return false
        }
    }
}
