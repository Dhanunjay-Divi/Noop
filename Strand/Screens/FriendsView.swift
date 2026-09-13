import SwiftUI
import StrandDesign

/// Plain-text invitation copy is shared with tests because recipients must be sent to the stable
/// Friends entry point. Keeping this outside the sheet prevents navigation changes from leaving stale setup
/// instructions in messages that have already left the sender's phone.
enum FriendsNavigationCopy {
    static let invitationInstruction =
        "In Noop, open More → Friends → Enter invite details. Sharing starts only after I accept your request."
}

/// Private, mutual score sharing through a server the circle operates.
///
/// This is intentionally a circle, not a leaderboard: friends see only the fields each relationship
/// allows, there is no discovery/search, and no raw biometric or location surface exists here.
struct FriendsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var service = FriendsService()

    #if os(iOS)
    @ObservedObject private var managedService = ManagedCloudService.shared
    @AppStorage("friends.source.v1")
    private var selectedSource = FriendsSource.managed.rawValue
    #endif

    @State private var displayName = ""
    @State private var invite: FriendsService.Invite?
    @State private var selectedFriend: FriendsService.Friend?
    @State private var showCodeEntry = false
    @State private var confirmLeave = false
    @State private var pendingInvite: PendingInvite?

    private struct PendingInvite: Identifiable {
        let id = UUID()
        let value: NavRouter.FriendInvite
    }

    var body: some View {
        #if os(iOS)
        Group {
            if selectedSource == FriendsSource.managed.rawValue {
                ManagedFriendsView(selectedSource: $selectedSource)
            } else {
                selfHostedBody
            }
        }
        .onAppear {
            if managedService.pendingSocialInviteCapability != nil {
                selectedSource = FriendsSource.managed.rawValue
            }
        }
        .onChange(of: managedService.pendingSocialInviteCapability) { _, capability in
            if capability != nil {
                selectedSource = FriendsSource.managed.rawValue
            }
        }
        #else
        selfHostedBody
        #endif
    }

    private var selfHostedBody: some View {
        ScreenScaffold(
            title: "Friends",
            subtitle: "Private summaries through a server you control.",
            onRefresh: { await service.refresh(repo: model.repo) },
            topBackground: liquidScaffoldSky()
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                #if os(iOS)
                FriendsSourcePicker(selection: $selectedSource)
                #endif
                switch service.setupState {
                case .needsServer:
                    serverSetupCard
                case .needsProfile:
                    profileSetupCard
                case .ready:
                    circleHero
                    if !service.requests.isEmpty { requestsSection }
                    friendsSection
                    privacyCard
                }

                if !service.statusMessage.isEmpty {
                    Text(service.statusMessage)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .task {
            if displayName.isEmpty { displayName = service.profileName }
            await service.refresh(repo: model.repo)
        }
        .sheet(item: $invite) { value in
            CircleInviteSheet(invite: value)
        }
        .sheet(item: $selectedFriend) { friend in
            FriendSharingSheet(friend: friend, service: service, repo: model.repo)
        }
        .sheet(isPresented: $showCodeEntry) {
            InviteCodeSheet(
                requiresServer: service.setupState != .ready,
                initialServer: service.serverAddress ?? "",
                displayName: $displayName
            ) { server, code in
                showCodeEntry = false
                let address = service.setupState == .ready
                    ? (service.serverAddress ?? "")
                    : server
                if let value = service.invitation(serverAddress: address, code: code) {
                    DispatchQueue.main.async {
                        pendingInvite = PendingInvite(value: value)
                    }
                }
            }
        }
        .sheet(item: $pendingInvite) { wrapped in
            JoinCircleSheet(
                invite: wrapped.value,
                needsName: service.setupState != .ready,
                displayName: $displayName
            ) {
                pendingInvite = nil
                Task {
                    await service.join(
                        wrapped.value,
                        displayName: displayName,
                        repo: model.repo
                    )
                }
            }
        }
        .alert("Friends", isPresented: Binding(
            get: { service.errorMessage != nil },
            set: { showing in if !showing { service.dismissError() } }
        )) {
            Button("OK", role: .cancel) { service.dismissError() }
        } message: {
            Text(service.errorMessage ?? "")
        }
        .confirmationDialog(
            "Leave this circle and delete your server profile?",
            isPresented: $confirmLeave,
            titleVisibility: .visible
        ) {
            Button("Leave & delete server copy", role: .destructive) {
                Task { await service.leaveAndDeleteProfile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Noop will remove your friendships, member credential, and dedicated Friends summary rows from this server. Your on-device health data and separate self-hosted backup stay intact.")
        }
    }

    private var serverSetupCard: some View {
        StrandCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    DepthGlyph("person.2.fill", size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Host your private circle")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Friends lives on a Noop server you control. There is no Noop account or public profile.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                NavigationLink {
                    BackupSyncView()
                } label: {
                    Label("Set up your server", systemImage: "server.rack")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.accentInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: NoopMetrics.controlHeight)
                        .background(StrandPalette.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                NoopButton(
                    "Enter invite details",
                    systemImage: "number",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    showCodeEntry = true
                }

                Text("An invitation includes a server address and one-time code. You can join without receiving the server administrator key.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var profileSetupCard: some View {
        StrandCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    FriendOrb(name: displayName.isEmpty ? "You" : displayName, size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Create your private profile")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Your name is visible only to accepted friends on \(service.serverHost ?? "your server").")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }

                TextField("Display name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textContentType(.name)
                    #endif
                    .accessibilityLabel("Friends display name")

                NoopButton(
                    service.isBusy ? "Creating…" : "Create private profile",
                    systemImage: "lock.shield",
                    kind: .primary,
                    fullWidth: true
                ) {
                    Task {
                        await service.bootstrap(displayName: displayName, repo: model.repo)
                    }
                }
                .disabled(service.isBusy || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                NoopButton(
                    "Join with invite details",
                    systemImage: "number",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    showCodeEntry = true
                }

                Text("The server administrator key is used once to issue a separate member token. That token stays in Keychain and cannot read raw server data. Friends is not end-to-end encrypted, so use a server operator you trust.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var circleHero: some View {
        StrandCard(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YOUR CIRCLE")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("\(service.memberCount) \(service.memberCount == 1 ? "person" : "people")")
                            .font(StrandFont.title1)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer()
                    DepthGlyph("person.2.fill", size: 48, selected: true)
                }

                HStack(spacing: -12) {
                    FriendOrb(name: service.profileName.isEmpty ? "You" : service.profileName, size: 54, highlighted: true)
                        .zIndex(Double(service.friends.count + 1))
                    ForEach(Array(service.friends.prefix(4).enumerated()), id: \.element.id) { index, friend in
                        FriendOrb(name: friend.displayName, size: 54)
                            .zIndex(Double(service.friends.count - index))
                    }
                    if service.friends.count > 4 {
                        ZStack {
                            Circle().fill(StrandPalette.surfaceInset)
                            Text("+\(service.friends.count - 4)")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .frame(width: 54, height: 54)
                        .overlay(Circle().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
                    }
                    Spacer()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(service.memberCount) people in your private circle")

                HStack(spacing: 10) {
                    NoopButton(
                        service.isBusy ? "Working…" : "Invite a friend",
                        systemImage: "person.badge.plus",
                        kind: .primary,
                        fullWidth: true
                    ) {
                        Task {
                            if let value = await service.createInvite() { invite = value }
                        }
                    }
                    .disabled(service.isBusy)

                    Button {
                        showCodeEntry = true
                    } label: {
                        Image(systemName: "number")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: NoopMetrics.controlHeight, height: NoopMetrics.controlHeight)
                            .background(StrandPalette.surfaceInset, in: Circle())
                            .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Enter an invite code")
                }
            }
        }
    }

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Requests", trailing: "\(service.requests.count)")
            ForEach(service.requests) { request in
                StrandCard(padding: 16) {
                    HStack(spacing: 13) {
                        FriendOrb(name: request.displayName, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.displayName)
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(request.isIncoming ? "Wants to join your circle" : "Waiting for acceptance")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: 8)
                        if request.isIncoming {
                            Button("Decline") {
                                Task { await service.decide(request, accept: false, repo: model.repo) }
                            }
                            .buttonStyle(.plain)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())

                            Button {
                                Task { await service.decide(request, accept: true, repo: model.repo) }
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(StrandPalette.accentInk)
                                    .frame(width: 34, height: 34)
                                    .background(StrandPalette.accent, in: Circle())
                                    .frame(width: 44, height: 44)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(LiquidPressStyle())
                            .accessibilityLabel("Accept \(request.displayName)")
                        }
                    }
                }
            }
        }
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Today", trailing: friendsTrailing)
            if service.friends.isEmpty {
                StrandCard(padding: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        DepthGlyph("person.crop.circle.badge.plus", size: 48)
                        Text("Your circle starts here")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Invite someone you trust. Their scores appear only after they join and you accept the request.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ForEach(service.friends) { friend in
                    Button { selectedFriend = friend } label: {
                        friendCard(friend)
                    }
                    .buttonStyle(StrandPressableButtonStyle())
                }
            }
        }
    }

    private var friendsTrailing: String {
        service.friends.isEmpty ? "Private" : "\(service.friends.count) friends"
    }

    private func friendCard(_ friend: FriendsService.Friend) -> some View {
        StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    FriendOrb(name: friend.displayName, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(friend.displayName)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(friend.latest.map { freshness($0.day) } ?? "Waiting for a shared day")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }

                if let summary = friend.latest {
                    HStack(spacing: 8) {
                        score("Recovery", summary.charge, symbol: "bolt.heart.fill",
                              color: StrandPalette.chargeColor)
                        score("Effort", summary.effort, symbol: "flame.fill",
                              color: StrandPalette.effortColor)
                        score("Sleep Score", summary.rest, symbol: "moon.stars.fill",
                              color: StrandPalette.restColor)
                    }
                } else {
                    Text("Scores will appear after \(friend.displayName) uploads a daily summary.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens sharing controls for \(friend.displayName)")
    }

    private func score(_ label: String, _ value: Double?, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                MetricGlyph(symbol, size: 22)
                Text(label.uppercased())
                    .font(StrandFont.overlineScaled(9))
                    .tracking(0)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(value.map { String(Int($0.rounded())) } ?? StrandFormat.missing)
                .font(StrandFont.number(26))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1)
        )
    }

    private var privacyCard: some View {
        StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 13) {
                    DepthGlyph("lock.shield.fill", size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Summary-only by design")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Raw heart rate, R-R intervals, sleep stages, journals, workouts, routes, exports, and device identifiers never appear in Friends.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                Button(role: .destructive) {
                    confirmLeave = true
                } label: {
                    Label("Leave circle & delete server copy…", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(StrandFont.subhead)
                }
                .disabled(service.isBusy)
            }
        }
    }

    private func freshness(_ day: String) -> String {
        let today = Self.dayString(Date())
        let yesterday = Self.dayString(
            Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        )
        if day == today { return "Shared today" }
        if day == yesterday { return "Shared yesterday" }
        guard let date = Self.storageDayFormatter.date(from: day) else {
            return String(localized: "Last shared")
        }
        let currentYear = Calendar.current.component(.year, from: Date())
        let sharedYear = Calendar.current.component(.year, from: date)
        let readable = sharedYear == currentYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return "Last shared \(readable)"
    }

    private static let storageDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}

#if os(iOS)
enum FriendsSource: String, CaseIterable {
    case managed
    case selfHosted

    var title: LocalizedStringKey {
        switch self {
        case .managed: return "NOOP+"
        case .selfHosted: return "Self-hosted"
        }
    }
}

struct FriendsSourcePicker: View {
    @Binding var selection: String

    var body: some View {
        Picker("Friends service", selection: $selection) {
            ForEach(FriendsSource.allCases, id: \.rawValue) { source in
                Text(source.title).tag(source.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Switches between NOOP+ and a server you operate.")
    }
}
#endif

// MARK: - Dimensional friend identity

private struct FriendOrb: View {
    let name: String
    var size: CGFloat
    var highlighted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color(hex: highlighted ? "#585858" : "#353535"), Color(hex: "#090909")]
                            : [Color.white, Color(hex: highlighted ? "#C8C8C3" : "#E1E1DD")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.75), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.72
                    )
                )
            Text(initials)
                .font(StrandFont.rounded(size * 0.30, weight: .bold))
                .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                .shadow(color: Color.black.opacity(0.18), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.85), StrandPalette.hairline, Color.black.opacity(0.28)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: highlighted ? 1.5 : 1
            )
        )
        .shadow(color: Color.black.opacity(scheme == .dark ? 0.50 : 0.16), radius: 8, x: 0, y: 5)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let value = words.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }
}

