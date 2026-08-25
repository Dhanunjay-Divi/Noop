import NoopRemoteSync
import StrandAnalytics
import StrandDesign
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SafetyIncidentContactPresentation {
    struct Receipt: Equatable {
        let reached: Int
        let targeted: Int
    }

    static func receipt(reached: Int, targeted: Int) -> Receipt? {
        guard targeted > 0, reached >= 0, reached <= targeted else { return nil }
        return Receipt(reached: reached, targeted: targeted)
    }

    static func lastReachedDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    static func shouldShowAllContactsFailed(
        status: RemoteSafetyIncidentStatus,
        summaryReportsAllFailed: Bool?
    ) -> Bool {
        status == .failed || summaryReportsAllFailed == true
    }

    static func allowsResolveOrCancel(_ status: RemoteSafetyIncidentStatus) -> Bool {
        [.open, .acknowledged, .pending].contains(status)
    }

    static func tone(for status: RemoteSafetyIncidentStatus) -> StrandTone {
        switch status {
        case .open, .pending, .submitted: return .warning
        case .acknowledged, .resolved: return .positive
        case .failed, .partialFailure: return .critical
        case .cancelled, .expired: return .neutral
        }
    }

    static func telephoneURL(phoneE164: String) -> URL? {
        guard phoneE164.first == "+" else { return nil }
        let digits = phoneE164.dropFirst()
        guard (8...15).contains(digits.count),
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              digits.first != "0"
        else { return nil }
        return URL(string: "tel:\(phoneE164)")
    }
}

/// Personal-safety tools: explicitly page accepted contacts, prepare a message with an optional
/// one-shot location, and arm a local check-in reminder. Wellness signals never silently page anyone.
struct SafetyCenterView: View {
    @Environment(\.openURL) private var openURL

    private enum IncidentAction: Equatable {
        case resolve
        case cancel
    }

    private enum CheckInPreset: Int, CaseIterable, Identifiable {
        case fifteenMinutes = 900
        case thirtyMinutes = 1_800
        case oneHour = 3_600
        case twoHours = 7_200

