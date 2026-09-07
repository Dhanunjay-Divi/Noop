import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import WhoopStore
#if os(iOS)
import UIKit
#endif

// MARK: - OnboardingWizard
//
// A full-screen, paged onboarding + pairing flow for NOOP. Cinematic and calm:
// a dark surfaceBase substrate with a slow ambient glow, a bottom progress "thread"
// that fills as you advance, Back always available, and a forward CTA per step.
//
// Steps:
//  1 Welcome           - NOOP + local-first health-data boundary
//  2 What it does      - 3 calm value slides
//  3 Expectations      - what scores need and what NOOP does not claim
//  4 Bluetooth priming - explain BEFORE the OS prompt
//  5 Wear & wake       - put your strap on, make sure it is charged
//  6 Scan              - radar sweep; auto-scans, Scan retries via model.scan()
//  7 Bonding           - celebration when live.bonded
//  8 Ownership         - first-party builds only; claim must finish before profile
//  9 Profile           - age / sex / weight / height bound to ProfileStore
// 10 Import (optional) - wearable / Apple Health history
// 11 Notifications     - explicit, default-off daily guidance choice
// 12 Safety contacts   - optional contact setup
// 13 Appearance        - app finish
// 14 Daily rhythm      - where everyday reviews, logs, and automations live
// 15 Plan              - choose NOOP or save a NOOP+ preference without payment
// 16 Done              - "Your thread starts here." -> onFinished()
//
// Presentation is wired centrally; this view only calls onFinished() when complete.

public struct OnboardingWizard: View {