// MARK: - Invite sheets

private struct CircleInviteSheet: View {
    let invite: FriendsService.Invite
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: "Invite a friend",
                subtitle: "One-time access to your private circle.",
                topBackground: liquidScaffoldSky()
            ) {
                StrandCard(padding: 22) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            DepthGlyph("link.badge.plus", size: 50, selected: true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Ready to share")
                                    .font(StrandFont.title2)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(invite.serverAddress)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }

                        Text(invite.code)
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 15))

                        ShareLink(
                            item: invitationText,
                            subject: Text("Join my private Noop circle"),
                            message: Text("appwide.friends.invite.instructions")
                        ) {
                            Label("Share invitation", systemImage: "square.and.arrow.up")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.accentInk)
                                .frame(maxWidth: .infinity)
                                .frame(height: NoopMetrics.controlHeight)
                                .background(StrandPalette.accent, in: Capsule())
                        }

                        Text("The code expires within 72 hours and works once. Noop shares the server and code as plain text instead of putting the capability in a custom app link; the recipient enters both in Friends. Joining creates a request-you still decide whether to accept.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #endif
    }

    private var invitationText: String {
        """
        Join my private Noop circle.

        Server: \(invite.serverAddress)
        One-time code: \(invite.code)

        \(FriendsNavigationCopy.invitationInstruction)
        """
    }
}

