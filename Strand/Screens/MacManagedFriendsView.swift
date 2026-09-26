#if os(macOS)
import NoopRemoteSync
import StrandDesign
import SwiftUI

struct MacManagedFriendsView: View {
    @ObservedObject var service: MacManagedViewerService
    @EnvironmentObject private var repo: Repository

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        ScreenScaffold(
            title: "Friends",
            subtitle: "Read-only summaries from your NOOP account.",
            onRefresh: {
                if service.phase == .ready {
                    await service.refresh(repo: repo)
                }
            },
            topBackground: liquidScaffoldSky()
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                content

                if !service.status.isEmpty {
                    Text(service.status)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(service.status)
                }
            }
        }
        .task {
            if service.phase != .ready || service.lastUpdatedAt == nil {
                await service.bootstrap(repo: repo)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .unavailable:
            unavailableCard
        case .signedOut:
            signInCard
        case .emailVerificationRequired:
            verificationCard
        case .enrollmentRequired:
            enrollmentCard
        case .ready:
            readyContent
        }
    }

    private var unavailableCard: some View {
        StrandCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    DepthGlyph("person.2.fill", size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Friends is unavailable")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("This build cannot connect to the NOOP account service.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var signInCard: some View {
        StrandCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    DepthGlyph("person.crop.circle.badge.checkmark", size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sign in to NOOP")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Use the verified email and password from your NOOP account. Account creation and band setup stay on the phone.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("NOOP account email")

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("NOOP account password")
                    .onSubmit {
                        signIn()
                    }

                NoopButton(
                    service.isBusy ? "Signing in..." : "Sign in",
                    systemImage: "person.crop.circle.badge.checkmark",
                    kind: .primary,
                    fullWidth: true
                ) {
                    signIn()
                }
                .disabled(
                    service.isBusy
                        || email.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                        || password.isEmpty
                )

                Button("Send password reset") {
                    Task {
                        await service.sendPasswordReset(email: email)
                    }
                }
                .buttonStyle(.plain)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.accentInk)
                .disabled(
                    service.isBusy
                        || email.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
            }
        }
    }

    private var verificationCard: some View {
        StrandCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    DepthGlyph("envelope.badge", size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Verify your email")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Finish email verification from the account message, then return here. This Mac cannot activate or claim a band.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                NoopButton(
                    service.isBusy ? "Checking..." : "Check again",
                    systemImage: "arrow.clockwise",
                    kind: .primary,
                    fullWidth: true
                ) {
                    Task {
                        await service.checkEmailVerification(repo: repo)
                    }
                }
                .disabled(service.isBusy)

                signOutButton
            }
        }
    }

    private var enrollmentCard: some View {
        StrandCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    DepthGlyph("desktopcomputer", size: 52, selected: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect this Mac")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Allow this Mac to read your retained account history and accepted Friends summaries. It cannot collect band data, upload health history, page contacts, poke friends, or change sharing.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !service.maskedEmail.isEmpty {
                    Label(
                        service.maskedEmail,
                        systemImage: "person.crop.circle"
                    )
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                }

                NoopButton(
                    service.isBusy ? "Connecting..." : "Connect read-only",
                    systemImage: "lock.shield",
                    kind: .primary,
                    fullWidth: true
                ) {
                    Task {
                        await service.enroll(repo: repo)
                    }
                }
                .disabled(service.isBusy)

                signOutButton
            }
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        accountCard
        historyCard

        if service.socialProfile == nil {
            phoneSetupCard
        } else {
            pendingRequestsSection
            friendsSection
            recentDaysSection
        }
    }

    private var historyCard: some View {
        StrandCard(padding: 18) {
            HStack(alignment: .center, spacing: 14) {
                DepthGlyph(
                    "arrow.triangle.2.circlepath",
                    size: 46,
                    selected: true
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Account history")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(historyDetail)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                NoopButton(
                    service.isBusy ? "Syncing…" : "Sync now",
                    systemImage: "arrow.triangle.2.circlepath",
                    kind: .secondary
                ) {
                    Task {
                        await service.refresh(repo: repo)
                    }
                }
                .disabled(service.isBusy)
            }
        }
    }

    private var historyDetail: String {
        if service.historyHasMore {
            return String(localized: "History sync")
        }
        if let updated = service.historyLastUpdatedAt {
            return String(localized: "History synced")
                + " "
                + updated.formatted(
                    .relative(
                        presentation: .named,
                        unitsStyle: .abbreviated
                    )
                )
        }
        return String(localized: "History sync")
    }

    private var accountCard: some View {
        StrandCard(padding: 18) {
            HStack(alignment: .center, spacing: 14) {
                MacManagedFriendAvatar(
                    name: service.socialProfile?.displayName ?? "You",
                    size: 48,
                    highlighted: true
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.socialProfile?.displayName ?? "NOOP account")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(accountDetail)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    service.signOut()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .frame(
                            width: NoopMetrics.controlHeight,
                            height: NoopMetrics.controlHeight
                        )
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                .accessibilityLabel("Sign out of NOOP on this Mac")
            }
        }
    }

    private var accountDetail: String {
        var values: [String] = ["Read-only Mac viewer"]
        if let updated = service.lastUpdatedAt {
            values.append(
                "Updated "
                    + updated.formatted(
                        .relative(
                            presentation: .named,
                            unitsStyle: .abbreviated
                        )
                    )
            )
        }
        return values.joined(separator: "  ·  ")
    }

    private var phoneSetupCard: some View {
        StrandCard(padding: 22) {
            HStack(alignment: .top, spacing: 14) {
                DepthGlyph("iphone", size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish Friends on your phone")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Create your private Friends profile and choose sharing from the collector phone. This Mac will then show the accepted summaries.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var pendingRequestsSection: some View {
        let requests = service.socialRequests.filter {
            $0.status == "pending"
        }
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    "Requests",
                    trailing: "\(requests.count) · Phone action"
                )
                ForEach(requests) { request in
                    StrandCard(padding: 16) {
                        HStack(spacing: 12) {
                            MacManagedFriendAvatar(
                                name: request.displayName,
                                size: 44
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.displayName)
                                    .font(StrandFont.headline)
                                    .foregroundStyle(
                                        StrandPalette.textPrimary
                                    )
                                Text(
                                    request.isIncoming
                                        ? "Waiting for your decision on the phone"
                                        : "Waiting for acceptance"
                                )
                                .font(StrandFont.caption)
                                .foregroundStyle(
                                    StrandPalette.textSecondary
                                )
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "iphone")
                                .foregroundStyle(
                                    StrandPalette.textTertiary
                                )
                                .accessibilityLabel(
                                    "Use the phone to manage this request"
                                )
                        }
                    }
                }
            }
        }
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                "Friends",
                trailing: service.socialFriends.isEmpty
                    ? "Private"
                    : "\(service.socialFriends.count)"
            )
            if service.socialFriends.isEmpty {
                StrandCard(padding: 22) {
                    HStack(alignment: .top, spacing: 14) {
                        DepthGlyph(
                            "person.crop.circle.badge.plus",
                            size: 48
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No accepted friends yet")
                                .font(StrandFont.title2)
                                .foregroundStyle(
                                    StrandPalette.textPrimary
                                )
                            Text("Find, invite, accept, and configure sharing from the phone. This Mac stays read-only.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(
                                    StrandPalette.textSecondary
                                )
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                    }
                }
            } else {
                ForEach(service.socialFriends) { friend in
                    MacManagedFriendCard(friend: friend)
                }
            }
        }
    }

    @ViewBuilder
    private var recentDaysSection: some View {
        if !service.socialFeed.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    "Recent shared days",
                    trailing: "Last 7 days"
                )
                StrandCard(padding: 18) {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(service.socialFeed.prefix(14))
                        ) { day in
                            MacManagedFeedRow(day: day)
                            if day.id
                                != service.socialFeed.prefix(14).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var signOutButton: some View {
        Button("Sign out on this Mac") {
            service.signOut()
        }
        .buttonStyle(.plain)
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textSecondary)
        .disabled(service.isBusy)
    }

    private func signIn() {
        Task {
            await service.signIn(
                email: email,
                password: password,
                repo: repo
            )
            password = ""
        }
    }
}

