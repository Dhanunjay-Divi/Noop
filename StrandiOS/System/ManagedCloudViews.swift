#if os(iOS)
import NoopRemoteSync
import SwiftUI
import StrandDesign

struct NoopPlusView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var service = ManagedCloudService.shared

    var body: some View {
        ScreenScaffold(
            title: "NOOP+",
            subtitle: "Optional storage and multi-device restore. Core metrics, coaching, workouts, journal, automations and exports stay available without an account."
        ) {
            ManagedCloudBackupCard(
                service: service,
                repo: model.repo
            )
        }
    }
}

struct ManagedCloudBackupCard: View {
    @ObservedObject var service: ManagedCloudService
    let repo: Repository

    @State private var showSetup = false

    var body: some View {
        StrandCard(
            padding: 20,
            tint: service.phase == .enrolled ? StrandPalette.accent : nil
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: service.phase == .enrolled
                          ? "checkmark.icloud.fill"
                          : "icloud")
                        .foregroundStyle(StrandPalette.accent)
                    Text("NOOP+ managed backup")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 0)
                    stateLabel
                }

                Text(
                    "Optional storage and multi-device restore. Core metrics, coaching, workouts, journal, automations and exports stay available without an account."
                )
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                if !service.status.isEmpty {
                    Text(service.status)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let lastSuccessAt = service.lastSuccessAt {
                    Text("Last cloud sync \(lastSuccessAt.formatted(.relative(presentation: .named)))")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                if service.phase == .unavailable {
                    Text(
                        "This build is not connected to a managed storage environment. Local NOOP and folder backup continue to work."
                    )
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    NoopButton(
                        service.phase == .enrolled ? "Manage NOOP+" : "Set up NOOP+",
                        systemImage: service.phase == .enrolled ? "gearshape" : "arrow.right",
                        kind: service.phase == .enrolled ? .secondary : .primary,
                        fullWidth: true
                    ) {
                        showSetup = true
                    }
                }
            }
        }
        .sheet(isPresented: $showSetup) {
            ManagedCloudSetupSheet(
                service: service,
                repo: repo,
                onClose: { showSetup = false }
            )
        }
        .task {
            service.bootstrap()
            if service.phase == .deletionScheduled {
                await service.refreshDeletionStatus()
            }
        }
    }

    private var stateLabel: some View {
        let presentation: (label: String, color: Color)
        switch service.phase {
        case .enrolled:
            presentation = (String(localized: "On"), StrandPalette.statusPositive)
        case .deletionScheduled:
            presentation = (String(localized: "Deleting"), StrandPalette.statusWarning)
        case .consentRequired, .codeSent:
            presentation = (String(localized: "Setup"), StrandPalette.statusWarning)
        case .signedOut, .unavailable:
            presentation = (String(localized: "Off"), StrandPalette.textTertiary)
        }
        return Text(presentation.label)
            .font(StrandFont.caption)
            .foregroundStyle(presentation.color)
    }
}

private struct ManagedCloudSetupSheet: View {
    @ObservedObject var service: ManagedCloudService
    let repo: Repository
    let onClose: () -> Void

    @State private var phoneNumber = ""
    @State private var code = ""
    @State private var consent = false
    @State private var deletionCode = ""
    @State private var deletionCodeRequested = false
    @State private var confirmDeletion = false
    @State private var confirmHistoryExport = false
    @State private var pendingRevoke: ManagedInstallation?