        var id: Int { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .fifteenMinutes: return "safety.duration.15_minutes"
            case .thirtyMinutes: return "safety.duration.30_minutes"
            case .oneHour: return "safety.duration.1_hour"
            case .twoHours: return "safety.duration.2_hours"
            }
        }
    }

    @StateObject private var locationProvider = SafetyLocationProvider()
    @StateObject private var pagingService = SafetyPagingService()
    @AppStorage("safety.checkInDueAtUnix") private var checkInDueAtUnix = 0.0
    @AppStorage(SafetySOSGesturePreferences.enabledKey) private var sosGestureEnabled = false
    @AppStorage(SafetySOSGesturePreferences.requiredEventsKey) private var sosGestureEvents = 4

    @State private var shareIntent: SafetyShareIntent = .feelUnsafe
    @State private var displayName = ""
    @State private var note = ""
    @State private var detailsExpanded = false
    @State private var includeLocation = true
    @State private var preset: CheckInPreset = .thirtyMinutes
    @State private var scheduling = false
    @State private var notice: String?
    @State private var nowUnix = Int(Date().timeIntervalSince1970)
    @State private var reminderDeliveryState: SafetyCheckInNotifications.DeliveryState = .unknown
    @State private var sosNotificationsAvailable = true
    @State private var confirmsContactPage = false
    @State private var pendingIncidentAction: IncidentAction?

    var body: some View {
        ScreenScaffold(
            title: "safety.title",
            subtitle: "safety.subtitle"
        ) {
            emergencyBoundary
            fallResponseReadiness
            emergencyContactsSection
            contactPageSection
            shareSection
            checkInSection
            privacyBoundary
        }
        .alert("safety.reminder.alert_title", isPresented: noticeBinding) {
            Button("safety.ok", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        .task {
            #if os(iOS)
            sosNotificationsAvailable =
                await SafetySOSRuntime.notificationDeliveryAvailable()
            #endif
            while !Task.isCancelled {
                nowUnix = Int(Date().timeIntervalSince1970)
                await pagingService.refreshLatestIncident()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .task(id: checkInDueAtUnix) {
            await refreshReminderDeliveryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: appDidBecomeActiveNotification)) { _ in
            nowUnix = Int(Date().timeIntervalSince1970)
            Task {
                await refreshReminderDeliveryState()
                #if os(iOS)
                sosNotificationsAvailable =
                    await SafetySOSRuntime.notificationDeliveryAvailable()
                #endif
                await pagingService.refresh()
            }
        }
        .confirmationDialog(
            "safety.page.confirm.title",
            isPresented: $confirmsContactPage,
            titleVisibility: .visible
        ) {
            Button("safety.page.confirm.action", role: .destructive) {
                Task { _ = await pagingService.pageAcceptedContacts() }
            }
            Button("safety.cancel", role: .cancel) {}
        } message: {
            Text("safety.page.confirm.body")
        }
        .confirmationDialog(
            "safety.page.update.title",
            isPresented: incidentActionBinding,
            titleVisibility: .visible
        ) {
            switch pendingIncidentAction {
            case .resolve:
                Button("safety.page.resolve.action") {
                    guard let incident = pagingService.lastDispatch else { return }
                    pendingIncidentAction = nil
                    Task { await pagingService.resolve(incident) }
                }
            case .cancel:
                Button("safety.page.cancel.action", role: .destructive) {
                    guard let incident = pagingService.lastDispatch else { return }
                    pendingIncidentAction = nil
                    Task { await pagingService.cancel(incident) }
                }
            case nil:
                EmptyView()
            }
            Button("safety.page.keep_open", role: .cancel) {
                pendingIncidentAction = nil
            }
        } message: {
            Text(
                pendingIncidentAction == .resolve
                    ? String(localized: "safety.page.resolve.guidance")
                    : String(localized: "safety.page.cancel.guidance")
            )
        }
    }

    private var emergencyBoundary: some View {
        NoopCard(tint: StrandPalette.statusCritical) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(StrandPalette.statusCriticalText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("safety.emergency.title")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("safety.emergency.body")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var emergencyContactsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("safety.contacts.section", overline: "safety.network.overline")
            NoopCard {
                SafetyContactsSetupView(service: pagingService)
            }
        }
    }

    private var fallResponseReadiness: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("safety.fall.section", overline: "safety.fall.overline")
            NoopCard(tint: StrandPalette.statusWarning) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(alignment: .top, spacing: NoopMetrics.space3) {
                        Image(systemName: "figure.fall")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                                Text("safety.fall.title")
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer(minLength: 8)
                                StatePill("safety.fall.status", tone: .warning)
                            }
                            Text(
                                String(
                                    format: String(localized: "safety.fall.body_format"),
                                    Int64(FallResponsePolicy.responseWindowSeconds)
                                )
                            )
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("safety.fall.requirements")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var contactPageSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("safety.page.section", overline: "SOS")
            NoopCard(tint: StrandPalette.statusCritical) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(alignment: .top, spacing: NoopMetrics.space3) {
                        Image(systemName: "phone.arrow.up.right.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(StrandPalette.statusCriticalText)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("safety.page.title")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("safety.page.body")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    NoopButton(
                        "safety.page.submit",
                        systemImage: "sos",
                        kind: .destructive,
                        fullWidth: true
                    ) {
                        confirmsContactPage = true
                    }
                    .disabled(!pagingService.canPage)

                    if !pagingService.canPage {
                        Text(pageDisabledReason)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let incident = pagingService.lastDispatch {
                        incidentStatus(incident)
                    }

                    Divider().overlay(StrandPalette.hairline)
                    sosGestureControls

                    Text("safety.page.disclaimer")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sosGestureControls: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Toggle(isOn: $sosGestureEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("safety.sos.gesture.title")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("safety.sos.gesture.subtitle")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .tint(StrandPalette.statusCritical)

            if sosGestureEnabled {
                Picker("safety.sos.gesture.repeats", selection: sosGestureEventsBinding) {
                    Text("safety.sos.gesture.three").tag(3)
                    Text("safety.sos.gesture.four").tag(4)
                }
                .pickerStyle(.segmented)

                Text(
                    String(
                        format: String(localized: "safety.sos.gesture.help_format"),
                        Int64(sosGestureEvents)
                    )
                )
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Label(
                    "safety.sos.gesture.priority",
                    systemImage: "hand.tap.fill"
                )
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                #if os(iOS)
                HStack(alignment: .top, spacing: NoopMetrics.space2) {
                    Image(
                        systemName: sosNotificationsAvailable
                            ? "bell.badge.fill"
                            : "bell.slash.fill"
                    )
                    .foregroundStyle(
                        sosNotificationsAvailable
                            ? StrandPalette.statusPositive
                            : StrandPalette.statusWarning
                    )
                    .accessibilityHidden(true)
                    Text(
                        sosNotificationsAvailable
                            ? String(localized: "safety.sos.notifications.ready")
                            : String(localized: "safety.sos.notifications.off")
                    )
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !sosNotificationsAvailable {
                    NoopButton(
                        "safety.settings.open_notifications",
                        systemImage: "gearshape",
                        kind: .secondary,
                        fullWidth: true,
                        action: openAppSettings
                    )
                }
                liveLocationPermissionControl
                #endif
            }
        }
        .onChangeCompat(of: sosGestureEnabled) { enabled in
            SafetySOSGesturePreferences.setEnabled(enabled)
            #if os(iOS)
            guard enabled else { return }
            Task { @MainActor in
                sosNotificationsAvailable =
                    await SafetySOSRuntime.requestNotificationAuthorizationIfNeeded()
            }
            #endif
        }
    }

    private var sosGestureEventsBinding: Binding<Int> {
        Binding(
            get: { min(max(sosGestureEvents, 3), 4) },
            set: {
                sosGestureEvents = min(max($0, 3), 4)
                SafetySOSGesturePreferences.setRequiredEvents($0)
            }
        )
    }

    #if os(iOS)
    @ViewBuilder private var liveLocationPermissionControl: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "location.fill")
                    .foregroundStyle(
                        locationProvider.hasBackgroundAuthorization
                            ? StrandPalette.statusPositive
                            : StrandPalette.statusWarning
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("safety.sos.location.title")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(
                        locationProvider.hasBackgroundAuthorization
                            ? String(localized: "safety.sos.location.ready")
                            : String(localized: "safety.sos.location.permission")
                    )
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            if !locationProvider.hasBackgroundAuthorization {
                if [.denied, .restricted].contains(locationProvider.authorizationStatus) {
                    NoopButton(
                        "safety.sos.location.settings",
                        systemImage: "gearshape",
                        kind: .secondary,
                        fullWidth: true,
                        action: openAppSettings
                    )
                } else {
                    NoopButton(
                        "safety.sos.location.enable",
                        systemImage: "location.fill",
                        kind: .secondary,
                        fullWidth: true,
                        action: locationProvider.requestBackgroundAuthorization
                    )
                }
            }

            Text(
                "safety.sos.location.retention"
            )
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif

    private var pageDisabledReason: String {
        if pagingService.setupState != .ready {
            return String(localized: "safety.page.disabled.setup")
        }
        if !pagingService.pagingConfigured || pagingService.pagingEnabled == false {
            return String(localized: "safety.page.disabled.delivery")
        }
        if pagingService.activeIncident != nil {
            return String(localized: "safety.page.disabled.active")
        }
        return String(localized: "safety.page.disabled.contacts")
    }

    private func incidentStatus(_ incident: RemoteSafetyDispatch) -> some View {
        let contactSummary = incident.contactSummary.flatMap {
            $0.isConsistent ? $0 : nil
        }
        let contactReceipt = contactSummary.flatMap {
            SafetyIncidentContactPresentation.receipt(
                reached: $0.reached,
                targeted: $0.targeted
            )
        }
        let allContactsFailed =
            SafetyIncidentContactPresentation.shouldShowAllContactsFailed(
                status: incident.status,
                summaryReportsAllFailed: contactSummary?.allContactsFailed
            )

        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: NoopMetrics.space2) {
                StatePill(
                    incidentStatusLabel(incident.status),
                    tone: SafetyIncidentContactPresentation.tone(
                        for: incident.status
                    )
                )
                Spacer(minLength: 8)
                if incident.idempotentReplay {
                    Text("safety.page.safe_retry")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            if !allContactsFailed {
                Text(incidentStatusDetail(incident))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let contactReceipt {
                Label {
                    Text(contactReceiptText(
                        contactReceipt,
                        lastReachedAt: contactSummary?.lastReachedAt
                    ))
                } icon: {
                    Image(systemName: "person.2.fill")
                        .accessibilityHidden(true)
                }
                .font(StrandFont.captionNumber)
                .foregroundStyle(
                    allContactsFailed
                        ? StrandPalette.statusCriticalText
                        : (contactReceipt.reached > 0
                           ? StrandPalette.statusPositive
                           : StrandPalette.textTertiary)
                )
                .accessibilityElement(children: .combine)
            } else {
                let submitted = incident.deliveries.filter {
                    [.queued, .sent, .delivered].contains($0.status)
                }.count
                let inProgress = incident.deliveries.filter {
                    [.pending, .submitting, .leased, .retryWait].contains($0.status)
                }.count
                let failed = incident.deliveries.filter {
                    [.failed, .unknown].contains($0.status)
                }.count
                Text(
                    String(
                        format: String(localized: "safety.page.delivery_counts_format"),
                        submitted,
                        inProgress,
                        failed
                    )
                )
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(failed == 0
                                     ? StrandPalette.textTertiary
                                     : StrandPalette.statusWarning)
            }

            if allContactsFailed {
                allContactsFailedWarning
            }

            if let responses = incident.responses, !responses.isEmpty {
                Text("safety.page.contact_responses")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)

                ForEach(responses) { response in
                    HStack(spacing: NoopMetrics.space2) {
                        Image(
                            systemName: response.decision == .responding
                                ? "checkmark.circle.fill"
                                : "xmark.circle"
                        )
                        .foregroundStyle(
                            response.decision == .responding
                                ? StrandPalette.statusPositive
                                : StrandPalette.textTertiary
                        )
                        Text(
                            response.decision == .responding
                                ? String(
                                    format: String(localized: "safety.page.responding_format"),
                                    response.contactDisplayName
                                )
                                : String(
                                    format: String(localized: "safety.page.cannot_respond_format"),
                                    response.contactDisplayName
                                )
                        )
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if let location = incident.latestLocation {
                Divider().overlay(StrandPalette.hairline)
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(StrandPalette.statusPositive)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("safety.sos.location.latest")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let accuracy = location.horizontalAccuracyMeters {
                            Text(
                                String(
                                    format: String(
                                        localized: "safety.sos.location.accuracy_format"
                                    ),
                                    Int64(accuracy.rounded())
                                )
                            )
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Spacer(minLength: 8)
                }
                NoopButton(
                    "safety.sos.location.open_maps",
                    systemImage: "map.fill",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    guard let url = URL(
                        string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)"
                    ) else { return }
                    openURL(url)
                }
            }

            if SafetyIncidentContactPresentation.allowsResolveOrCancel(incident.status) {
                NoopButton(
                    "safety.page.resolve.action",
                    systemImage: "checkmark.circle.fill",
                    kind: .primary,
                    fullWidth: true
                ) {
                    pendingIncidentAction = .resolve
                }
                .disabled(pagingService.isBusy)

                NoopButton(
                    "safety.page.cancel.action",
                    systemImage: "xmark.circle",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    pendingIncidentAction = .cancel
                }
                .disabled(pagingService.isBusy)
            }
        }
    }

    private func contactReceiptText(
        _ receipt: SafetyIncidentContactPresentation.Receipt,
        lastReachedAt: String?
    ) -> String {
        if let date = SafetyIncidentContactPresentation.lastReachedDate(lastReachedAt) {
            return String(
                format: String(localized: "safety.page.contacts_reached_at_format"),
                locale: Locale.current,
                arguments: [
                    Int64(receipt.reached),
                    Int64(receipt.targeted),
                    date.formatted(date: .omitted, time: .shortened),
                ]
            )
        }
        return String(
            format: String(localized: "safety.page.contacts_reached_format"),
            locale: Locale.current,
            arguments: [Int64(receipt.reached), Int64(receipt.targeted)]
        )
    }

    private var allContactsFailedWarning: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(StrandPalette.statusCriticalText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text(
                        String(
                            localized: "safety.page.all_contacts_failed_title"
                        )
                    )
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("safety.page.detail.failed")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(directlyCallableContacts) { contact in
                if let url = SafetyIncidentContactPresentation.telephoneURL(
                    phoneE164: contact.phoneE164
                ) {
                    Button {
                        openURL(url)
                    } label: {
                        Label {
                            Text(
                                String(
                                    format: String(
                                        localized: "safety.page.call_contact_format"
                                    ),
                                    contact.displayName
                                )
                            )
                        } icon: {
                            Image(systemName: "phone.fill")
                        }
                    }
                    .buttonStyle(NoopButtonStyle(.destructive, fullWidth: true))
                }
            }
        }
        .padding(.leading, NoopMetrics.space3)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(StrandPalette.statusCritical)
                .frame(width: 3)
                .accessibilityHidden(true)
        }
    }

    private var directlyCallableContacts: [RemoteSafetyContact] {
        pagingService.contacts.filter {
            $0.status == .accepted
                && SafetyIncidentContactPresentation.telephoneURL(
                    phoneE164: $0.phoneE164
                ) != nil
        }
    }

    private func incidentStatusLabel(
        _ status: RemoteSafetyIncidentStatus
    ) -> LocalizedStringKey {
        switch status {
        case .open, .pending: return "safety.page.status.open"
        case .acknowledged: return "safety.page.status.acknowledged"
        case .resolved: return "safety.page.status.resolved"
        case .cancelled: return "safety.page.status.cancelled"
        case .expired: return "safety.page.status.expired"
        case .submitted: return "safety.page.status.submitted"
        case .partialFailure: return "safety.page.status.partial_failure"
        case .failed: return "safety.page.status.failed"
        }
    }

    private func incidentStatusDetail(_ incident: RemoteSafetyDispatch) -> String {
        switch incident.status {
        case .open, .pending:
            return String(localized: "safety.page.detail.waiting")
        case .acknowledged:
            if let name = incident.acknowledgedContactDisplayName {
                return String(
                    format: String(localized: "safety.page.detail.acknowledged_format"),
                    name
                )
            }
            return String(localized: "safety.page.detail.acknowledged")
        case .resolved:
            return String(localized: "safety.page.detail.resolved")
        case .cancelled:
            return String(localized: "safety.page.detail.cancelled")
        case .expired:
            return String(localized: "safety.page.detail.expired")
        case .submitted:
            return String(localized: "safety.page.detail.submitted")
        case .partialFailure:
            return String(localized: "safety.page.detail.partial_failure")
        case .failed:
            return String(localized: "safety.page.detail.failed")
        }
    }

    private var incidentActionBinding: Binding<Bool> {
        Binding(
            get: { pendingIncidentAction != nil },
            set: { if !$0 { pendingIncidentAction = nil } }
        )
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("safety.share.title", overline: "safety.share.overline")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Picker("safety.message.purpose", selection: $shareIntent) {
                        Text("safety.intent.feel_unsafe").tag(SafetyShareIntent.feelUnsafe)
                        Text("safety.intent.need_help_now").tag(SafetyShareIntent.needHelpNow)
                        Text("safety.intent.missed_check_in").tag(SafetyShareIntent.missedCheckIn)
                    }
                    .pickerStyle(.menu)

                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { detailsExpanded.toggle() }
                    } label: {
                        HStack(spacing: NoopMetrics.space2) {
                            Image(systemName: "square.and.pencil")
                                .accessibilityHidden(true)
                            Text(detailsButtonTitle)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .rotationEffect(.degrees(detailsExpanded ? 0 : -90))
                                .accessibilityHidden(true)
                        }
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: NoopMetrics.controlHeight,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(detailsButtonHint)

                    if detailsExpanded {
                        TextField("safety.name.optional", text: $displayName)
                            .textFieldStyle(.roundedBorder)

                        TextField("safety.note.optional", text: $note, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                    }

                    Toggle(isOn: $includeLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("safety.location.include")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("safety.location.one_shot")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }

                    if includeLocation {
                        locationControl
                        if !locationIsReady {
                            Text("safety.location.required")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.statusWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ShareLink(
                        item: preparedMessage,
                        subject: Text("safety.share.subject"),
                        message: Text("safety.share.review_prompt")
                    ) {
                        Label("safety.share.button", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                    .disabled(!canSharePreparedMessage)
                    .accessibilityHint(shareAccessibilityHint)

                    Text("safety.share.disclaimer")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var locationControl: some View {
        switch locationProvider.state {
        case .idle:
            NoopButton(
                "safety.location.get",
                systemImage: "location.fill",
                kind: .secondary,
                fullWidth: true,
                action: locationProvider.requestCurrentLocation
            )
        case .requesting:
            HStack(spacing: NoopMetrics.space2) {
                ProgressView()
                Text("safety.location.getting")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: NoopMetrics.controlHeight, alignment: .center)
            .accessibilityElement(children: .combine)
        case .ready:
            if locationIsReady {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(spacing: NoopMetrics.space2) {
                        StatePill("safety.location.ready", tone: .positive)
                        Spacer(minLength: 8)
                        Button("safety.refresh") { locationProvider.requestCurrentLocation() }
                            .buttonStyle(.borderless)
                            .frame(minWidth: NoopMetrics.controlHeight, minHeight: NoopMetrics.controlHeight)
                    }
                    if let location = locationProvider.location {
                        Text(locationDetail(location))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    inlineLocationState(
                        "safety.location.expired",
                        tone: .warning
                    )
                    NoopButton(
                        "safety.location.refresh",
                        systemImage: "arrow.clockwise",
                        kind: .secondary,
                        fullWidth: true,
                        action: locationProvider.requestCurrentLocation
                    )
                }
            }
        case .denied:
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                inlineLocationState(
                    "safety.location.permission_off",
                    tone: .warning
                )
                #if os(iOS)
                NoopButton(
                    "safety.settings.open_app",
                    systemImage: "gearshape",
                    kind: .secondary,
                    fullWidth: true,
                    action: openAppSettings
                )
                #endif
            }
        case .unavailable:
            inlineLocationState("safety.location.unavailable", tone: .warning)
        case .failed:
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                inlineLocationState("safety.location.failed", tone: .warning)
                NoopButton(
                    "safety.location.retry",
                    systemImage: "arrow.clockwise",
                    kind: .secondary,
                    fullWidth: true,
                    action: locationProvider.requestCurrentLocation
                )
            }
        }
    }

    private func inlineLocationState(_ text: LocalizedStringKey, tone: StrandTone) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space2) {
            Image(systemName: "location.slash.fill")
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var checkInSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionHeader("safety.timer.title", overline: "safety.timer.overline")
            NoopCard {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    checkInContent(now: context.date)
                }
            }
        }
    }

    @ViewBuilder private func checkInContent(now: Date) -> some View {
        let state = SafetyCheckInPolicy.state(
            dueAtUnix: checkInDueAtUnix > 0 ? Int(checkInDueAtUnix) : nil,
            nowUnix: Int(now.timeIntervalSince1970)
        )

        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            switch state {
            case .inactive:
                StatePill("safety.timer.none", tone: .neutral, showsDot: false)
            case .active:
                StatePill("safety.timer.active", tone: .positive)
            case .dueSoon:
                StatePill("safety.timer.due_soon", tone: .warning)
            case .overdue:
                StatePill("safety.timer.overdue", tone: .critical)
            }

            Text(timerStatusLabel(state))
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if checkInDueAtUnix > 0 {
                Text(scheduledDateLabel)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }

            if checkInDueAtUnix > now.timeIntervalSince1970 {
                reminderDeliveryStatus
            }

            switch state {
            case .inactive:
                Picker("safety.timer.length", selection: $preset) {
                    ForEach(CheckInPreset.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                NoopButton(
                    startTimerButtonTitle,
                    systemImage: "timer",
                    kind: .primary,
                    fullWidth: true,
                    action: startCheckIn
                )
                .disabled(scheduling)
            case .active, .dueSoon, .overdue:
                NoopButton(
                    "safety.timer.end",
                    systemImage: "checkmark.circle.fill",
                    kind: .primary,
                    fullWidth: true,
                    action: endCheckIn
                )
            }

            Text("safety.timer.disclaimer")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyBoundary: some View {
        NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("safety.privacy.title")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("safety.privacy.body")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var preparedMessage: String {
        SafetyShareMessage.build(
            intent: shareIntent,
            displayName: displayName,
            note: note,
            location: includeLocation ? locationProvider.location : nil,
            preparedAtUnix: Int(Date().timeIntervalSince1970),
            copy: localizedSafetyShareCopy
        )
    }

    private var locationIsReady: Bool {
        locationProvider.state == .ready
            && locationProvider.location?.isUsable(atUnix: nowUnix) == true
    }

    private var canSharePreparedMessage: Bool {
        !includeLocation || locationIsReady
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )
    }

    private func startCheckIn() {
        guard !scheduling else { return }
        scheduling = true
        Task { @MainActor in
            defer { scheduling = false }
            let nowUnix = Int(Date().timeIntervalSince1970)
            guard let dueUnix = SafetyCheckInPolicy.dueAtUnix(
                startedAtUnix: nowUnix,
                requestedDurationSeconds: preset.rawValue
            ) else {
                notice = String(localized: "safety.error.create")
                return
            }

            switch await SafetyCheckInNotifications.schedule(
                dueAt: Date(timeIntervalSince1970: TimeInterval(dueUnix))
            ) {
            case .scheduled:
                checkInDueAtUnix = Double(dueUnix)
                reminderDeliveryState = .scheduled
            case .denied:
                reminderDeliveryState = .notificationsOff
                notice = String(localized: "safety.error.notifications_start")
            case .failed:
                reminderDeliveryState = .requestMissing
                notice = String(localized: "safety.error.schedule")
            }
        }
    }

    private func endCheckIn() {
        checkInDueAtUnix = 0
        reminderDeliveryState = .notApplicable
        SafetyCheckInNotifications.cancel()
    }

    @ViewBuilder private var reminderDeliveryStatus: some View {
        switch reminderDeliveryState {
        case .unknown:
            EmptyView()
        case .scheduled:
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(StrandPalette.statusPositive)
                    .accessibilityHidden(true)
                Text("safety.reminder.scheduled")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case .notificationsOff:
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                inlineReminderWarning(
                    "safety.reminder.notifications_off"
                )
                #if os(iOS)
                NoopButton(
                    "safety.settings.open_notifications",
                    systemImage: "bell.badge",
                    kind: .secondary,
                    fullWidth: true,
                    action: openAppSettings
                )
                #endif
            }
        case .requestMissing:
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                inlineReminderWarning(
                    "safety.reminder.missing"
                )
                NoopButton(
                    repairButtonTitle,
                    systemImage: "arrow.clockwise",
                    kind: .secondary,
                    fullWidth: true,
                    action: repairCheckIn
                )
                .disabled(scheduling)
            }
        case .notApplicable:
            EmptyView()
        }
    }

    private func inlineReminderWarning(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space2) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func locationDetail(_ location: SafetyLocation) -> String {
        let captured = Date(timeIntervalSince1970: TimeInterval(location.capturedAtUnix))
            .formatted(date: .omitted, time: .shortened)
        guard let accuracy = location.horizontalAccuracyMeters,
              accuracy.isFinite, accuracy >= 0
        else {
            return String(
                format: String(localized: "safety.location.captured_format"),
                locale: Locale.current,
                arguments: [captured]
            )
        }
        return String(
            format: String(localized: "safety.location.accuracy_format"),
            locale: Locale.current,
            arguments: [captured, Int64(accuracy.rounded())]
        )
    }

    private func refreshReminderDeliveryState() async {
        let dueAt = checkInDueAtUnix > 0
            ? Date(timeIntervalSince1970: checkInDueAtUnix)
            : nil
        reminderDeliveryState = await SafetyCheckInNotifications.deliveryState(dueAt: dueAt)
    }

    private func repairCheckIn() {
        guard !scheduling, checkInDueAtUnix > Date().timeIntervalSince1970 else { return }
        scheduling = true
        Task { @MainActor in
            defer { scheduling = false }
            switch await SafetyCheckInNotifications.schedule(
                dueAt: Date(timeIntervalSince1970: checkInDueAtUnix)
            ) {
            case .scheduled:
                reminderDeliveryState = .scheduled
            case .denied:
                reminderDeliveryState = .notificationsOff
                notice = String(localized: "safety.error.notifications_repair")
            case .failed:
                reminderDeliveryState = .requestMissing
                notice = String(localized: "safety.error.repair")
            }
        }
    }

    private var detailsButtonTitle: LocalizedStringKey {
        detailsExpanded ? "safety.details.hide" : "safety.details.add"
    }

    private var detailsButtonHint: LocalizedStringKey {
        detailsExpanded ? "safety.details.hide_hint" : "safety.details.show_hint"
    }

    private var shareAccessibilityHint: LocalizedStringKey {
        canSharePreparedMessage ? "safety.share.review_prompt" : "safety.location.required"
    }

    private var startTimerButtonTitle: LocalizedStringKey {
        scheduling ? "safety.timer.starting" : "safety.timer.start"
    }

    private var repairButtonTitle: LocalizedStringKey {
        scheduling ? "safety.reminder.repairing" : "safety.reminder.repair"
    }

    private var scheduledDateLabel: String {
        let date = Date(timeIntervalSince1970: checkInDueAtUnix)
            .formatted(date: .abbreviated, time: .shortened)
        return String(
            format: String(localized: "safety.timer.scheduled_format"),
            locale: Locale.current,
            arguments: [date]
        )
    }

    private func timerStatusLabel(_ state: SafetyCheckInState) -> String {
        switch state {
        case .inactive:
            return String(localized: "safety.timer.status.inactive")
        case let .active(remainingSeconds):
            return String(
                format: String(localized: "safety.timer.status.active_format"),
                locale: Locale.current,
                arguments: [localizedDuration(remainingSeconds)]
            )
        case let .dueSoon(remainingSeconds):
            return String(
                format: String(localized: "safety.timer.status.due_soon_format"),
                locale: Locale.current,
                arguments: [localizedDuration(remainingSeconds)]
            )
        case let .overdue(elapsedSeconds):
            return String(
                format: String(localized: "safety.timer.status.overdue_format"),
                locale: Locale.current,
                arguments: [localizedDuration(elapsedSeconds)]
            )
        }
    }

    private func localizedDuration(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        formatter.allowedUnits = safe < 60
            ? [.second]
            : (safe < 3_600 ? [.minute] : [.hour, .minute])
        return formatter.string(from: TimeInterval(safe)) ?? "\(safe)"
    }

    private var localizedSafetyShareCopy: SafetyShareCopy {
        SafetyShareCopy(
            needHelpNowOpening: String(localized: "safety.message.need_help_opening"),
            feelUnsafeOpening: String(localized: "safety.message.feel_unsafe_opening"),
            missedCheckInOpening: String(localized: "safety.message.missed_opening"),
            immediateDangerInstruction: String(localized: "safety.message.immediate_danger"),
            locationLabel: String(localized: "safety.message.location_label"),
            locationCapturedFormat: String(localized: "safety.message.location_captured_format"),
            locationCapturedAccuracyFormat:
                String(localized: "safety.message.location_accuracy_format"),
            noteLabel: String(localized: "safety.message.note_label"),
            preparedAtFormat: String(localized: "safety.message.prepared_at_format"),
            deliveryBoundary: String(localized: "safety.message.delivery_boundary")
        )
    }

    #if os(iOS)
    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}

#if os(iOS)
private let appDidBecomeActiveNotification = UIApplication.didBecomeActiveNotification
#elseif os(macOS)
private let appDidBecomeActiveNotification = NSApplication.didBecomeActiveNotification
#endif

#if DEBUG
#Preview("Safety Center") {
    SafetyCenterView()
        .frame(minWidth: 390, minHeight: 800)
}
#endif
