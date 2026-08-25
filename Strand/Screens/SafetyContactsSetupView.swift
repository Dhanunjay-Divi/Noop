import NoopRemoteSync
import StrandDesign
import SwiftUI

struct SafetyContactsSetupView: View {
    @ObservedObject var service: SafetyPagingService
    var marksReminderNeeded = true

    @State private var ownerName = ""
    @State private var contactName = ""
    @State private var contactPhone = ""
    @State private var contactToRemove: RemoteSafetyContact?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            switch service.setupState {
            case .needsServer:
                needsServer
            case .needsEnrollment:
                enrollment
            case .ready:
                readyContacts
            }

            if service.isBusy {
                HStack(spacing: NoopMetrics.space2) {
                    ProgressView()
                    Text("safety.setup.updating")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityElement(children: .combine)
            } else if !service.statusMessage.isEmpty {
                Text(service.statusMessage)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            if marksReminderNeeded {
                service.markSetupPresented()
            }
            await service.refresh()
        }
        .alert("safety.setup.title", isPresented: errorBinding) {
            Button("safety.ok", role: .cancel) { service.dismissError() }
        } message: {
            Text(service.errorMessage ?? "")
        }
        .confirmationDialog(
            "safety.contact.remove.title",
            isPresented: removeConfirmation,
            titleVisibility: .visible
        ) {
            if let contactToRemove {
                Button("safety.contact.remove.action", role: .destructive) {
                    Task {
                        await service.remove(contactToRemove)
                        self.contactToRemove = nil
                    }
                }
            }
            Button("safety.cancel", role: .cancel) {
                contactToRemove = nil
            }
        } message: {
            if let contactToRemove {
                Text(
                    String(
                        format: String(localized: "safety.contact.remove.body_format"),
                        contactToRemove.displayName
                    )
                )
            }
        }
    }