    /// Called when the user finishes (or skips to the end of) onboarding.
    public var onFinished: () -> Void

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        var initialStep = Step.welcome
        if let stored = UserDefaults.standard.string(
            forKey: Self.progressStorageKey
        ),
           let restored = Step.allCases.first(where: {
               $0.storageValue == stored
           }) {
            initialStep = restored
        }
        #if DEBUG
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--demo-onboarding-page"),
           args.indices.contains(index + 1),
           let requestedStep = Step.allCases.first(where: {
               $0.storageValue == args[index + 1]
           }) {
            initialStep = requestedStep
        } else if let index = args.firstIndex(of: "--demo-onboarding-step"),
           args.indices.contains(index + 1),
           let rawValue = Int(args[index + 1]),
           let requestedStep = Step(rawValue: rawValue) {
            initialStep = requestedStep
        }
        #endif
        _step = State(initialValue: initialStep)
    }

    // NOTE: the root deliberately does NOT observe the fast-updating model/live/profile
    // env objects — doing so re-rendered the whole animated wizard on every HR tick and
    // caused flicker. Child steps observe what they need; a hidden BondWatcher (below)
    // handles the bond→celebration transition without re-rendering the root.

    private enum Step: Int, CaseIterable {
        case welcome, what, expectations, bluetooth, wear, scan, bonded,
             ownership, profile, importData, notifications, safetyContacts,
             appearance, dailyRhythm, plan, done

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .done }

        var storageValue: String {
            switch self {
            case .welcome: return "welcome"
            case .what: return "what"
            case .expectations: return "expectations"
            case .bluetooth: return "bluetooth"
            case .wear: return "wear"
            case .scan: return "scan"
            case .bonded: return "bonded"
            case .ownership: return "ownership"
            case .profile: return "profile"
            case .importData: return "import"
            case .notifications: return "notifications"
            case .safetyContacts: return "safety_contacts"
            case .appearance: return "appearance"
            case .dailyRhythm: return "daily_rhythm"
            case .plan: return "plan"
            case .done: return "done"
            }
        }
    }

    private static let progressStorageKey = "noop.onboarding.progress.v1"
    @State private var step: Step = .welcome
    @State private var glow = false
    @State private var profileEditing = false
    @State private var bandBonded = false
    /// Notification permission is never bundled into a generic Continue tap. This explicit, default-off
    /// choice is explained on the Notifications step and only then passed to the scheduler.
    @State private var dailyReviewOptIn = DailyReviewNotifications.isEnabled
    @State private var selectedPlan = NoopProductPlan.stored()
    @State private var planSubmissionAttempted = false
    #if os(iOS)
    @StateObject private var ownershipService = OwnershipService.shared
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                // Top chrome: a small back affordance + a step counter.
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                // The paged content.
                ZStack {
                    switch step {
                    case .welcome:    WelcomeStep()
                    case .what:       WhatItDoesStep()
                    case .expectations: ExpectationsStep()
                    case .bluetooth:  BluetoothStep()
                    case .wear:       WearStep()
                    case .scan:       ScanStep(advance: advance)
                    case .bonded:     BondedStep()
                    case .ownership:
                        #if os(iOS)
                        OwnershipAccountView()
                        #else
                        EmptyView()
                        #endif
                    case .profile:    ProfileStep(isEditing: $profileEditing)
                    case .importData: ImportStep()
                    case .notifications: NotificationsStep(dailyReviewOptIn: $dailyReviewOptIn)
                    case .safetyContacts: SafetyContactsStep()
                    case .appearance: AppearanceStep()
                    case .dailyRhythm: DailyRhythmStep()
                    case .plan:
                        ProductPlanStep(
                            selection: $selectedPlan,
                            status: planSubmissionStatus,
                            isBusy: planSubmissionBusy
                        )
                    case .done:       DoneStep()
                    }
                }
                .frame(maxWidth: 620, maxHeight: .infinity)
                .clipped()
                .transition(stepTransition)
                .id(step)                       // re-runs the transition per step
                .padding(.horizontal, 20)

                // This must be a real sibling of the paged viewport. A root safe-area inset adjusts the
                // ScrollView's endpoint, but iOS still renders partially visible controls under the inset;
                // on an SE at accessibility sizes the Scan help row sat behind progress and Continue.
                if step != .profile || !profileEditing {
                    bottomBar
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .background(
                            StrandPalette.surfaceBase
                                .ignoresSafeArea()
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("noop.onboarding.footer")
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // Reduce Motion: leave the ambient bloom at its resting frame (no breathing).
        .onAppear {
            normalizeCurrentStep()
            if !reduceMotion { glow = true }
        }
        // Isolated live observation — a hidden watcher slides Scan → celebration on bond
        // without subscribing the whole wizard to per-tick updates.
        .background(BondWatcher(onBondState: handleBondState))
        #if os(iOS)
        .onChange(of: ownershipService.phase) { _, _ in
            reconcileOwnershipRequirement()
        }
        #endif
    }

    private func handleBondState(_ bonded: Bool) {
        bandBonded = bonded
        if bonded && step == .scan {
            move(to: .bonded, direction: "automatic")
        }
    }

    // MARK: Backgrounds

    private var background: some View {
        ZStack {
            StrandPalette.surfaceBase
            // A slow ambient bloom that breathes — the substrate feels alive. Kept subtle
            // (≈⅓ the old gold opacity) so it's a minimal gold hint, not a wash.
            RadialGradient(
                colors: [StrandPalette.glowAmbient.opacity(0.18), .clear],
                center: .center,
                startRadius: 40,
                endRadius: glow ? 620 : 480
            )
            .blendMode(.plusLighter)
            .opacity(glow ? 0.4 : 0.28)
            .animation(StrandMotion.breathe(reduced: reduceMotion), value: glow)
            .ignoresSafeArea()

            // A faint indigo wash from the top — instrument-grade depth.
            LinearGradient(
                colors: [StrandPalette.accentMuted.opacity(0.20), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if step.isFirst {
                Color.clear.frame(width: 64, height: 28)
            } else {
                Button(action: back) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(planSubmissionBusy)
                .accessibilityLabel("Back")
            }

            Spacer()

            Text("\(currentStepIndex + 1) / \(activeSteps.count)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Bottom bar (the thread + CTA)

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 16) {
            ThreadProgress(progress: progress)
                .frame(height: 8)
                .frame(maxWidth: 620)

            HStack(spacing: 14) {
                PrimaryButton(
                    title: ctaTitle,
                    systemImage: ctaIcon,
                    enabled: primaryActionEnabled,
                    action: primaryAction
                )
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("noop.onboarding.primary")
            }
            .frame(maxWidth: 620)
        }
    }

    private var progress: Double {
        guard activeSteps.count > 1 else { return 1 }
        return Double(currentStepIndex) / Double(activeSteps.count - 1)
    }

    private var ctaTitle: String {
        if step == .plan && planSubmissionBusy {
            return String(localized: "Saving…")
        }
        switch step {
        case .welcome:    return String(localized: "Get Started")
        case .what:       return String(localized: "Continue")
        case .expectations: return String(localized: "I understand")
        case .bluetooth:  return String(localized: "Continue")
        case .wear:       return String(localized: "I'm wearing it")
        case .scan:       return String(localized: "Continue")
        case .bonded:     return String(localized: "Continue")
        case .ownership:
            return ownershipClaimed
                ? String(localized: "Continue")
                : String(localized: "Claim band to continue")
        case .profile:    return String(localized: "Save & Continue")
        case .importData: return String(localized: "Continue")
        case .notifications:
            return dailyReviewOptIn
                ? String(localized: "Enable & Continue")
                : String(localized: "Not now")
        case .safetyContacts: return String(localized: "Finish later")
        case .appearance: return String(localized: "Continue")
        case .dailyRhythm: return String(localized: "Continue")
        case .plan:
            return selectedPlan == .noop
                ? String(localized: "Continue with NOOP")
                : String(localized: "Save NOOP+ preference")
        case .done:       return String(localized: "Enter NOOP")
        }
    }

    private var primaryActionEnabled: Bool {
        if step == .ownership { return ownershipClaimed }
        if step == .scan && ownershipRequired { return bandBonded }
        if step == .plan {
            return !planSubmissionBusy && postClaimOwnershipReady
        }
        return ownershipAllows(step)
    }

    private var ctaIcon: String? {
        switch step {
        case .done:    return "arrow.right"
        case .bonded:  return "checkmark"
        default:       return nil
        }
    }

    private func primaryAction() {
        guard primaryActionEnabled else { return }
        if step.isLast {
            finishOnboarding()
        } else {
            advance()
        }
    }

    // MARK: Navigation

    /// The Notifications page contains a clear, default-off opt-in. Continue never asks permission on
    /// its own: only "Enable & Continue" calls the scheduler, which requests the OS permission if needed.
    /// Denial does not block onboarding and the same control remains available under Automations.
    private func advance() {
        if step == .plan {
            planSubmissionAttempted = true
            #if os(iOS)
            guard postClaimOwnershipReady else {
                reconcileOwnershipRequirement()
                return
            }
            Task { @MainActor in
                guard await ownershipService.selectPlan(selectedPlan) else {
                    return
                }
                guard step == .plan else { return }
                guard postClaimOwnershipReady else {
                    reconcileOwnershipRequirement()
                    return
                }
                advanceStep()
            }
            #else
            selectedPlan.persist()
            AppDiagnosticsRecorder.shared.record(
                "ownership.plan_local",
                fields: ["selection": selectedPlan.rawValue]
            )
            advanceStep()
            #endif
            return
        }
        if step == .profile {
            // The editor is seeded with neutral defaults for layout, but age-shaped estimates must not
            // treat those as user-provided. Tapping the explicitly labelled Save & Continue accepts both
            // visible profile inputs, including when the user intentionally keeps the shown defaults.
            ProfileStore.confirmFitnessInputsInDefaults()
        }
        guard step != .notifications else {
            guard dailyReviewOptIn else {
                DailyReviewNotifications.setEnabled(false)
                advanceStep()
                return
            }
            DailyReviewNotifications.setEnabled(true) { outcome in
                dailyReviewOptIn = outcome == .scheduled
                advanceStep()
            }
            return
        }
        advanceStep()
    }

    private func advanceStep() {
        let index = currentStepIndex
        guard activeSteps.indices.contains(index + 1) else {
            finishOnboarding()
            return
        }
        move(to: activeSteps[index + 1], direction: "forward")
    }

    private func finishOnboarding() {
        guard ownershipAllows(.done) else {
            reconcileOwnershipRequirement()
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.progressStorageKey)
        AppDiagnosticsRecorder.shared.record(
            "onboarding.progress",
            fields: [
                "step": "complete",
                "direction": "finished",
            ]
        )
        onFinished()
    }

    private func back() {
        let index = currentStepIndex
        guard activeSteps.indices.contains(index - 1) else { return }
        move(to: activeSteps[index - 1], direction: "back")
    }

    private var activeSteps: [Step] {
        Step.allCases.filter { $0 != .ownership || ownershipRequired }
    }

    private var currentStepIndex: Int {
        activeSteps.firstIndex(of: step) ?? 0
    }

    private var ownershipRequired: Bool {
        #if os(iOS)
        return ownershipService.isAvailable
        #else
        return false
        #endif
    }

    private var ownershipClaimed: Bool {
        #if os(iOS)
        return ownershipService.phase == .claimed
            || ownershipService.phase == .complete
        #else
        return true
        #endif
    }

    private var planSubmissionBusy: Bool {
        #if os(iOS)
        return planSubmissionAttempted && ownershipService.isBusy
        #else
        return false
        #endif
    }

    private var postClaimOwnershipReady: Bool {
        #if os(iOS)
        return ownershipCanAccessPostClaimOnboarding(
            isAvailable: ownershipService.isAvailable,
            phase: ownershipService.phase
        )
        #else
        return true
        #endif
    }

    private var planSubmissionStatus: String {
        #if os(iOS)
        guard planSubmissionAttempted, !ownershipService.isBusy else {
            return ""
        }
        return ownershipService.status
        #else
        return ""
        #endif
    }

    private func normalizeCurrentStep() {
        if !ownershipAllows(step) {
            reconcileOwnershipRequirement()
            return
        }
        guard !activeSteps.contains(step) else { return }
        move(to: .profile, direction: "reconciled")
    }

    private func ownershipAllows(_ candidate: Step) -> Bool {
        guard candidate.rawValue > Step.ownership.rawValue else {
            return true
        }
        return postClaimOwnershipReady
    }

    private func reconcileOwnershipRequirement() {
        #if os(iOS)
        guard !ownershipAllows(step),
              ownershipService.isAvailable else {
            return
        }
        guard let ownershipIndex = activeSteps.firstIndex(of: .ownership) else {
            return
        }
        move(to: activeSteps[ownershipIndex], direction: "reconciled")
        #endif
    }

    private func move(to next: Step, direction: String) {
        let destination: Step
        let effectiveDirection: String
        if ownershipAllows(next) {
            destination = next
            effectiveDirection = direction
        } else {
            destination = .ownership
            effectiveDirection = "reconciled"
        }
        UserDefaults.standard.set(
            destination.storageValue,
            forKey: Self.progressStorageKey
        )
        AppDiagnosticsRecorder.shared.record(
            "onboarding.progress",
            fields: [
                "step": destination.storageValue,
                "direction": effectiveDirection,
            ]
        )
        withAnimation(
            effectiveDirection == "automatic"
                ? StrandMotion.hero
                : StrandMotion.gentle
        ) {
            step = destination
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

private struct ProductPlanStep: View {
    @Binding var selection: NoopProductPlan
    let status: String
    let isBusy: Bool

    var body: some View {
        StepShell {
            VStack(spacing: 18) {
                Spacer(minLength: 12)
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityHidden(true)
                Text("Choose your NOOP")
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                Text(
                    "Core metrics, workouts, Journal, Coach, automations, local backup and exports stay available with NOOP. This choice never changes band ownership."
                )
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)

                VStack(spacing: 12) {
                    planButton(
                        .noop,
                        symbol: "iphone",
                        title: "NOOP",
                        subtitle: "Local-first",
                        detail: "Continue immediately. No payment or subscription is required."
                    )
                    planButton(
                        .noopPlus,
                        symbol: "sparkles",
                        title: "NOOP+",
                        subtitle: "Optional continuity",
                        detail: "Save your interest in managed storage and multi-device restore. Payment and entitlement are not available yet."
                    )
                }
                .frame(maxWidth: 500)

                Text(
                    "Selecting NOOP+ does not upload data, open checkout or unlock an entitlement."
                )
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                if isBusy {
                    ProgressView(String(localized: "Saving…"))
                        .tint(StrandPalette.accent)
                } else if !status.isEmpty {
                    Text(status)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "noop.onboarding.plan.status"
                        )
                }
                Spacer(minLength: 8)
            }
        }
    }

    private func planButton(
        _ plan: NoopProductPlan,
        symbol: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        let selected = selection == plan
        let tint = plan == .noopPlus
            ? StrandPalette.metricAmber
            : StrandPalette.textPrimary
        return Button {
            selection = plan
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(
                        tint.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(StrandFont.headline)
                            .foregroundStyle(
                                plan == .noopPlus
                                    ? StrandPalette.metricAmber
                                    : StrandPalette.textPrimary
                            )
                        Text(subtitle)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Text(detail)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? tint : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                StrandPalette.surfaceRaised,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        selected ? tint : StrandPalette.hairline,
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(
            Text(title) + Text(", ") + Text(subtitle) + Text(". ") + Text(detail)
        )
        .accessibilityValue(selected ? Text("Selected") : Text("Not selected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Hidden, isolated observer — re-renders on live updates (it's just Color.clear, so no
/// visible cost) and fires `onBonded` when the strap bonds, keeping the main wizard body
/// out of the per-tick re-render path that caused flicker.
private struct BondWatcher: View {
    @EnvironmentObject private var live: LiveState
    let onBondState: (Bool) -> Void
    var body: some View {
        Color.clear
            .onAppear { onBondState(live.bonded) }
            .onChangeCompat(of: live.bonded) { onBondState($0) }
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStep: View {
    @State private var appear = false
    var body: some View {
        StepShell {
            VStack(spacing: 24) {
                Spacer()
                // The hero mark — the Engraved titanium BrandMark (open gold ring +
                // core dot on a brushed-titanium tile). Clean and flat; it draws in
                // with a calm scale + fade, no glow.
                BrandMark(size: 120)
                    .scaleEffect(appear ? 1 : 0.92)
                    .opacity(appear ? 1 : 0)
                Text("your health data, local by default")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .opacity(appear ? 1 : 0)
                Text("A private window into your recovery, sleep and effort. Core data is read from NOOP Band and processed on \(Platform.deviceNounPhrase); cloud features are optional.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .opacity(appear ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(StrandMotion.hero) { appear = true } }
    }
}

// MARK: - Step 2 · What it does

private struct WhatItDoesStep: View {
    private struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        .init(icon: "circle.dashed.inset.filled",
              tint: StrandPalette.accent,
              title: String(localized: "See recovery, beautifully"),
              body: String(localized: "A signature ring distils HRV, resting heart rate and sleep into one calm read on whether to push or rest.")),
        .init(icon: "waveform.path.ecg",
              tint: StrandPalette.accent,
              title: String(localized: "Watch your heart, live"),
              body: String(localized: "Connect Noop Band, a heart-rate strap, or a gym machine and watch each beat in real time: heart rate, variability, and zones as they happen. Already have history elsewhere? Import a wearable export, or use Apple Health, Oura, Fitbit, or Garmin.")),
        .init(icon: "lock.shield",
              tint: StrandPalette.statusPositive,
              title: String(localized: "Private by default"),
              body: String(localized: "Everything starts on \(Platform.deviceNounPhrase). No account or cloud is required. Data leaves only when you explicitly share it, use Coach, or enable your own self-hosted sync.")),
    ]

    var body: some View {
        StepShell(title: String(localized: "What NOOP does"), subtitle: String(localized: "Three quiet promises.")) {
            VStack(spacing: 14) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    SlideRow(slide: slide, index: index)
                }
            }
        }
    }

    private struct SlideRow: View {
        let slide: Slide
        let index: Int
        @State private var shown = false
        var body: some View {
            StrandCard {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(slide.tint.opacity(0.14))
                            .frame(width: 46, height: 46)
                        Image(systemName: slide.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(slide.tint)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slide.title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(slide.body)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(StrandMotion.gentle.delay(Double(index) * 0.10)) { shown = true }
            }
        }
    }
}

// MARK: - Step 2.5 · What to expect (independent / experimental / 5-MG framing)

private struct ExpectationsStep: View {
    @State private var shown = false
    var body: some View {
        StepShell(title: String(localized: "What to expect"),
                  subtitle: String(localized: "A few honest words, so nothing's a surprise.")) {
            VStack(spacing: 12) {
                ForEach(Array(AppChangelog.expectations.enumerated()), id: \.element.id) { index, e in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: e.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 26)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(CustomerFacingBrand.text(e.title)).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(CustomerFacingBrand.text(e.body)).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrandPalette.hairline))
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
                    .animation(StrandMotion.gentle.delay(Double(index) * 0.08), value: shown)
                }

                #if os(iOS)
                if IOSDiagnostics.capture().isSideloaded == true {
                    // Free-development / AltStore builds still need periodic re-signing.
                    expectationRow(
                        icon: "iphone.gen3",
                        title: String(localized: "Installed outside the App Store"),
                        body: String(localized: "On iPhone this is a sideloaded build. Re-sign it about every 7 days on a free Apple ID (longer on a paid account). After your phone reboots, unlock it once so NOOP can read and sync its data.")
                    )
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
                    .animation(StrandMotion.gentle.delay(Double(AppChangelog.expectations.count) * 0.08), value: shown)
                }
                #endif
            }
        }
        .onAppear { shown = true }
    }

    /// One expectation callout, matching the data-driven rows above so the iOS-only addition is visually
    /// identical to the rest of the list.
    private func expectationRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(body).font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrandPalette.hairline))
    }
}

// MARK: - Step 3 · Bluetooth priming

private struct BluetoothStep: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        StepShell(title: String(localized: "A quick word before we connect"),
                  subtitle: String(localized: "\(Platform.deviceNoun) will ask for Bluetooth in a moment.")) {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(StrandPalette.accent.opacity(0.25), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.25 : 0.9)
                        .opacity(pulse ? 0 : 0.8)
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.5))
                        .frame(width: 86, height: 86)
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .frame(height: 130)

                InfoCard(
                    icon: "lock.fill",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "Direct, local Bluetooth"),
                    message: String(localized: "NOOP talks straight to Noop Band over Bluetooth Low Energy, with no project server in the middle. Readings stay on this device unless you later enable an optional destination such as your own self-hosted server.")
                )

                Text("When the system prompt appears, choose Allow so NOOP can find Noop Band.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .onAppear { if !reduceMotion { withAnimation(StrandMotion.breathe) { pulse = true } } }
    }
}

// MARK: - Step 4 · Wear & wake

private struct WearStep: View {
    var body: some View {
        StepShell(title: String(localized: "Put Noop Band on"),
                  subtitle: String(localized: "And make sure it's charged.")) {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(StrandPalette.accent.opacity(0.16))
                        .frame(width: 130, height: 130)
                        .blur(radius: 24)
                    Image(systemName: "applewatch.side.right")
                        .font(.system(size: 58, weight: .regular))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(height: 140)

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Wear it snug on your wrist or bicep, sensor against skin."))
                    Checkline(text: String(localized: "Give it a few minutes of charge if the battery is low."))
                    Checkline(text: String(localized: "Keep it within about a metre of \(Platform.deviceNounPhrase)."))
                }
                .frame(maxWidth: 440)
            }
        }
    }
}

// MARK: - Step 5 · Scan (radar sweep + reassurance)

private struct ScanStep: View {
    let advance: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    @State private var scanning = false
    @State private var showHelp = false

    var body: some View {
        StepShell(title: String(localized: "Find Noop Band"),
                  subtitle: live.bonded
                      ? String(localized: "Bonded. You're set.")
                      : String(localized: "Keep your Noop Band nearby, then tap Scan. Hardware detection is automatic.")) {
            VStack(spacing: 24) {
                RadarSweep(active: scanning && !live.bonded, bonded: live.bonded)
                    .frame(width: 220, height: 220)

                statusLine

                if !live.bonded {
                    VStack(spacing: 6) {
                        Label("Noop Band", systemImage: "applewatch.side.right")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("NOOP detects compatible band hardware automatically.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Noop Band. Hardware detection is automatic.")
                    .accessibilityIdentifier("noop.onboarding.band")

                    Button(action: { startScan() }) {
                        Label(scanning ? "Scanning…" : "Scan", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(scanning)
                    .accessibilityIdentifier("noop.onboarding.scan")

                    DisclosureToggle(open: $showHelp, label: String(localized: "Don't see it?"))

                    if showHelp { reassurance }

                    Text("No Noop Band? You can still continue. Add another heart-rate strap, watch, ring, or gym machine under Devices, or connect an import under Data Sources at any time.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                        .accessibilityIdentifier("noop.onboarding.scan-footnote")
                }
            }
        }
        .onDisappear { scanning = false }
    }

    private var statusLine: some View {
        Group {
            if live.bonded {
                StatePill("Connected", tone: .positive)
            } else if live.connected {
                StatePill("Connecting…", tone: .warning, pulsing: true)
            } else if scanning {
                StatePill("Searching", tone: .accent, pulsing: true)
            } else {
                StatePill("Ready to scan", tone: .neutral, showsDot: false)
            }
        }
    }

    private func startScan() {
        scanning = true
        showHelp = false
        // The transport starts with the last observed family and automatically rotates after a short
        // miss, so setup does not ask users for protocol-generation knowledge.
        model.scan()
        // Surface the reassurance card if we haven't bonded after a calm beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if !live.bonded {
                scanning = false
                withAnimation(StrandMotion.gentle) { showHelp = true }
            }
        }
    }

    // The calm, never-alarmist "can't find it" card.
    private var reassurance: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                    Text("Don't see it? That's normal.")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                Text("A Noop Band may not appear in your \(Platform.deviceNoun)'s Bluetooth settings. NOOP finds its private band signal directly, so start pairing here.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                VStack(alignment: .leading, spacing: 10) {
                    Checkline(text: String(localized: "It's charged and worn. The sensor needs skin contact to wake."))
                    Checkline(text: String(localized: "It isn't held by another band app. Close that app first because the band supports one active host."))
                    Checkline(text: String(localized: "It's within about a metre of \(Platform.deviceNounPhrase)."))
                }

                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: 480)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func retry() {
        withAnimation(StrandMotion.gentle) { showHelp = false }
        startScan()
    }
}

// MARK: - Step 6 · Bonding celebration

private struct BondedStep: View {
    @EnvironmentObject private var live: LiveState
    @State private var bloom = false
    var body: some View {
        StepShell {
            VStack(spacing: 26) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(StrandPalette.statusPositive)
                        .frame(width: 160, height: 160)
                        .blur(radius: 70)
                        .opacity(bloom ? 0.5 : 0.0)
                        .blendMode(.plusLighter)
                    // A ring materialises — a taste of the signature component.
                    RecoveryRing(score: 100, supporting: nil, diameter: 200, lineWidth: 14, showsLabel: false)
                        .scaleEffect(bloom ? 1 : 0.7)
                        .opacity(bloom ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(StrandPalette.statusPositive)
                        .scaleEffect(bloom ? 1 : 0.4)
                        .opacity(bloom ? 1 : 0)
                }
                .frame(height: 210)

                VStack(spacing: 8) {
                    Text("You're connected.")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(batteryLine)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .opacity(bloom ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(StrandMotion.hero) { bloom = true } }
    }

    private var batteryLine: String {
        if let pct = live.batteryPct {
            return String(localized: "Noop Band is paired · \(Int(pct))% battery.")
        }
        return String(localized: "Noop Band is paired and ready to stream.")
    }
}

// MARK: - Step 7 · Profile

private struct ProfileStep: View {
    @EnvironmentObject private var profile: ProfileStore
    @Binding var isEditing: Bool

    // Distance keeps the app-wide system preference, but weight and height can override it independently:
    // kg + ft/in and lb + cm are both common real-world combinations. Storage remains SI throughout.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.massKey) private var massUnitRaw = ""
    @AppStorage(UnitPrefs.heightKey) private var heightUnitRaw = ""
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var massUnit: MassUnit { UnitPrefs.resolveMass(system: unitSystem, override: massUnitRaw) }
    private var heightUnit: HeightUnit { UnitPrefs.resolveHeight(system: unitSystem, override: heightUnitRaw) }

    private enum InputField: Hashable { case weight, heightCm, heightFeet, heightInches }
    private enum ScrollAnchor: Hashable { case height }
    @FocusState private var focusedField: InputField?
    /// Text-backed drafts deliberately remain separate from the validated SI profile values. A formatter-
    /// bound Double field clamps an empty intermediate edit straight back to the minimum (the reported
    /// "30.0 cannot be replaced" loop). Drafts may be empty while typing and commit only when valid.
    @State private var weightDraft = ""
    @State private var heightCmDraft = ""
    @State private var heightFeetDraft = ""
    @State private var heightInchesDraft = ""
    @State private var clearTransitionField: InputField?

    private let sexes: [(String, String)] = [
        ("male", String(localized: "Male")), ("female", String(localized: "Female")),
        ("nonbinary", String(localized: "Other"))
    ]

    var body: some View {
        ScrollViewReader { scrollProxy in
            StepShell(title: String(localized: "About you"),
                      subtitle: String(localized: "So your zones, calories and baselines are accurate.")) {
                VStack(spacing: 16) {
                    StrandCard {
                        VStack(spacing: 18) {
                            // #146: capture a date of birth so age advances on its own instead of going stale.
                            DatePicker(selection: $profile.dateOfBirth,
                                       in: ProfileStore.dateOfBirthRange,
                                       displayedComponents: .date) {
                                FieldRow(label: String(localized: "Date of birth"),
                                         value: String(localized: "\(profile.age) yrs"))
                            }
                            .tint(StrandPalette.accent)

                            Divider().overlay(StrandPalette.hairline)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sex").strandOverline()
                                Picker("Sex", selection: $profile.sex) {
                                    ForEach(sexes, id: \.0) { key, label in
                                        Text(label).tag(key)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }

                            Divider().overlay(StrandPalette.hairline)

                            weightEditor

                            Divider().overlay(StrandPalette.hairline)

                            heightEditor
                                .id(ScrollAnchor.height)
                        }
                    }

                    Text("Weight and height units are independent. NOOP stores one precise value and only changes how it is displayed.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Image(systemName: "bolt.heart")
                            .foregroundStyle(StrandPalette.accent)
                        Text("Estimated max heart rate · \(profile.hrMax) bpm")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .onAppear { syncMeasurementDrafts() }
            .onChangeCompat(of: massUnitRaw) { _ in syncWeightDraft() }
            .onChangeCompat(of: heightUnitRaw) { _ in syncHeightDrafts() }
            .onChangeCompat(of: profile.weightKg) { _ in
                if focusedField != .weight { syncWeightDraft() }
            }
            .onChangeCompat(of: profile.heightCm) { _ in
                if focusedField != .heightCm && focusedField != .heightFeet
                    && focusedField != .heightInches {
                    syncHeightDrafts()
                }
            }
            .onChangeCompat(of: focusedField) { field in
                guard let field else {
                    if let clearedField = clearTransitionField {
                        DispatchQueue.main.async {
                            guard focusedField == nil,
                                  clearTransitionField == clearedField else { return }
                            focusedField = clearedField
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        guard focusedField == nil, clearTransitionField == nil else { return }
                        isEditing = false
                        normalizeMeasurementDrafts()
                    }
                    return
                }
                if let clearedField = clearTransitionField, field != clearedField {
                    clearTransitionField = nil
                }
                isEditing = true
                revealMeasurements(using: scrollProxy)
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard focusedField != nil else { return }
                withAnimation(StrandMotion.gentle) {
                    revealMeasurements(using: scrollProxy)
                }
            }
            #endif
            .onDisappear { isEditing = false }
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { finishEditing() }
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.accent)
                }
            }
            #endif
        }
    }

    private var massSelection: Binding<MassUnit> {
        Binding(get: { massUnit }, set: { massUnitRaw = $0.rawValue })
    }

    private var heightSelection: Binding<HeightUnit> {
        Binding(get: { heightUnit }, set: { heightUnitRaw = $0.rawValue })
    }

    private var displayedWeight: Binding<Double> {
        Binding(
            get: { massUnit == .pounds ? UnitFormatter.kgToPounds(profile.weightKg) : profile.weightKg },
            set: { entered in
                guard entered.isFinite else { return }
                let kilograms = massUnit == .pounds
                    ? entered / UnitFormatter.poundsPerKilogram
                    : entered
                profile.weightKg = min(250, max(30, kilograms))
            }
        )
    }

    private var displayedHeightCm: Binding<Double> {
        Binding(
            get: { profile.heightCm },
            set: { entered in
                guard entered.isFinite else { return }
                profile.heightCm = min(230, max(120, entered))
            }
        )
    }

    private var displayedHeightInches: Binding<Double> {
        Binding(
            get: { UnitFormatter.cmToInches(profile.heightCm) },
            set: { entered in
                guard entered.isFinite else { return }
                let inches = min(91, max(47, entered))
                profile.heightCm = inches * UnitFormatter.centimetersPerInch
            }
        )
    }

    private var stepperWeight: Binding<Double> {
        Binding(
            get: { displayedWeight.wrappedValue },
            set: {
                displayedWeight.wrappedValue = $0
                syncWeightDraft()
            }
        )
    }

    private var stepperHeightCm: Binding<Double> {
        Binding(
            get: { displayedHeightCm.wrappedValue },
            set: {
                displayedHeightCm.wrappedValue = $0
                syncHeightDrafts()
            }
        )
    }

    private var stepperHeightInches: Binding<Double> {
        Binding(
            get: { displayedHeightInches.wrappedValue },
            set: {
                displayedHeightInches.wrappedValue = $0
                syncHeightDrafts()
            }
        )
    }

    private var weightDraftBinding: Binding<String> {
        Binding(
            get: { weightDraft },
            set: { draft in
                weightDraft = draft
                if !draft.isEmpty, clearTransitionField == .weight {
                    clearTransitionField = nil
                }
                guard let entered = decimalValue(draft),
                      (massUnit == .pounds ? 66.0...551.0 : 30.0...250.0).contains(entered) else { return }
                displayedWeight.wrappedValue = entered
            }
        )
    }

    private var heightCmDraftBinding: Binding<String> {
        Binding(
            get: { heightCmDraft },
            set: { draft in
                heightCmDraft = draft
                if !draft.isEmpty, clearTransitionField == .heightCm {
                    clearTransitionField = nil
                }
                guard let entered = decimalValue(draft), (120.0...230.0).contains(entered) else { return }
                displayedHeightCm.wrappedValue = entered
            }
        )
    }

    private var heightFeetDraftBinding: Binding<String> {
        Binding(
            get: { heightFeetDraft },
            set: { draft in
                heightFeetDraft = draft
                updateHeightFromFeetDrafts()
            }
        )
    }

    private var heightInchesDraftBinding: Binding<String> {
        Binding(
            get: { heightInchesDraft },
            set: { draft in
                heightInchesDraft = draft
                updateHeightFromFeetDrafts()
            }
        )
    }

    private func decimalValue(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }

    private func syncMeasurementDrafts() {
        syncWeightDraft()
        syncHeightDrafts()
    }

    private func syncWeightDraft() {
        let shown = displayedWeight.wrappedValue
        weightDraft = massUnit == .kilograms
            ? String(format: "%.1f", shown)
            : String(format: "%.0f", shown)
    }

    private func syncHeightDrafts() {
        heightCmDraft = String(format: "%.0f", profile.heightCm)
        let parts = UnitFormatter.cmToFeetInches(profile.heightCm)
        heightFeetDraft = String(parts.feet)
        heightInchesDraft = String(parts.inches)
    }

    private func normalizeWeightDraft() {
        guard !weightDraft.isEmpty else {
            syncWeightDraft()
            return
        }
        guard let entered = decimalValue(weightDraft),
              (massUnit == .pounds ? 66.0...551.0 : 30.0...250.0).contains(entered) else {
            syncWeightDraft()
            return
        }
        displayedWeight.wrappedValue = entered
        syncWeightDraft()
    }

    private func normalizeHeightCmDraft() {
        guard !heightCmDraft.isEmpty else {
            syncHeightDrafts()
            return
        }
        guard let entered = decimalValue(heightCmDraft), (120.0...230.0).contains(entered) else {
            syncHeightDrafts()
            return
        }
        displayedHeightCm.wrappedValue = entered
        syncHeightDrafts()
    }

    private func updateHeightFromFeetDrafts() {
        guard let feet = Int(heightFeetDraft), let inches = Int(heightInchesDraft),
              (0...11).contains(inches) else { return }
        let total = feet * 12 + inches
        guard (47...91).contains(total) else { return }
        displayedHeightInches.wrappedValue = Double(total)
    }

    private func normalizeFeetInchesDrafts() {
        updateHeightFromFeetDrafts()
        syncHeightDrafts()
    }

    private func normalizeMeasurementDrafts() {
        normalizeWeightDraft()
        if heightUnit == .centimeters {
            normalizeHeightCmDraft()
        } else {
            normalizeFeetInchesDrafts()
        }
    }

    private func finishEditing() {
        clearTransitionField = nil
        normalizeMeasurementDrafts()
        focusedField = nil
        isEditing = false
    }

    private func focus(_ field: InputField) {
        isEditing = true
        focusedField = field
    }

    private func clearDraft(_ field: InputField) {
        isEditing = true
        clearTransitionField = field
        switch field {
        case .weight:
            weightDraft = ""
        case .heightCm:
            heightCmDraft = ""
        case .heightFeet:
            heightFeetDraft = ""
        case .heightInches:
            heightInchesDraft = ""
        }
        focusedField = nil
        DispatchQueue.main.async {
            guard clearTransitionField == field else { return }
            focusedField = field
        }
    }

    private func revealMeasurements(using proxy: ScrollViewProxy) {
        #if os(iOS)
        proxy.scrollTo(ScrollAnchor.height, anchor: .center)
        #endif
    }

    private var weightEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Weight").strandOverline()
                Spacer(minLength: 8)
                Picker("Weight unit", selection: massSelection) {
                    Text("kg").tag(MassUnit.kilograms)
                    Text("lb").tag(MassUnit.pounds)
                }
                .pickerStyle(.segmented)
                .frame(width: 116)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    TextField("Weight", text: weightDraftBinding)
                        .font(StrandFont.bodyNumber)
                        .multilineTextAlignment(.trailing)
                        .numericKeyboard()
                        .focused($focusedField, equals: .weight)
                        .simultaneousGesture(TapGesture().onEnded { focus(.weight) })
                        .accessibilityLabel("Weight value")
                        .accessibilityIdentifier("noop.profile.weight")
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .contentShape(Rectangle())
                        .onTapGesture { clearDraft(.weight) }
                        .accessibilityElement()
                        .accessibilityAddTraits(.isButton)
                    .opacity(weightDraft.isEmpty ? 0 : 1)
                    .allowsHitTesting(!weightDraft.isEmpty)
                    .accessibilityHidden(weightDraft.isEmpty)
                    .accessibilityLabel("Clear weight")
                    .accessibilityIdentifier("noop.profile.weight.clear")
                }
                .frame(width: 92)
                .measurementEntryChrome()
                Text(massUnit.rawValue)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(minWidth: 22, alignment: .leading)
                Stepper("Adjust weight", value: stepperWeight,
                        in: massUnit == .pounds ? 66...551 : 30...250,
                        step: massUnit == .pounds ? 1 : 0.5)
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder private var heightEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Height").strandOverline()
                Spacer(minLength: 8)
                Picker("Height unit", selection: heightSelection) {
                    Text("cm").tag(HeightUnit.centimeters)
                    Text("ft / in").tag(HeightUnit.feetInches)
                }
                .pickerStyle(.segmented)
                .frame(width: 136)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if heightUnit == .centimeters {
                    HStack(spacing: 4) {
                        TextField("Height", text: heightCmDraftBinding)
                            .font(StrandFont.bodyNumber)
                            .multilineTextAlignment(.trailing)
                            .numericKeyboard()
                            .focused($focusedField, equals: .heightCm)
                            .simultaneousGesture(TapGesture().onEnded { focus(.heightCm) })
                            .accessibilityLabel("Height value")
                            .accessibilityIdentifier("noop.profile.height.cm")
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .contentShape(Rectangle())
                            .onTapGesture { clearDraft(.heightCm) }
                            .accessibilityElement()
                            .accessibilityAddTraits(.isButton)
                        .opacity(heightCmDraft.isEmpty ? 0 : 1)
                        .allowsHitTesting(!heightCmDraft.isEmpty)
                        .accessibilityHidden(heightCmDraft.isEmpty)
                        .accessibilityLabel("Clear height")
                        .accessibilityIdentifier("noop.profile.height.clear")
                    }
                    .frame(width: 76)
                    .measurementEntryChrome()
                    Text("cm")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Stepper("Adjust height", value: stepperHeightCm, in: 120...230, step: 1)
                        .labelsHidden()
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            feetInchesFields
                            Stepper("Adjust height", value: stepperHeightInches, in: 47...91, step: 1)
                                .labelsHidden()
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        VStack(alignment: .trailing, spacing: 8) {
                            feetInchesFields
                            Stepper("Adjust height", value: stepperHeightInches, in: 47...91, step: 1)
                                .labelsHidden()
                        }
                    }
                }
            }
        }
    }

    private var feetInchesFields: some View {
        HStack(spacing: 8) {
            TextField("Feet", text: heightFeetDraftBinding)
                .font(StrandFont.bodyNumber)
                .multilineTextAlignment(.trailing)
                .numericKeyboard()
                .focused($focusedField, equals: .heightFeet)
                .simultaneousGesture(TapGesture().onEnded { focus(.heightFeet) })
                .accessibilityLabel("Height feet")
                .accessibilityIdentifier("noop.profile.height.feet")
                .frame(width: 46)
                .measurementEntryChrome()
            Text("ft")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            TextField("Inches", text: heightInchesDraftBinding)
                .font(StrandFont.bodyNumber)
                .multilineTextAlignment(.trailing)
                .numericKeyboard()
                .focused($focusedField, equals: .heightInches)
                .simultaneousGesture(TapGesture().onEnded { focus(.heightInches) })
                .accessibilityLabel("Height inches")
                .accessibilityIdentifier("noop.profile.height.inches")
                .frame(width: 46)
                .measurementEntryChrome()
            Text("in")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

private extension View {
    /// Shared compact field chrome for the independently editable onboarding measurements.
    func measurementEntryChrome() -> some View {
        self
            .padding(.horizontal, 9)
            .frame(height: 40)
            .background(StrandPalette.surfaceOverlay,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }
}

// MARK: - Step 8 · Import (optional)

private struct ImportStep: View {
    @EnvironmentObject private var model: AppModel
    #if os(iOS)
    @EnvironmentObject private var health: HealthKitBridge
    #endif
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop

    var body: some View {
        StepShell(title: String(localized: "Bring your history"),
                  subtitle: String(localized: "Optional: import now, or continue and return to Data Sources later.")) {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.45))
                        .frame(width: 96, height: 96)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(StrandPalette.accent)
                }

                InfoCard(
                    icon: "clock.arrow.circlepath",
                    tint: StrandPalette.accent,
                    title: String(localized: "History fills the dashboard immediately"),
                    message: String(localized: "A wearable export backfills recovery, strain, sleep and workouts. Apple Health can add HR, HRV, sleep, SpO₂, steps, workouts, weight, and body or sleeping-wrist temperature when a source records them.")
                )

                StrandCard {
                    VStack(spacing: 10) {
                        #if os(iOS)
                        // The normal iPhone path is a live, permissioned HealthKit connection. File
                        // import remains immediately below as the explicit historical/fallback path.
                        ImportActionButton(
                            title: appleHealthConnectionTitle,
                            systemImage: health.auth == .authorized
                                ? "checkmark.circle.fill" : "heart.text.square.fill",
                            disabled: health.syncing || health.auth == .unavailable
                                || health.auth == .entitlementMissing
                        ) {
                            Task {
                                if health.auth != .authorized {
                                    await health.requestAuthorization()
                                }
                                if health.auth == .authorized {
                                    await health.sync()
                                    await model.repo.refresh()
                                }
                            }
                        }
                        if let note = appleHealthConnectionNote {
                            Text(note)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                        #endif

                        ImportActionButton(
                            title: model.isImporting(.whoop) ? String(localized: "Importing…") : String(localized: "Import wearable export"),
                            systemImage: "tray.and.arrow.down",
                            disabled: model.hasActiveImport
                        ) {
                            presentImporter(.whoop)
                        }
                        ImportActionButton(
                            title: model.isImporting(.appleHealth) ? String(localized: "Working…") : String(localized: "Import Apple Health export"),
                            systemImage: "heart.fill",
                            disabled: model.hasActiveImport
                        ) {
                            presentImporter(.appleHealth)
                        }
                    }
                }
                .frame(maxWidth: 480)

                if model.hasActiveImport {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StrandPalette.accent)
                }

                // Show the summary for the source the user last imported, styled off the typed
                // failure flag (not a substring match) so real errors read as warnings.
                if let summary = lastSummary {
                    Text(summary)
                        .font(StrandFont.subhead)
                        .foregroundStyle(model.importFailed(importKind) ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importTarget.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result, for: importTarget)
        }
    }

    #if os(iOS)
    private var appleHealthConnectionTitle: String {
        if health.syncing { return String(localized: "Syncing Apple Health…") }
        switch health.auth {
        case .authorized: return String(localized: "Apple Health connected")
        case .denied: return String(localized: "Review Apple Health access")
        case .unavailable: return String(localized: "Apple Health unavailable")
        case .entitlementMissing: return String(localized: "Apple Health unavailable in this build")
        case .unknown: return String(localized: "Connect Apple Health")
        }
    }

    private var appleHealthConnectionNote: String? {
        switch health.auth {
        case .authorized:
            return String(localized: "Automatic sync is on. New data is read when Health notifies NOOP and whenever you reopen the app.")
        case .denied:
            return String(localized: "If the permission sheet does not return, enable NOOP in Settings › Health › Data Access & Devices.")
        case .entitlementMissing:
            return String(localized: "This signed build cannot request Health access; use the Apple Health export below.")
        case .unavailable:
            return String(localized: "Apple Health is not available on this device.")
        case .unknown:
            return String(localized: "Connect once to import compatible watch, scale and health-app data automatically with your permission.")
        }
    }
    #endif

    /// The AppModel source kind matching the last-chosen import target.
    private var importKind: DataSourceImportKind {
        switch importTarget {
        case .whoop: return .whoop
        case .appleHealth: return .appleHealth
        }
    }

    /// The summary for the source the user last imported in this step.
    private var lastSummary: String? {
        switch importTarget {
        case .whoop: return model.whoopImportSummary
        case .appleHealth: return model.appleHealthImportSummary
        }
    }

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        showingImporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>, for target: ImportTarget) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch target {
        case .whoop:
            model.importWhoop(url: url)
        case .appleHealth:
            model.importAppleHealth(url: url)
        }
    }

    private enum ImportTarget {
        case whoop
        case appleHealth

        var allowedContentTypes: [UTType] {
            // See DataSourcesView: `.folder` is a macOS-only affordance (pick an unzipped export
            // directory). On iOS it greys out the .zip in the Files picker (issue #179), so iOS
            // offers only the concrete file types.
            switch self {
            case .whoop:
                #if os(macOS)
                return [.zip, .folder]
                #else
                return [.zip]
                #endif
            case .appleHealth:
                #if os(macOS)
                return [.zip, .xml, .folder]
                #else
                return [.zip, .xml]
                #endif
            }
        }
    }
}

// MARK: - Step 9 · Notifications (wrist alerts priming)

private struct NotificationsStep: View {
    @Binding var dailyReviewOptIn: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        StepShell(title: String(localized: "Stay in the loop"),
                  subtitle: String(localized: "NOOP can tap your wrist when your \(Platform.deviceNoun) needs you. No glance at the screen required.")) {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(StrandPalette.accent.opacity(0.25), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.2 : 0.9)
                        .opacity(pulse ? 0 : 0.8)
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.5))
                        .frame(width: 86, height: 86)
                    Image(systemName: "bell.badge")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .frame(height: 130)

                #if os(iOS)
                // iOS gives an app no way to observe *other* apps' notifications, and the per-app picker
                // behind it is NSWorkspace-based (macOS-only). So drop the cross-app relay claim here and
                // keep only what iOS genuinely does: NOOP's own strain nudges + smart alarm buzz the strap
                // directly over BLE.
                InfoCard(
                    icon: "applewatch.radiowaves.left.and.right",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "A buzz, not a banner"),
                    message: String(localized: "NOOP taps Noop Band so an alert lands on your wrist instead of your screen. No need to reach for it. Everything stays on \(Platform.deviceNounPhrase).")
                )

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Strain nudges and your smart alarm tap your wrist the moment they fire."))
                    Checkline(text: String(localized: "Collection and analysis stay on Noop Band and \(Platform.deviceNounPhrase). Network features are off until you explicitly configure one."))
                }
                .frame(maxWidth: 460)
                #else
                InfoCard(
                    icon: "applewatch.radiowaves.left.and.right",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "A buzz, not a banner"),
                    message: String(localized: "When the \(Platform.deviceNoun) apps you choose send a notification, NOOP taps Noop Band: Slack, Calendar, Messages, or whatever matters. Everything stays on \(Platform.deviceNounPhrase).")
                )

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Pick which apps reach your wrist in Settings → Notifications."))
                    Checkline(text: String(localized: "Strain nudges and your smart alarm tap your wrist the same way."))
                }
                .frame(maxWidth: 460)
                #endif

                StrandCard(padding: 18, tint: StrandPalette.accent) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Daily review reminders")
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("Morning opens Sleep; evening opens Journal. Scores appear only after your latest device sync.")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $dailyReviewOptIn)
                                .labelsHidden()
                                .toggleStyle(.noopSwitch)
                                .accessibilityLabel("Daily review reminders")
                        }

                        Text("Off by default. If enabled, NOOP asks for notification access after you tap Enable & Continue. Reminder banners never include scores or health values.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 460)
            }
        }
        .onAppear { if !reduceMotion { withAnimation(StrandMotion.breathe) { pulse = true } } }
    }
}