    var body: some View {
        NavigationStack {
            ZStack {
                StrandPalette.surfaceBase.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        switch service.phase {
                        case .unavailable:
                            unavailable
                        case .signedOut, .codeSent:
                            authentication
                        case .consentRequired:
                            consentReview
                        case .enrolled:
                            enrolled
                        case .deletionScheduled:
                            deletionScheduled
                        }
                    }
                    .screenPadding()
                    .padding(.vertical, NoopMetrics.space5)
                }
            }
            .navigationTitle("NOOP+")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .disabled(service.isBusy)
                    .accessibilityLabel("Close NOOP+ setup")
                }
            }
        }
        .interactiveDismissDisabled(service.isBusy)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .alert("Delete NOOP+ cloud account?", isPresented: $confirmDeletion) {
            Button("Send verification code", role: .destructive) {
                deletionCodeRequested = true
                Task { await service.sendDeletionCode() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Cloud data and the NOOP+ managed account will be scheduled for deletion after a 24-hour cooling-off period. Data stored locally on this iPhone is not deleted."
            )
        }
        .alert(
            "Export complete cloud history?",
            isPresented: $confirmHistoryExport
        ) {
            Button("Export") {
                Task {
                    if let url = await service.exportCompleteCloudHistory(
                        repo: repo
                    ) {
                        FileExport.shareTemporaryFile(at: url)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "NOOP will first finish backing up current phone data, then download every cloud chunk and personal record, including history no longer stored on this iPhone. The ZIP contains readable sensitive health data and may be large. Keep NOOP open until the share sheet appears."
            )
        }
        .alert(item: $pendingRevoke) { installation in
            Alert(
                title: Text("Revoke this NOOP+ device?"),
                message: Text(
                    "It will stop server sync and must enroll again before it can access this NOOP+ account. Local data on that device and data already backed up are not deleted."
                ),
                primaryButton: .destructive(Text("Revoke")) {
                    Task {
                        await service.revokeInstallation(
                            installation.installationID
                        )
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .task(id: service.phase) {
            if service.phase == .enrolled {
                await service.refreshOverview()
            }
        }
    }

    private var authentication: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            header(
                symbol: "lock.shield",
                title: "Private backup without changing local NOOP",
                detail: "Verify a phone number to protect cloud storage and recovery. Signing in does not upload anything."
            )

            VStack(alignment: .leading, spacing: 12) {
                TextField("Phone number with country code", text: $phoneNumber)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .textFieldStyle(.roundedBorder)
                    .disabled(service.isBusy || service.phase == .codeSent)
                    .accessibilityLabel("NOOP+ phone number")

                if service.phase == .codeSent {
                    TextField("Verification code", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(service.isBusy)
                        .accessibilityLabel("NOOP+ verification code")

                    NoopButton(
                        service.isBusy ? "Verifying…" : "Verify code",
                        systemImage: "checkmark.shield",
                        kind: .primary,
                        fullWidth: true
                    ) {
                        Task { await service.verifyCode(code) }
                    }
                    .disabled(service.isBusy || code.isEmpty)

                    Button("Use a different number") {
                        code = ""
                        service.disconnect()
                    }
                    .buttonStyle(.plain)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
                    .disabled(service.isBusy)
                } else {
                    NoopButton(
                        service.isBusy ? "Sending…" : "Send verification code",
                        systemImage: "message",
                        kind: .primary,
                        fullWidth: true
                    ) {
                        Task { await service.sendCode(to: phoneNumber) }
                    }
                    .disabled(service.isBusy || phoneNumber.isEmpty)
                }
            }

            status

            privacyBoundary
        }
    }

    private var consentReview: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            header(
                symbol: "hand.raised.fill",
                title: "Choose what happens next",
                detail: "Your phone is verified. NOOP still has not uploaded health data."
            )

            VStack(alignment: .leading, spacing: 14) {
                evidenceRow(
                    symbol: "waveform.path.ecg",
                    title: "Backed up",
                    detail: "Sensor streams, sleep, workouts and daily summaries needed for restore"
                )
                evidenceRow(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Used for",
                    detail: "A server-readable copy, protected in transit and at rest, for managed storage and multi-device restore"
                )
                evidenceRow(
                    symbol: "iphone",
                    title: "Stays local-first",
                    detail: "Band collection and calculations continue on this device; cloud cannot prevent iOS suspension or BLE gaps"
                )
            }

            Toggle(isOn: $consent) {
                Text("I allow NOOP to upload my health backup to NOOP+.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.noopSwitch)
            .accessibilityIdentifier("managed-cloud-consent")

            NoopButton(
                service.isBusy ? "Enabling…" : "Allow cloud backup",
                systemImage: "icloud.and.arrow.up",
                kind: .primary,
                fullWidth: true
            ) {
                Task { await service.enroll(repo: repo) }
            }
            .disabled(service.isBusy || !consent)

            Button("Sign out without enabling cloud backup") {
                service.disconnect()
            }
            .buttonStyle(.plain)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .disabled(service.isBusy)

            status
            privacyBoundary
        }
    }

    private var enrolled: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            header(
                symbol: "checkmark.icloud.fill",
                title: "Cloud backup is on",
                detail: "Signed in with \(service.maskedPhoneNumber). Sync is incremental and resumes from durable checkpoints."
            )

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic catch-up")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Runs after local refreshes, foreground opens and best-effort background wakes.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Automatic catch-up", isOn: Binding(
                    get: { service.automatic },
                    set: { service.automatic = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.noopSwitch)
                .disabled(service.isBusy)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reduce phone storage after backup")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Keeps \(ManagedLocalRetentionPolicy.detailedHistoryDays) days of validated sensor detail on this iPhone. Daily metrics, sleep, workouts, body measurements, journals, plans, and preferences remain local.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Reduce phone storage after backup", isOn: Binding(
                    get: { service.optimizePhoneStorage },
                    set: { service.optimizePhoneStorage = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.noopSwitch)
                .disabled(service.isBusy)
            }

            if let overview = service.overview {
                Text(managedStorageSummary(overview))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let activeInstallations = service.installations.filter {
                $0.status != "revoked"
            }
            if !activeInstallations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NOOP+ devices")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)

                    ForEach(activeInstallations) { installation in
                        managedInstallationRow(installation)
                    }
                }
            }

            if let date = service.lastSuccessAt {
                Text("Last successful sync \(date.formatted(.relative(presentation: .named)))")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }

            status

            NoopButton(
                service.isBusy ? "Syncing…" : "Sync now",
                systemImage: "arrow.triangle.2.circlepath",
                kind: .primary,
                fullWidth: true
            ) {
                Task { await service.syncNow(repo: repo) }
            }
            .disabled(service.isBusy)

            NoopButton(
                service.isBusy
                    ? "Preparing export…"
                    : "Export complete cloud history",
                systemImage: "square.and.arrow.up",
                kind: .secondary,
                fullWidth: true
            ) {
                confirmHistoryExport = true
            }
            .disabled(service.isBusy)

            NoopButton(
                "Disconnect this iPhone",
                systemImage: "rectangle.portrait.and.arrow.right",
                kind: .secondary,
                fullWidth: true
            ) {
                service.disconnect()
            }
            .disabled(service.isBusy)

            Button("Delete NOOP+ cloud account…") {
                confirmDeletion = true
            }
            .buttonStyle(.plain)
            .font(StrandFont.caption)
            .foregroundStyle(.red)
            .disabled(service.isBusy)

            if deletionCodeRequested {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Fresh verification code", text: $deletionCode)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(service.isBusy)
                        .accessibilityLabel("Account deletion verification code")
                    NoopButton(
                        service.isBusy ? "Verifying…" : "Schedule account deletion",
                        systemImage: "trash",
                        kind: .destructive,
                        fullWidth: true
                    ) {
                        Task { await service.requestAccountDeletion(code: deletionCode) }
                    }
                    .disabled(service.isBusy || deletionCode.isEmpty)
                }
            }

            privacyBoundary
        }
    }

    private var deletionScheduled: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            header(
                symbol: "clock.badge.exclamationmark",
                title: "Account deletion scheduled",
                detail: "Cloud backup is stopped. NOOP will retain the managed account only through its 24-hour cooling-off period."
            )
            if let notBefore = service.deletionNotBefore {
                Text("Deletion can begin after \(notBefore).")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            status
            NoopButton(
                service.isBusy ? "Working…" : "Cancel account deletion",
                systemImage: "xmark.circle",
                kind: .primary,
                fullWidth: true
            ) {
                Task { await service.cancelAccountDeletion() }
            }
            .disabled(service.isBusy)

            NoopButton(
                service.isBusy ? "Checking…" : "Check deletion status",
                systemImage: "arrow.clockwise",
                kind: .secondary,
                fullWidth: true
            ) {
                Task { await service.refreshDeletionStatus() }
            }
            .disabled(service.isBusy)

            Text("Local NOOP data is not part of this request and remains usable without an account.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unavailable: some View {
        header(
            symbol: "icloud.slash",
            title: "NOOP+ is unavailable",
            detail: "This build is not connected to a managed storage environment. Local NOOP and folder backup continue to work."
        )
    }

    private var privacyBoundary: some View {
        Text(
            "NOOP+ is a storage option only. It does not unlock or remove health features, and it does not replace the phone-to-band connection."
        )
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var status: some View {
        if !service.status.isEmpty {
            Text(service.status)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(
        symbol: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 40, height: 40)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(detail)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func evidenceRow(
        symbol: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func managedInstallationRow(
        _ installation: ManagedInstallation
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: installation.platform == "ios"
                  ? "iphone"
                  : installation.platform == "android"
                  ? "apps.iphone"
                  : "laptopcomputer")
                .foregroundStyle(
                    installation.current
                        ? StrandPalette.statusPositive
                        : StrandPalette.textSecondary
                )
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    installation.current
                        ? "\(managedPlatformName(installation.platform)) · This device"
                        : managedPlatformName(installation.platform)
                )
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                Text("Last seen \(managedRelativeTime(installation.lastSeenAt))")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }

            Spacer(minLength: 8)
            if !installation.current {
                Button("Revoke") {
                    pendingRevoke = installation
                }
                .buttonStyle(.plain)
                .font(StrandFont.caption)
                .foregroundStyle(.red)
                .disabled(service.isBusy)
            }
        }
        .padding(.vertical, 6)
    }
}

private func managedStorageSummary(_ overview: ManagedStorageOverview) -> String {
    let used = overview.committedBytes.addingReportingOverflow(
        overview.reservedBytes
    )
    let usedText = ByteCountFormatter.string(
        fromByteCount: used.overflow ? overview.committedBytes : used.partialValue,
        countStyle: .file
    )
    let storageText: String
    if let maximum = overview.maximumBytes {
        let maximumText = ByteCountFormatter.string(
            fromByteCount: maximum,
            countStyle: .file
        )
        storageText = String(localized: "\(usedText) of \(maximumText) stored")
    } else {
        storageText = String(localized: "\(usedText) stored")
    }
    return String(
        localized: "\(storageText) · \(overview.installationCount) of \(overview.maximumInstallations) devices"
    )
}

private func managedPlatformName(_ platform: String) -> String {
    switch platform {
    case "ios": return String(localized: "iPhone")
    case "android": return String(localized: "Android")
    case "macos": return String(localized: "Mac")
    default: return String(localized: "Device")
    }
}

private func managedRelativeTime(_ value: String) -> String {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = fractional.date(from: value)
        ?? ISO8601DateFormatter().date(from: value) else {
        return String(localized: "recently")
    }
    return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
}
#endif