private struct InviteCodeSheet: View {
    let requiresServer: Bool
    @Binding var displayName: String
    let onRedeem: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var server: String
    @State private var code = ""

    init(
        requiresServer: Bool,
        initialServer: String,
        displayName: Binding<String>,
        onRedeem: @escaping (String, String) -> Void
    ) {
        self.requiresServer = requiresServer
        _server = State(initialValue: initialServer)
        _displayName = displayName
        self.onRedeem = onRedeem
    }

    var body: some View {
        NavigationStack {
            Form {
                if requiresServer {
                    Section {
                        TextField("https://your-server.example", text: $server)
                            #if os(iOS)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    } header: {
                        Text("Server address")
                    } footer: {
                        Text("Use the complete address from the invitation, including HTTPS, port, and any base path.")
                    }

                    Section("Private profile") {
                        TextField("Display name", text: $displayName)
                            #if os(iOS)
                            .textContentType(.name)
                            #endif
                    }
                }

                Section {
                    TextField("NOOP-…", text: $code)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Invite code")
                } footer: {
                    Text("A code sends a request. No summary is uploaded until the inviter accepts it.")
                }

                if requiresServer {
                    Section {
                        Label("Trust the server operator", systemImage: "server.rack")
                    } footer: {
                        Text("Friends is not end-to-end encrypted. After acceptance, the server operator can access the summary fields you choose to send, even though other members see only their per-friend allowlist.")
                    }
                }
            }
            .navigationTitle("Join a circle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send request") { onRedeem(server, code) }
                        .disabled(
                            code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (requiresServer && (
                                server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ))
                        )
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #endif
    }
}

private struct JoinCircleSheet: View {
    let invite: NavRouter.FriendInvite
    let needsName: Bool
    @Binding var displayName: String
    let onJoin: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: "Join this circle?",
                subtitle: "Review the destination and disclosure first.",
                topBackground: liquidScaffoldSky()
            ) {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    StrandCard(padding: 22) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 13) {
                                DepthGlyph("person.2.fill", size: 50, selected: true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Private server")
                                        .font(StrandFont.headline)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text(invite.serverDisplay)
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .textSelection(.enabled)
                                }
                            }