private struct MacManagedFriendCard: View {
    let friend: ManagedSocialFriend
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var visibleBadges: ArraySlice<ManagedSocialBadge> {
        friend.badges.prefix(3)
    }

    private var visibleBadgeTitles: String {
        visibleBadges
            .map { MacManagedSocialFormat.badgeTitle($0.code) }
            .joined(separator: ", ")
    }

    var body: some View {
        StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    MacManagedFriendAvatar(
                        name: friend.displayName,
                        size: 46
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(friend.displayName)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(
                            friend.latest.map {
                                MacManagedSocialFormat.day($0.day)
                            } ?? String(localized: "Waiting for a shared day")
                        )
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Label("Read-only", systemImage: "lock.fill")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                if let summary = friend.latest?.summary {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 8) {
                            summaryTiles(summary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            summaryTiles(summary)
                        }
                    }
                    let details = MacManagedSocialFormat.details(summary)
                    if !details.isEmpty {
                        Text(details.joined(separator: "  ·  "))
                            .font(StrandFont.caption)
                            .foregroundStyle(
                                StrandPalette.textSecondary
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                } else {
                    Text("Shared details appear only when this friend allows them.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                if !friend.badges.isEmpty {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) {
                                badgeLabels
                            }
                        } else {
                            HStack(spacing: 8) {
                                badgeLabels
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Wellness badges")
                    .accessibilityValue(visibleBadgeTitles)
                }
            }
        }
    }

    @ViewBuilder
    private func summaryTiles(_ summary: ManagedSocialSummary) -> some View {
        MacManagedMetricTile(
            label: "Recovery",
            value: summary.charge,
            color: StrandPalette.chargeColor
        )
        MacManagedMetricTile(
            label: "Effort",
            value: summary.effort,
            color: StrandPalette.effortColor
        )
        MacManagedMetricTile(
            label: "Sleep Score",
            value: summary.rest,
            color: StrandPalette.restColor
        )
    }

    @ViewBuilder
    private var badgeLabels: some View {
        ForEach(visibleBadges) { badge in
            Label(
                MacManagedSocialFormat.badgeTitle(badge.code),
                systemImage: MacManagedSocialFormat.badgeSymbol(badge.code)
            )
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(StrandPalette.surfaceInset, in: Capsule())
        }
    }
}

private struct MacManagedMetricTile: View {
    let label: LocalizedStringKey
    let value: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(StrandFont.metricLabel)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(2)
            Text(
                value.map { String(Int($0.rounded())) }
                    ?? StrandFormat.missing
            )
            .font(StrandFont.metricValue)
            .foregroundStyle(
                value == nil ? StrandPalette.textTertiary : color
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            StrandPalette.surfaceInset,
            in: RoundedRectangle(
                cornerRadius: NoopMetrics.cardRadius,
                style: .continuous
            )
        )
    }
}