// MARK: - Safety contacts

private struct SafetyContactsStep: View {
    @StateObject private var service = SafetyPagingService()

    var body: some View {
        StepShell(
            title: String(localized: "safety.onboarding.title"),
            subtitle: String(localized: "safety.onboarding.subtitle")
        ) {
            VStack(spacing: 20) {
                Image(systemName: "person.2.badge.shield.checkmark.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(StrandPalette.statusPositive)
                    .frame(height: 72)

                NoopCard {
                    SafetyContactsSetupView(service: service)
                }
                .frame(maxWidth: 520)

                Text("safety.onboarding.pending_body")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
        }
    }
}

// MARK: - Done

private struct DoneStep: View {
    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    VStack(spacing: 12) {
                        Text("Your thread starts here.")
                            .font(StrandFont.title1)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("noop.onboarding.done.title")
                        Text("Every beat, every night, every day, woven into one quiet picture of you. Welcome to NOOP.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("noop.onboarding.done.body")
                    }
                    .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, minHeight: max(360, proxy.size.height - 28))
                .padding(.horizontal, 4)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

// MARK: - Step shell (shared layout for each page)

/// Lets a brand-new user pick the app's finish up front (and learn it's changeable) — the same
/// System / Light / Graphite / OLED Black setting that lives in Settings → Appearance. The wizard
/// itself is the live preview.
private struct AppearanceStep: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.defaultMode.rawValue
    var body: some View {
        StepShell(title: String(localized: "Make it yours"),
                  subtitle: String(localized: "Choose how NOOP looks. The whole app updates as you tap. You can change this any time in Settings → Appearance.")) {
            VStack(spacing: 28) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(height: 96)
                AppearancePickerGrid(selection: $appearanceRaw)
                    .frame(maxWidth: 420)
                Text("System follows your \(Platform.deviceNoun)'s appearance. Black uses a true OLED canvas while keeping the same health-data colours.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)
        }
    }
}

// MARK: - Daily rhythm

/// A compact map of the real app shell just before hand-off. It teaches stable entry points instead of
/// adding another setup catalogue or enabling optional automations on the user's behalf.
private struct DailyRhythmStep: View {
    var body: some View {
        StepShell(
            title: String(localized: "onboarding.rhythm.title"),
            subtitle: String(localized: "onboarding.rhythm.subtitle")
        ) {
            VStack(spacing: 12) {
                InfoCard(
                    icon: "sun.horizon.fill",
                    tint: StrandPalette.statusWarning,
                    title: String(localized: "onboarding.rhythm.morning.title"),
                    message: String(localized: "onboarding.rhythm.morning.body")
                )
                InfoCard(
                    icon: "plus.circle.fill",
                    tint: StrandPalette.metricCyan,
                    title: String(localized: "onboarding.rhythm.quick.title"),
                    message: String(localized: "onboarding.rhythm.quick.body")
                )
                InfoCard(
                    icon: "square.and.pencil",
                    tint: StrandPalette.accent,
                    title: String(localized: "onboarding.rhythm.journal.title"),
                    message: String(localized: "onboarding.rhythm.journal.body")
                )
                InfoCard(
                    icon: "wand.and.stars",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "onboarding.rhythm.automations.title"),
                    message: String(localized: "onboarding.rhythm.automations.body")
                )
            }
        }
    }
}

private struct StepShell<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                if title != nil || subtitle != nil {
                    VStack(spacing: 8) {
                        if let title {
                            Text(title)
                                .font(StrandFont.title1)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .multilineTextAlignment(.center)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 8)
                }
                content()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

// MARK: - Radar sweep

private struct RadarSweep: View {
    var active: Bool
    var bonded: Bool
    @State private var angle: Double = 0
    @State private var ping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // Concentric rings.
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .stroke(StrandPalette.hairline.opacity(0.7), lineWidth: 1)
                        .frame(width: size * Double(i) / 3, height: size * Double(i) / 3)
                }
                // Cross hairs.
                Path { p in
                    p.move(to: CGPoint(x: size / 2, y: 0)); p.addLine(to: CGPoint(x: size / 2, y: size))
                    p.move(to: CGPoint(x: 0, y: size / 2)); p.addLine(to: CGPoint(x: size, y: size / 2))
                }
                .stroke(StrandPalette.hairline.opacity(0.5), lineWidth: 1)

                // The sweeping wedge.
                if active {
                    sweepWedge(size: size)
                        .rotationEffect(.degrees(angle))
                }

                // Center node — accent while searching, mint when bonded.
                Circle()
                    .fill(bonded ? StrandPalette.recovery100 : StrandPalette.accent)
                    .frame(width: 14, height: 14)
                    .shadow(color: (bonded ? StrandPalette.recovery100 : StrandPalette.accent).opacity(0.8),
                            radius: ping ? 10 : 4)

                // A discovered "blip" once bonded.
                if bonded {
                    Circle()
                        .fill(StrandPalette.statusPositive)
                        .frame(width: 12, height: 12)
                        .shadow(color: StrandPalette.statusPositive.opacity(0.9), radius: 8)
                        .position(x: size * 0.70, y: size * 0.36)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
        }
        .onAppear {
            if active { startSweep() }
            ping = true
        }
        .onChangeCompat(of: active) { isActive in
            if isActive { startSweep() }
        }
        .animation(StrandMotion.breathe(reduced: reduceMotion), value: ping)
    }

    private func sweepWedge(size: CGFloat) -> some View {
        let radius = size / 2
        return AngularGradient(
            gradient: Gradient(colors: [StrandPalette.accent.opacity(0.0),
                                        StrandPalette.accent.opacity(0.45)]),
            center: .center,
            startAngle: .degrees(-50),
            endAngle: .degrees(0)
        )
        .mask(
            Path { p in
                let c = CGPoint(x: radius, y: radius)
                p.move(to: c)
                p.addArc(center: c, radius: radius,
                         startAngle: .degrees(-50), endAngle: .degrees(0), clockwise: false)
                p.closeSubpath()
            }
        )
        .frame(width: size, height: size)
        .blendMode(.plusLighter)
    }

    private func startSweep() {
        // Reduce Motion: keep the wedge still (the static rings/crosshairs/blip
        // still convey "searching" / "found") instead of spinning forever.
        guard !reduceMotion else { return }
        angle = 0
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

// MARK: - The bottom "thread" progress

private struct ThreadProgress: View {
    var progress: Double           // 0...1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            GeometryReader { geo in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let phase = reduceMotion ? 0.35 : (sin(elapsed * .pi * 2 / 1.8) + 1) / 2
                let fillWidth = max(6, geo.size.width * min(max(progress, 0), 1))
                let activeHeight = 3 + phase * 2.5

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(StrandPalette.hairline)
                        .frame(height: 3)
                    Capsule()
                        .fill(LinearGradient(gradient: StrandPalette.recoveryGradient,
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: fillWidth, height: activeHeight)
                        .shadow(
                            color: StrandPalette.recovery078.opacity(0.24 + phase * 0.34),
                            radius: 2 + phase * 4
                        )
                        .animation(StrandMotion.gentle, value: progress)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Reusable pieces

private struct InfoCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var body: some View {
        StrandCard {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(message)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 480)
    }
}

private struct Checkline: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(StrandPalette.statusPositive)
                .padding(.top, 1)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct FieldRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).strandOverline()
            Spacer()
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

private struct DisclosureToggle: View {
    @Binding var open: Bool
    let label: String
    var body: some View {
        Button {
            withAnimation(StrandMotion.gentle) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.up" : "chevron.down")
                Text(label)
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.accent)
        }
        .buttonStyle(.plain)
    }
}

private struct ImportActionButton: View {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(StrandFont.subhead.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

// MARK: - Button styles

private struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(StrandFont.headline)
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            // `accent` intentionally flips with appearance (black in Light, near-white in Dark),
            // so a hard-coded white label disappears on the Dark-mode CTA. `accentInk` is the
            // paired contrast token: white over the Light-mode black fill, dark over the
            // Dark-mode white fill. This one style drives every onboarding footer CTA.
            .foregroundStyle(StrandPalette.accentInk)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? StrandPalette.accentHover : StrandPalette.accent)
            )
            .shadow(color: StrandPalette.accent.opacity(0.4), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.vertical, 11)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StrandPalette.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(configuration.isPressed ? StrandPalette.hairlineStrong : StrandPalette.hairline, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

// MARK: - Preview

#if DEBUG
private struct OnboardingPreview: View {
    @StateObject private var model = AppModel()
    var body: some View {
        OnboardingWizard(onFinished: {})
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(model.profile)
            .frame(width: 1100, height: 780)
    }
}

#Preview("Onboarding") { OnboardingPreview() }
#endif
