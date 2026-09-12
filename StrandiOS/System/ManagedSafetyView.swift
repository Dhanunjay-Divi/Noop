#if os(iOS)
import NoopRemoteSync
import StrandAnalytics
import StrandDesign
import SwiftUI

struct ManagedSafetyView: View {
    @ObservedObject private var service = ManagedCloudService.shared
    @ObservedObject var locationProvider: SafetyLocationProvider
    @Binding var durationHours: Int

    @State private var noopID = ""
    @State private var shareLocation = false
    @State private var confirmPage = false
    @State private var contactToRemove: ManagedSafetyContact?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            SectionHeader(
                "managed.safety.section",
                overline: "managed.safety.section.overline"
            )
            if service.phase == .enrolled {
                pageCard
                setupCard
            } else {
                unavailableCard
            }
            if !service.safetyStatus.isEmpty {
                Text(service.safetyStatus)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            service.bootstrap()
            if service.phase == .enrolled {
                await service.refreshSafety()
            }
        }
        .onChange(of: service.phase) { _, phase in
            guard phase == .enrolled else { return }
            Task {
                await service.refreshSafety()
            }
        }
        .confirmationDialog(
            "managed.safety.confirm.title",
            isPresented: $confirmPage,
            titleVisibility: .visible
        ) {
            Button("managed.safety.confirm.send", role: .destructive) {
                Task { await startPage() }
            }
            Button("safety.cancel", role: .cancel) {}
        } message: {
            Text(
                shareLocation
                    ? localizedFormat(
                        "managed.safety.confirm.location.body",
                        Int64(durationHours == 12 ? 12 : 8)
                    )
                    : String(localized: "managed.safety.confirm.body")
            )
        }
        .confirmationDialog(
            "managed.safety.remove.contact",
            isPresented: Binding(
                get: { contactToRemove != nil },
                set: { if !$0 { contactToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let contact = contactToRemove {
                Button("managed.safety.remove.contact", role: .destructive) {
                    contactToRemove = nil
                    Task {
                        await service.removeSafetyContact(contact.profileID)
                    }
                }
            }
            Button("safety.cancel", role: .cancel) {
                contactToRemove = nil
            }
        } message: {
            Text("managed.safety.remove.contact.body")
        }
    }

    private var unavailableCard: some View {
        NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: "person.2.badge.shield.checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("managed.safety.app.title")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("managed.safety.not.enrolled")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var setupCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    Image(systemName: "person.2.badge.shield.checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("managed.safety.app.title")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("managed.safety.app.body")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if service.pendingSafetyInviteCapability != nil {
                    Divider()
                    pendingInvite
                }

                Divider()
                Text("managed.safety.add.by.id")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                HStack(spacing: NoopMetrics.space2) {
                    TextField("NOOP-XXXX-XXXX-XXXX-XXXX", text: $noopID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: noopID) { _, value in
                            noopID = String(
                                value.uppercased().prefix(24)
                            )
                        }
                    Button {
                        let value = noopID
                        noopID = ""
                        Task {
                            await service.createSafetyRequest(noopID: value)
                        }
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .frame(
                                width: NoopMetrics.controlHeight,
                                height: NoopMetrics.controlHeight
                            )
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .disabled(
                        service.isBusy
                            || ManagedSocialIdentifier.canonicalNOOPID(noopID)
                                == nil
                    )
                    .accessibilityLabel("managed.safety.add.contact")
                }

                inviteControls
                requests
                contacts

                NoopButton(
                    "managed.safety.notification.permission",
                    systemImage: "bell.badge.fill",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    Task {
                        _ = await service.enableManagedSafetyNotifications()
                    }
                }
                .disabled(service.isBusy)
            }
        }
    }

    private var pendingInvite: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("managed.safety.invite.pending.title")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("managed.safety.invite.pending.body")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NoopMetrics.space2) {
                NoopButton(
                    "managed.safety.add.contact",
                    systemImage: "paperplane.fill",
                    fullWidth: true
                ) {
                    Task { await service.redeemPendingSafetyInvite() }
                }
                .disabled(service.isBusy)
                Button {
                    service.clearPendingSafetyInvite()
                } label: {
                    Image(systemName: "xmark")
                        .frame(
                            width: NoopMetrics.controlHeight,
                            height: NoopMetrics.controlHeight
                        )
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                .accessibilityLabel("managed.safety.dismiss.invite")
            }
        }
    }

    @ViewBuilder
    private var inviteControls: some View {
        Divider()
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("managed.safety.invite.title")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("managed.safety.invite.body")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if let invite = service.safetyInvite,
               let url = service.safetyInviteURL(invite) {
                HStack(spacing: NoopMetrics.space2) {
                    ShareLink(
                        item: url,
                        subject: Text("managed.safety.share.invite.subject"),
                        message: Text("managed.safety.share.invite.body")
                    ) {
                        Label(
                            "managed.safety.share.invite",
                            systemImage: "square.and.arrow.up"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(
                        NoopButtonStyle(.secondary, fullWidth: true)
                    )
                    .disabled(service.isBusy)
                    Button {
                        Task { await service.revokeSafetyInvite() }
                    } label: {
                        Image(systemName: "link.badge.minus")
                            .frame(
                                width: NoopMetrics.controlHeight,
                                height: NoopMetrics.controlHeight
                            )
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .accessibilityLabel("managed.safety.revoke.invite")
                    .disabled(service.isBusy)
                }
            } else {
                NoopButton(
                    "managed.safety.create.invite",
                    systemImage: "link.badge.plus",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    Task { await service.createSafetyInvite() }
                }
                .disabled(service.isBusy)
            }
        }
    }

    @ViewBuilder
    private var requests: some View {
        let pending = service.safetyRequests.filter { $0.status == "pending" }
        Divider()
        Text("managed.safety.pending.requests")
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .foregroundStyle(StrandPalette.textTertiary)
        if pending.isEmpty {
            Text("managed.safety.requests.empty")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        } else {
            ForEach(pending) { request in
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text(verbatim: requestLabel(request))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    if request.direction == "incoming" {
                        HStack(spacing: NoopMetrics.space2) {
                            NoopButton(
                                "managed.safety.accept",
                                systemImage: "checkmark.circle.fill",
                                fullWidth: true
                            ) {
                                Task {
                                    await service.decideSafetyRequest(
                                        request.requestID,
                                        accept: true
                                    )
                                }
                            }
                            NoopButton(
                                "managed.safety.decline",
                                kind: .tertiary,
                                fullWidth: true
                            ) {
                                Task {
                                    await service.decideSafetyRequest(
                                        request.requestID,
                                        accept: false
                                    )
                                }
                            }
                        }
                        .disabled(service.isBusy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contacts: some View {
        let values = service.safetyContacts?.contacts ?? []
        Divider()
        Text("managed.safety.contacts.title")
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .foregroundStyle(StrandPalette.textTertiary)
        Text(verbatim: contactCountLabel)
        .font(StrandFont.caption)
        .foregroundStyle(
            outboundContacts.count >= minimumContacts
                ? StrandPalette.statusPositive
                : StrandPalette.textTertiary
        )
        if values.isEmpty {
            Text("managed.safety.contact.empty")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        } else {
            ForEach(values) { contact in
                HStack(spacing: NoopMetrics.space2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(
                            contact.role == "contact"
                                ? "managed.safety.contact.you.page"
                                : "managed.safety.contact.pages.you"
                        )
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    Button {
                        contactToRemove = contact
                    } label: {
                        Image(systemName: "trash")
                            .frame(
                                width: NoopMetrics.controlHeight,
                                height: NoopMetrics.controlHeight
                            )
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .accessibilityLabel("managed.safety.remove.contact")
                    .disabled(service.isBusy)
                }
            }
        }
    }

    private var pageCard: some View {
        NoopCard(tint: StrandPalette.statusCritical) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    Image(systemName: "sos.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(StrandPalette.statusCriticalText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("managed.safety.page.title")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("managed.safety.page.body")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("managed.safety.duration")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Picker("managed.safety.duration", selection: durationBinding) {
                    Text("safety.sos.duration.8_hours").tag(8)
                    Text("safety.sos.duration.12_hours").tag(12)
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $shareLocation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("managed.safety.location.current")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("managed.safety.location.current.body")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(StrandPalette.statusPositive)

                if shareLocation && !locationReady {
                    NoopButton(
                        "safety.location.get",
                        systemImage: "location.fill",
                        kind: .secondary,
                        fullWidth: true
                    ) {
                        locationProvider.requestCurrentLocation()
                    }
                    Text("managed.safety.location.needed")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                }
                if shareLocation,
                   locationReady,
                   !locationProvider.hasBackgroundAuthorization {
                    Text("managed.safety.location.background.body")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    NoopButton(
                        "managed.safety.location.background.enable",
                        systemImage: "location.fill.viewfinder",
                        kind: .secondary,
                        fullWidth: true
                    ) {
                        locationProvider.requestBackgroundAuthorization()
                    }
                }

                NoopButton(
                    service.isBusy
                        ? "managed.safety.working"
                        : "managed.safety.confirm.send",
                    systemImage: "sos",
                    kind: .destructive,
                    fullWidth: true
                ) {
                    confirmPage = true
                }
                .disabled(!canStartPage)

                if outboundContacts.count < minimumContacts {
                    Text(verbatim: contactsRemainingLabel)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                } else if activeOwnerIncident != nil {
                    Text("managed.safety.active.page.exists")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    StatePill(
                        "managed.safety.threshold.ready",
                        tone: .positive
                    )
                }

                incidents
            }
        }
    }

    @ViewBuilder
    private var incidents: some View {
        let active = service.safetyIncidents.filter {
            $0.status == "open" || $0.status == "acknowledged"
        }
        if active.isEmpty {
            if let last = service.safetyIncidents.first {
                Divider()
                Text(verbatim: lastClosedLabel(last))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        } else {
            ForEach(active) { incident in
                Divider()
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: incidentTitle(incident))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: NoopMetrics.space2)
                        StatePill(
                            incident.status == "acknowledged"
                                ? "managed.safety.status.acknowledged"
                                : "managed.safety.status.active",
                            tone: incident.status == "acknowledged"
                                ? .positive
                                : .warning
                        )
                    }
                    if let delivery = incident.delivery {
                        Text(verbatim: deliveryLabel(delivery))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    }
                    ForEach(incident.participants) { participant in
                        Text(verbatim: participantLabel(participant))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    }
                    if let location = incident.location,
                       let url = mapURL(location) {
                        Link(destination: url) {
                            Label(
                                "managed.safety.open.maps",
                                systemImage: "map.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(
                            NoopButtonStyle(.secondary, fullWidth: true)
                        )
                    }
                    if incident.role == "owner" {
                        if incident.shareLocation && locationReady {
                            NoopButton(
                                "managed.safety.location.update",
                                systemImage: "location.fill",
                                kind: .secondary,
                                fullWidth: true
                            ) {
                                Task { await replaceLocation(for: incident) }
                            }
                            .disabled(service.isBusy)
                        }
                        if canRetryPush(for: incident) {
                            NoopButton(
                                "managed.safety.retry.push",
                                systemImage: "arrow.clockwise",
                                kind: .secondary,
                                fullWidth: true
                            ) {
                                Task {
                                    await service.retrySafetyPush(
                                        incident.incidentID
                                    )
                                }
                            }
                            .disabled(service.isBusy)
                        }
                        HStack(spacing: NoopMetrics.space2) {
                            NoopButton(
                                "managed.safety.resolve.page",
                                systemImage: "checkmark.circle.fill",
                                fullWidth: true
                            ) {
                                Task {
                                    await service.endSafetyIncident(
                                        incident.incidentID,
                                        resolved: true
                                    )
                                }
                            }
                            NoopButton(
                                "managed.safety.cancel.page",
                                kind: .tertiary,
                                fullWidth: true
                            ) {
                                Task {
                                    await service.endSafetyIncident(
                                        incident.incidentID,
                                        resolved: false
                                    )
                                }
                            }
                        }
                        .disabled(service.isBusy)
                    } else {
                        HStack(spacing: NoopMetrics.space2) {
                            NoopButton(
                                "managed.safety.responding",
                                systemImage: "checkmark.circle.fill",
                                fullWidth: true
                            ) {
                                Task {
                                    await service.respondToSafetyIncident(
                                        incident.incidentID,
                                        responding: true
                                    )
                                }
                            }
                            NoopButton(
                                "managed.safety.cannot.respond",
                                kind: .tertiary,
                                fullWidth: true
                            ) {
                                Task {
                                    await service.respondToSafetyIncident(
                                        incident.incidentID,
                                        responding: false
                                    )
                                }
                            }
                        }
                        .disabled(service.isBusy)
                    }
                }
            }
        }
    }

    private var durationBinding: Binding<Int> {
        Binding(
            get: { durationHours == 12 ? 12 : 8 },
            set: { durationHours = $0 == 12 ? 12 : 8 }
        )
    }

    private var outboundContacts: [ManagedSafetyContact] {
        (service.safetyContacts?.contacts ?? []).filter {
            $0.role == "contact"
        }
    }

    private var minimumContacts: Int {
        service.safetyContacts?.minimumRequired ?? 2
    }

    private var activeOwnerIncident: ManagedSafetyIncident? {
        service.safetyIncidents.first {
            $0.role == "owner"
                && ($0.status == "open" || $0.status == "acknowledged")
        }
    }

    private var locationReady: Bool {
        locationProvider.state == .ready
            && locationProvider.location?.isUsable(
                atUnix: Int(Date().timeIntervalSince1970)
            ) == true
    }

    private var canStartPage: Bool {
        !service.isBusy
            && outboundContacts.count >= minimumContacts
            && activeOwnerIncident == nil
            && (!shareLocation || locationReady)
    }

    private var contactCountLabel: String {
        localizedFormat(
            "managed.safety.contact.count.format",
            Int64(outboundContacts.count),
            Int64(minimumContacts)
        )
    }

    private var contactsRemainingLabel: String {
        localizedFormat(
            "managed.safety.threshold.remaining.format",
            Int64(max(0, minimumContacts - outboundContacts.count))
        )
    }

    private func requestLabel(_ request: ManagedSafetyRequest) -> String {
        localizedFormat(
            request.direction == "incoming"
                ? "managed.safety.incoming.request.format"
                : "managed.safety.outgoing.request.format",
            request.displayName
        )
    }

    private func lastClosedLabel(
        _ incident: ManagedSafetyIncident
    ) -> String {
        localizedFormat(
            "managed.safety.last.closed.format",
            incidentStatusLabel(incident.status)
        )
    }

    private func incidentTitle(_ incident: ManagedSafetyIncident) -> String {
        guard incident.role != "owner" else {
            return String(localized: "managed.safety.role.owner")
        }
        return localizedFormat(
            "managed.safety.role.contact.format",
            incident.ownerDisplayName
        )
    }

    private func deliveryLabel(_ delivery: ManagedSafetyDelivery) -> String {
        localizedFormat(
            "managed.safety.delivery.format",
            Int64(delivery.contactsReached),
            Int64(delivery.contactsTargeted),
            Int64(delivery.installationsReached),
            Int64(delivery.installationsTargeted)
        )
    }

    private func canRetryPush(for incident: ManagedSafetyIncident) -> Bool {
        guard let delivery = incident.delivery else { return false }
        if let retryable = delivery.installationsRetryable {
            return retryable > 0
        }
        return delivery.installationsReached < delivery.installationsTargeted
    }

    private func participantLabel(
        _ participant: ManagedSafetyParticipant
    ) -> String {
        localizedFormat(
            "managed.safety.participant.status.format",
            participant.displayName,
            participantStatusLabel(participant.status)
        )
    }

    private func incidentStatusLabel(_ status: String) -> String {
        switch status {
        case "open":
            String(localized: "managed.safety.status.active")
        case "acknowledged":
            String(localized: "managed.safety.status.acknowledged")
        case "resolved":
            String(localized: "managed.safety.status.label.resolved")
        case "canceled":
            String(localized: "managed.safety.status.label.canceled")
        case "expired":
            String(localized: "managed.safety.status.label.expired")
        default:
            String(localized: "managed.safety.status.label.unavailable")
        }
    }

    private func participantStatusLabel(_ status: String) -> String {
        switch status {
        case "pending":
            String(localized: "managed.safety.participant.status.pending")
        case "responding":
            String(localized: "managed.safety.participant.status.responding")
        case "cannot_respond":
            String(
                localized: "managed.safety.participant.status.cannot.respond"
            )
        case "revoked":
            String(localized: "managed.safety.participant.status.revoked")
        default:
            String(localized: "managed.safety.participant.status.unavailable")
        }
    }

    private func localizedFormat(
        _ key: String.LocalizationValue,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: String(localized: key),
            locale: .current,
            arguments: arguments
        )
    }

    private func startPage() async {
        guard let incident = await service.createSafetyIncident(
            durationHours: durationHours == 12 ? 12 : 8,
            shareLocation: shareLocation
        ) else {
            return
        }
        if shareLocation {
            await replaceLocation(for: incident)
            locationProvider.requestBackgroundAuthorization()
        }
        await service.refreshSafety()
    }

    private func replaceLocation(
        for incident: ManagedSafetyIncident
    ) async {
        guard let location = locationProvider.location,
              let horizontalAccuracy = location.horizontalAccuracyMeters,
              location.isUsable(
                atUnix: Int(Date().timeIntervalSince1970)
              ) else {
            return
        }
        await service.updateSafetyLocation(
            incidentID: incident.incidentID,
            latitude: location.latitude,
            longitude: location.longitude,
            horizontalAccuracyM: horizontalAccuracy,
            capturedAt: Date(
                timeIntervalSince1970: TimeInterval(
                    location.capturedAtUnix
                )
            )
        )
        await service.refreshSafety()
    }

    private func mapURL(_ location: ManagedSafetyLocation) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(
                name: "ll",
                value: "\(location.latitude),\(location.longitude)"
            ),
        ]
        return components.url
    }
}
#endif