                            if needsName {
                                TextField("Display name", text: $displayName)
                                    .textFieldStyle(.roundedBorder)
                                    #if os(iOS)
                                    .textContentType(.name)
                                    #endif
                            }

                            disclosure("Shared by default", "Recovery, Effort, and Sleep Score", "checkmark.shield")
                            disclosure("Off by default", "Sleep duration, HRV, and resting heart rate", "hand.raised")
                            disclosure("Never sent to Friends", "Raw HR/R-R, sleep stages, journal, workouts, routes, exports, and device identifiers", "lock.fill")
                            disclosure("Operator trust", "This is not end-to-end encrypted. The self-hosted server operator can access summary fields you choose to send.", "server.rack")

                            NoopButton(
                                "Send join request",
                                systemImage: "paperplane.fill",
                                kind: .primary,
                                fullWidth: true
                            ) {
                                onJoin()
                                dismiss()
                            }
                            .disabled(needsName && displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Text("Noop will not replace an existing circle with a different server. A mismatch is stopped and shown before anything is sent.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private func disclosure(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Per-friend sharing controls

private struct FriendSharingSheet: View {
    let friend: FriendsService.Friend
    @ObservedObject var service: FriendsService
    let repo: Repository

    @Environment(\.dismiss) private var dismiss
    @State private var sharing: FriendsService.Visibility
    @State private var confirmRemove = false

    init(friend: FriendsService.Friend, service: FriendsService, repo: Repository) {
        self.friend = friend
        self.service = service
        self.repo = repo
        _sharing = State(initialValue: friend.sharing)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 13) {
                        FriendOrb(name: friend.displayName, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(friend.displayName)
                                .font(StrandFont.title2)
                            Text("Sharing is directional and enforced by your server.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Daily scores") {
                    privacyToggle("Recovery", "battery.100percent", isOn: $sharing.charge)
                    privacyToggle("Effort", "figure.run", isOn: $sharing.effort)
                    privacyToggle("Sleep Score", "bed.double.fill", isOn: $sharing.rest)
                }

                Section {
                    privacyToggle("Sleep duration", "moon.zzz.fill", isOn: $sharing.sleepDuration)
                    privacyToggle("HRV", "waveform.path.ecg", isOn: $sharing.hrv)
                    privacyToggle("Resting heart rate", "heart.fill", isOn: $sharing.rhr)
                } header: {
                    Text("Additional details")
                } footer: {
                    Text("These stay off for every new friendship until you enable them here.")
                }

                Section("They share with you") {
                    readOnly("Recovery", friend.sharedWithMe.charge)
                    readOnly("Effort", friend.sharedWithMe.effort)
                    readOnly("Sleep Score", friend.sharedWithMe.rest)
                    readOnly("Sleep duration", friend.sharedWithMe.sleepDuration)
                    readOnly("HRV", friend.sharedWithMe.hrv)
                    readOnly("Resting heart rate", friend.sharedWithMe.rhr)
                }

                Section {
                    Button("Remove friend…", role: .destructive) {
                        confirmRemove = true
                    }
                } footer: {
                    Text("Removing a friend stops both directions of sharing immediately.")
                }
            }
            .navigationTitle(friend.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await service.updatePrivacy(
                                friendId: friend.id,
                                visibility: sharing,
                                repo: repo
                            )
                            dismiss()
                        }
                    }
                }
            }
            .alert("Remove \(friend.displayName)?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) {
                    Task {
                        await service.remove(friendId: friend.id, repo: repo)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Neither of you will see the other’s scores. You can reconnect only with a new invite.")
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private func privacyToggle(_ title: String, _ icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: icon)
        }
        .toggleStyle(.noopSwitch)
    }

    private func readOnly(_ title: String, _ visible: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(visible ? "Shared" : "Hidden")
                .foregroundStyle(visible ? StrandPalette.textPrimary : StrandPalette.textTertiary)
        }
    }
}

#if DEBUG
#Preview {
    FriendsView()
}
#endif