private struct MacManagedFeedRow: View {
    let day: ManagedSocialFeedDay

    var body: some View {
        HStack(spacing: 12) {
            MacManagedFriendAvatar(name: day.displayName, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(day.displayName)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(MacManagedSocialFormat.day(day.day))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 12)
            Text(
                MacManagedSocialFormat.compact(day.summary)
                    .joined(separator: "  ·  ")
            )
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct MacManagedFriendAvatar: View {
    let name: String
    let size: CGFloat
    var highlighted = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    highlighted
                        ? StrandPalette.accent.opacity(0.22)
                        : StrandPalette.surfaceInset
                )
            Text(initials)
                .font(
                    StrandFont.rounded(
                        size * 0.30,
                        weight: .bold
                    )
                )
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(
                highlighted
                    ? StrandPalette.accent
                    : StrandPalette.hairlineStrong,
                lineWidth: 1
            )
        )
        .accessibilityHidden(true)
    }

    private var initials: String {
        let value = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return value.isEmpty ? "?" : value.uppercased()
    }
}

private enum MacManagedSocialFormat {
    static func day(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return raw }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func compact(_ summary: ManagedSocialSummary) -> [String] {
        var result: [String] = []
        if let recovery = summary.charge {
            result.append("Recovery \(Int(recovery.rounded()))")
        }
        if let effort = summary.effort {
            result.append("Effort \(Int(effort.rounded()))")
        }
        if let sleepScore = summary.rest {
            result.append("Sleep \(Int(sleepScore.rounded()))")
        }
        return result.isEmpty ? [StrandFormat.missing] : result
    }

    static func details(_ summary: ManagedSocialSummary) -> [String] {
        var result: [String] = []
        if let sleep = summary.sleepDuration {
            let total = Int(sleep.rounded())
            result.append("Sleep \(total / 60)h \(total % 60)m")
        }
        if let hrv = summary.hrv {
            result.append("HRV \(Int(hrv.rounded())) ms")
        }
        if let rhr = summary.rhr {
            result.append("Resting HR \(Int(rhr.rounded())) bpm")
        }
        return result
    }

    static func badgeTitle(_ code: String) -> String {
        switch code {
        case "connected": return String(localized: "Connected")
        case "steady_week": return String(localized: "7 shared days")
        case "steady_month": return String(localized: "30 shared days")
        default: return String(localized: "Milestone")
        }
    }

    static func badgeSymbol(_ code: String) -> String {
        switch code {
        case "connected": return "person.2.fill"
        case "steady_week": return "calendar.badge.checkmark"
        case "steady_month": return "calendar.circle.fill"
        default: return "sparkles"
        }
    }
}
#endif