    private var needsServer: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Label("safety.network.unavailable.title", systemImage: "network.slash")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("safety.network.unavailable.body")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            StatePill("safety.setup.required", tone: .warning)
        }
    }

    private var enrollment: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("safety.enrollment.title")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("safety.enrollment.body")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("safety.owner.name", text: $ownerName)
                .textFieldStyle(.roundedBorder)
                .safetyNameContentType()
                .disabled(service.isBusy)
            NoopButton(
                "safety.enrollment.activate",
                systemImage: "shield.checkered",
                kind: .primary,
                fullWidth: true
            ) {
                Task { await service.bootstrap(displayName: ownerName) }
            }
            .disabled(service.isBusy || ownerName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var readyContacts: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            readinessHeader

            if !service.pagingConfigured || service.pagingEnabled == false {
                HStack(alignment: .top, spacing: NoopMetrics.space2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .accessibilityHidden(true)
                    Text("safety.delivery.unavailable")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if service.contacts.isEmpty {
                Text("safety.contacts.empty")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(service.contacts) { contact in
                        contactRow(contact)
                        if contact.id != service.contacts.last?.id {
                            Divider().overlay(StrandPalette.hairline)
                        }
                    }
                }
            }

            if service.contacts.count < service.maximumContacts {
                Divider().overlay(StrandPalette.hairline)
                addContactForm
            } else {
                Text("safety.contacts.maximum")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var readinessHeader: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            ZStack {
                Circle()
                    .fill(
                        (service.acceptedCount >= SafetyPagingService.minimumAcceptedContacts
                            ? StrandPalette.statusPositive
                            : StrandPalette.statusWarning)
                            .opacity(0.14)
                    )
                Image(systemName: "person.2.badge.shield.checkmark.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(
                        service.acceptedCount >= SafetyPagingService.minimumAcceptedContacts
                            ? StrandPalette.statusPositive
                            : StrandPalette.statusWarning
                    )
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    String(
                        format: String(localized: "safety.contacts.accepted_count_format"),
                        service.acceptedCount,
                        SafetyPagingService.minimumAcceptedContacts
                    )
                )
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(readinessDetail)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 8)
            Button {
                Task { await service.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textSecondary)
            .disabled(service.isBusy)
            .accessibilityLabel(Text("safety.contacts.refresh"))
        }
    }

    private func contactRow(_ contact: RemoteSafetyContact) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: contact.status == .accepted
                  ? "checkmark.circle.fill"
                  : "person.crop.circle.badge.clock")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(contact.status == .accepted
                                 ? StrandPalette.statusPositive
                                 : StrandPalette.statusWarning)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.displayName)
                    .font(StrandFont.body.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(contact.phoneE164)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let invitationError = contact.invitationError,
                   contact.invitationDeliveryStatus == .failed {
                    Text(invitationError)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusCriticalText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            StatePill(statusLabel(contact.status), tone: statusTone(contact.status))
            Menu {
                if contact.status != .accepted {
                    Button {
                        Task { await service.resend(contact) }
                    } label: {
                        Label("safety.contact.resend", systemImage: "paperplane")
                    }
                    .disabled(
                        !SafetyPagingService.deliveryAvailable(
                            providerConfigured: service.pagingConfigured,
                            pagingEnabled: service.pagingEnabled
                        )
                    )
                }
                Button(role: .destructive) {
                    contactToRemove = contact
                } label: {
                    Label("safety.contact.remove.action", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(StrandPalette.textSecondary)
            .disabled(service.isBusy)
            .accessibilityLabel(
                Text(
                    String(
                        format: String(localized: "safety.contact.actions_format"),
                        contact.displayName
                    )
                )
            )
        }
        .padding(.vertical, NoopMetrics.space2)
    }

    private var addContactForm: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("safety.contact.invite.title")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            TextField("safety.contact.name", text: $contactName)
                .textFieldStyle(.roundedBorder)
                .safetyNameContentType()
            TextField("safety.contact.phone", text: $contactPhone)
                .textFieldStyle(.roundedBorder)
                .safetyPhoneContentType()
            Text("safety.contact.invitation_help")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            NoopButton(
                "safety.contact.invitation.send",
                systemImage: "paperplane.fill",
                kind: .secondary,
                fullWidth: true
            ) {
                Task {
                    if await service.addContact(
                        displayName: contactName,
                        phone: contactPhone
                    ) {
                        contactName = ""
                        contactPhone = ""
                    }
                }
            }
            .disabled(
                service.isBusy
                    || !service.pagingConfigured
                    || service.pagingEnabled == false
                    || contactName.trimmingCharacters(in: .whitespaces).isEmpty
                    || contactPhone.trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { service.errorMessage != nil },
            set: { if !$0 { service.dismissError() } }
        )
    }

    private var removeConfirmation: Binding<Bool> {
        Binding(
            get: { contactToRemove != nil },
            set: { if !$0 { contactToRemove = nil } }
        )
    }

    private var readinessDetail: String {
        switch service.remainingAcceptedContacts {
        case 0:
            return String(localized: "safety.contacts.threshold_complete")
        case 1:
            return String(localized: "safety.contacts.acceptance_one")
        default:
            return String(
                format: String(localized: "safety.contacts.acceptances_format"),
                service.remainingAcceptedContacts
            )
        }
    }

    private func statusLabel(_ status: RemoteSafetyContactStatus) -> LocalizedStringKey {
        switch status {
        case .accepted: return "safety.contact.status.accepted"
        case .pending: return "safety.contact.status.pending"
        case .declined: return "safety.contact.status.declined"
        case .expired: return "safety.contact.status.expired"
        }
    }

    private func statusTone(_ status: RemoteSafetyContactStatus) -> StrandTone {
        switch status {
        case .accepted: return .positive
        case .pending: return .warning
        case .declined, .expired: return .neutral
        }
    }
}

private extension View {
    @ViewBuilder
    func safetyNameContentType() -> some View {
        #if os(iOS)
        textContentType(.name)
        #else
        self
        #endif
    }

    @ViewBuilder
    func safetyPhoneContentType() -> some View {
        #if os(iOS)
        textContentType(.telephoneNumber)
        #else
        self
        #endif
    }
}
