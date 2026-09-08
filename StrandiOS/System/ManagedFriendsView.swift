#if os(iOS)
import NoopRemoteSync
import StrandDesign
import SwiftUI
import UserNotifications

struct ManagedFriendsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var service = ManagedCloudService.shared
    @Binding var selectedSource: String

    @State private var displayName = ""
    @State private var searchID = ""
    @State private var pokeOptIn = false
    @State private var quietStartMinute = 22 * 60
    @State private var quietEndMinute = 7 * 60
    @State private var selectedFriend: ManagedSocialFriend?
    @State private var requestToBlock: ManagedSocialRequest?
    @State private var profileToUnblock: ManagedSocialBlockedProfile?
    @State private var confirmRotate = false
    @State private var confirmDelete = false

    var body: some View {
        ScreenScaffold(
            title: "Friends",
            subtitle: "Private summaries with mutual control.",
            onRefresh: {
                if service.phase == .enrolled {
                    await service.refreshSocial(repo: model.repo)
                }
            },
            topBackground: liquidScaffoldSky()
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                FriendsSourcePicker(selection: $selectedSource)
                content
                if !service.socialStatus.isEmpty {
                    Text(service.socialStatus)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            service.bootstrap()
            apply(service.socialProfile)
            applyPendingProfileLink(service.pendingSocialNOOPID)
            if service.phase == .enrolled {
                await service.refreshSocial(repo: model.repo)
                apply(service.socialProfile)
            }
        }
        .onChange(of: service.phase) { _, phase in
            guard phase == .enrolled else { return }
            Task {
                await service.refreshSocial(repo: model.repo)
                apply(service.socialProfile)
            }
        }
        .onChange(of: service.socialProfile) { _, profile in
            apply(profile)
        }
        .onChange(of: service.pendingSocialNOOPID) { _, noopID in
            applyPendingProfileLink(noopID)
        }
        .onChange(of: searchID) { _, _ in
            service.clearSocialLookup()
        }
        .sheet(item: $selectedFriend) { friend in
            ManagedFriendDetailSheet(
                friend: friend,
                service: service,
                repo: model.repo
            )
        }
        .confirmationDialog(
            "Replace your NOOP ID?",
            isPresented: $confirmRotate,
            titleVisibility: .visible
        ) {
            Button("Replace NOOP ID", role: .destructive) {
                Task { await service.rotateSocialNOOPID(repo: model.repo) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current ID will stop accepting new requests. Existing friends are unchanged.")
        }
        .confirmationDialog(
            "Delete managed Friends?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete managed Friends", role: .destructive) {
                Task { await service.deleteSocialProfile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Friendships, invitations, shared summaries, badges, pending pokes, Safety contacts, Safety invitations, and Safety incident history will be deleted. Any active Safety page and location sharing will end. NOOP+ backup and on-device data are unchanged.")
        }
        .confirmationDialog(
            requestToBlock.map { "Block \($0.displayName)?" }
                ?? "Block profile?",
            isPresented: Binding(
                get: { requestToBlock != nil },
                set: { if !$0 { requestToBlock = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let request = requestToBlock {
                Button("Block profile", role: .destructive) {
                    requestToBlock = nil
                    Task {
                        await service.blockSocialProfile(
                            request.profileID,
                            repo: model.repo
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                requestToBlock = nil
            }
        } message: {
            Text("This request is removed and exact-ID lookup is hidden between both profiles.")
        }
        .confirmationDialog(
            profileToUnblock.map { "Unblock \($0.displayName)?" }
                ?? "Unblock profile?",
            isPresented: Binding(
                get: { profileToUnblock != nil },
                set: { if !$0 { profileToUnblock = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let blocked = profileToUnblock {
                Button("Unblock profile") {
                    profileToUnblock = nil
                    Task {
                        await service.unblockSocialProfile(
                            blocked.profileID,
                            repo: model.repo
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                profileToUnblock = nil
            }
        } message: {
            Text("Exact-ID lookup and new requests are allowed again. The friendship and sharing are not restored.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if service.phase != .enrolled {
            ManagedCloudBackupCard(service: service, repo: model.repo)
            StrandCard(padding: 18) {
                HStack(alignment: .top, spacing: 12) {
                    DepthGlyph("person.2.fill", size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Two private options")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("NOOP+ Friends needs an enrolled NOOP+ account. Self-hosted Friends remains available without NOOP+.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if service.socialProfile == nil {
            profileSetup
        } else {
            if service.pendingSocialNOOPID != nil {
                pendingProfileLink
            }
            if service.pendingSocialInviteCapability != nil {
                pendingInvite
            }
            identityCard
            exactSearch
            requestsSection
            friendsSection
            settingsCard
        }
    }

    private var profileSetup: some View {
        StrandCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ManagedFriendAvatar(
                        name: displayName.isEmpty ? "You" : displayName,
                        size: 54,
                        highlighted: true
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Create your managed Friends profile")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("A random exact-match NOOP ID is created. There is no public directory.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                TextField("Display name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.name)
                    .onChange(of: displayName) { _, value in
                        if value.count > 64 {
                            displayName = String(value.prefix(64))
                        }
                    }

                NoopButton(
                    service.isBusy ? "Creating..." : "Create private profile",
                    systemImage: "person.crop.circle.badge.plus",
                    kind: .primary,
                    fullWidth: true
                ) {
                    Task {
                        await service.createSocialProfile(
                            displayName: displayName,
                            repo: model.repo
                        )
                    }
                }
                .disabled(
                    service.isBusy
                        || displayName.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )

                if service.pendingSocialNOOPID != nil
                    || service.pendingSocialInviteCapability != nil {
                    Text("Finish this profile before reviewing the friend profile that opened NOOP.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusWarning)
                }
            }
        }
    }

    private var pendingProfileLink: some View {
        StrandCard(padding: 18, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    DepthGlyph(
                        "person.crop.circle.badge.questionmark",
                        size: 42,
                        selected: true
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Shared friend profile")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Review the exact profile before sending a request. Nothing is shared automatically.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                HStack(spacing: 10) {
                    NoopButton(
                        "Review profile",
                        systemImage: "person.crop.circle.badge.questionmark",
                        kind: .primary,
                        fullWidth: true
                    ) {
                        guard let noopID = service.pendingSocialNOOPID else {
                            return
                        }
                        searchID = noopID
                        service.clearPendingSocialProfileLink()
                        Task {
                            await service.lookupSocialProfile(noopID: noopID)
                        }
                    }
                    .disabled(service.isBusy)

                    Button {
                        service.clearPendingSocialProfileLink()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(
                                width: NoopMetrics.controlHeight,
                                height: NoopMetrics.controlHeight
                            )
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .accessibilityLabel("Dismiss shared profile")
                }
            }
        }
    }

    private var pendingInvite: some View {
        StrandCard(padding: 18, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    DepthGlyph("link.badge.plus", size: 42, selected: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Friend invitation")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("This link creates a request. Nothing is shared unless the other person accepts it.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                HStack(spacing: 10) {
                    NoopButton(
                        "Send request",
                        systemImage: "paperplane.fill",
                        kind: .primary,
                        fullWidth: true
                    ) {
                        Task {
                            await service.redeemPendingSocialInvite(
                                repo: model.repo
                            )
                        }
                    }
                    .disabled(service.isBusy)

                    Button {
                        service.clearPendingSocialInvite()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(
                                width: NoopMetrics.controlHeight,
                                height: NoopMetrics.controlHeight
                            )
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .accessibilityLabel("Dismiss invitation")
                }
            }
        }
    }

    private var identityCard: some View {
        StrandCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    ManagedFriendAvatar(
                        name: service.socialProfile?.displayName ?? "You",
                        size: 52,
                        highlighted: true
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.socialProfile?.displayName ?? "You")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Your exact-match NOOP ID")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    StatePill("Private", tone: .positive)
                }

                Text(service.socialProfile?.noopID ?? "")
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(
                        StrandPalette.surfaceInset,
                        in: RoundedRectangle(
                            cornerRadius: NoopMetrics.cardRadius,
                            style: .continuous
                        )
                    )

                HStack(spacing: 10) {
                    if let profile = service.socialProfile,
                       let url = service.socialProfileURL(profile) {
                        ShareLink(
                            item: url,
                            subject: Text("My NOOP profile"),
                            message: Text("Open this profile in NOOP Friends, review it, and choose whether to send a request.")
                        ) {
                            Label(
                                "Share profile link",
                                systemImage: "square.and.arrow.up"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(
                            NoopButtonStyle(.primary, fullWidth: true)
                        )
                        .disabled(service.isBusy)
                    } else {
                        NoopButton(
                            "Share profile link",
                            systemImage: "square.and.arrow.up",
                            kind: .primary,
                            fullWidth: true
                        ) {}
                        .disabled(true)
                    }

                    Button {
                        confirmRotate = true
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(
                                width: NoopMetrics.controlHeight,
                                height: NoopMetrics.controlHeight
                            )
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .accessibilityLabel("Replace NOOP ID")
                }

                if let invite = service.socialInvite,
                   let url = service.socialInviteURL(invite) {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Private invitation link")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("This link expires within 72 hours and creates a request, never an automatic friendship.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            ShareLink(
                                item: url,
                                subject: Text("NOOP Friends invitation"),
                                message: Text("Open this link in NOOP to send me a friend request. Nothing is shared automatically.")
                            ) {
                                Label(
                                    "Share invite link",
                                    systemImage: "square.and.arrow.up"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(
                                NoopButtonStyle(.secondary, fullWidth: true)
                            )
                            .disabled(service.isBusy)

                            Button {
                                Task { await service.revokeSocialInvite() }
                            } label: {
                                Image(systemName: "link.badge.minus")
                                    .frame(
                                        width: NoopMetrics.controlHeight,
                                        height: NoopMetrics.controlHeight
                                    )
                            }
                            .buttonStyle(NoopButtonStyle(.secondary))
                            .accessibilityLabel("Revoke invitation link")
                            .disabled(service.isBusy)
                        }
                    }
                } else {
                    NoopButton(
                        "Create invite link",
                        systemImage: "link.badge.plus",
                        kind: .secondary,
                        fullWidth: true
                    ) {
                        Task { await service.createSocialInvite() }
                    }
                    .disabled(service.isBusy)
                }

                if let profile = service.socialProfile,
                   !profile.badges.isEmpty {
                    ManagedBadgeRow(badges: profile.badges)
                }
            }
        }
    }

    private var exactSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Add by NOOP ID", trailing: "Exact match")
            StrandCard(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        TextField("NOOP-XXXX-XXXX-XXXX-XXXX", text: $searchID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button {
                            Task {
                                await service.lookupSocialProfile(
                                    noopID: searchID
                                )
                            }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .frame(
                                    width: NoopMetrics.controlHeight,
                                    height: NoopMetrics.controlHeight
                                )
                        }
                        .buttonStyle(NoopButtonStyle(.secondary))
                        .disabled(
                            service.isBusy
                                || ManagedSocialIdentifier.canonicalNOOPID(
                                    searchID
                                ) == nil
                        )
                        .accessibilityLabel("Search exact NOOP ID")
                    }

                    if let result = service.socialLookup {
                        HStack(spacing: 12) {
                            ManagedFriendAvatar(
                                name: result.displayName,
                                size: 44
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.displayName)
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(result.isSelf ? "This is you" : "Exact ID found")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer(minLength: 8)
                            if !result.isSelf {
                                Button {
                                    Task {
                                        await service.sendSocialRequest(
                                            noopID: result.noopID,
                                            repo: model.repo
                                        )
                                        searchID = ""
                                    }
                                } label: {
                                    Image(systemName: "person.badge.plus")
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(NoopButtonStyle(.primary))
                                .disabled(service.isBusy)
                                .accessibilityLabel(
                                    "Send friend request to \(result.displayName)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var requestsSection: some View {
        let requests = service.socialRequests.filter { $0.status == "pending" }
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Requests", trailing: "\(requests.count)")
                ForEach(requests) { request in
                    StrandCard(padding: 16) {
                        HStack(spacing: 12) {
                            ManagedFriendAvatar(
                                name: request.displayName,
                                size: 44
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.displayName)
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(
                                    request.isIncoming
                                        ? "Wants to connect"
                                        : "Waiting for acceptance"
                                )
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer(minLength: 8)
                            if request.isIncoming {
                                Menu {
                                    Button(role: .destructive) {
                                        requestToBlock = request
                                    } label: {
                                        Label(
                                            "Block profile",
                                            systemImage: "hand.raised.fill"
                                        )
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(NoopButtonStyle(.secondary))
                                .accessibilityLabel(
                                    "More options for \(request.displayName)"
                                )

                                Button("Decline") {
                                    Task {
                                        await service.decideSocialRequest(
                                            request.requestID,
                                            accept: false,
                                            repo: model.repo
                                        )
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(minWidth: 44, minHeight: 44)

                                Button {
                                    Task {
                                        await service.decideSocialRequest(
                                            request.requestID,
                                            accept: true,
                                            repo: model.repo
                                        )
                                    }
                                } label: {
                                    Image(systemName: "checkmark")
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(NoopButtonStyle(.primary))
                                .accessibilityLabel(
                                    "Accept \(request.displayName)"
                                )
                            }
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
                            Text("Your circle starts here")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Share your profile link or exchange an exact NOOP ID. Every connection requires acceptance.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                ForEach(service.socialFriends) { friend in
                    ManagedFriendCard(
                        friend: friend,
                        busy: service.isBusy,
                        onOpen: { selectedFriend = friend },
                        onPoke: {
                            Task {
                                await service.sendSocialPoke(
                                    to: friend.profileID
                                )
                            }
                        }
                    )
                }
            }
        }
    }

    private var settingsCard: some View {
        StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    DepthGlyph("hand.tap.fill", size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pokes and privacy")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Pokes require this global switch and permission for that specific friend.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }

                TextField("Display name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.name)
                    .onChange(of: displayName) { _, value in
                        if value.count > 64 {
                            displayName = String(value.prefix(64))
                        }
                    }

                Toggle("Allow permitted friends to poke me", isOn: $pokeOptIn)
                    .tint(StrandPalette.statusPositive)
                    .onChange(of: pokeOptIn) { _, enabled in
                        guard enabled else { return }
                        Task {
                            _ = try? await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound])
                        }
                    }

                if pokeOptIn {
                    Divider()
                    Text("Quiet hours")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    DatePicker(
                        "Start",
                        selection: quietStartBinding,
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        "End",
                        selection: quietEndBinding,
                        displayedComponents: .hourAndMinute
                    )
                }

                NoopButton(
                    "Save Friends settings",
                    systemImage: "checkmark",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    Task {
                        await service.updateSocialProfile(
                            displayName: displayName,
                            pokeOptIn: pokeOptIn,
                            quietStartMinute: quietStartMinute,
                            quietEndMinute: quietEndMinute,
                            repo: model.repo
                        )
                    }
                }
                .disabled(
                    service.isBusy
                        || displayName.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(StrandPalette.statusPositive)
                    Text("Only Charge, Effort, Rest, sleep duration, HRV, and resting heart rate can be shared. Raw streams, locations, journals, routes, workouts, and sleep stages are excluded.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !service.socialBlockedProfiles.isEmpty {
                    Divider()
                    SectionHeader(
                        "Blocked profiles",
                        trailing: "\(service.socialBlockedProfiles.count)"
                    )
                    ForEach(service.socialBlockedProfiles) { blocked in
                        HStack(spacing: 12) {
                            ManagedFriendAvatar(
                                name: blocked.displayName,
                                size: 40
                            )
                            Text(blocked.displayName)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Button {
                                profileToUnblock = blocked
                            } label: {
                                Image(systemName: "lock.open.fill")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(NoopButtonStyle(.secondary))
                            .accessibilityLabel(
                                "Unblock \(blocked.displayName)"
                            )
                            .disabled(service.isBusy)
                        }
                    }
                }

                NoopButton(
                    "Delete managed Friends",
                    systemImage: "trash",
                    kind: .tertiary,
                    fullWidth: true
                ) {
                    confirmDelete = true
                }
                .disabled(service.isBusy)
            }
        }
    }

    private var quietStartBinding: Binding<Date> {
        Binding(
            get: { Self.date(for: quietStartMinute) },
            set: { quietStartMinute = Self.minute(of: $0) }
        )
    }

    private var quietEndBinding: Binding<Date> {
        Binding(
            get: { Self.date(for: quietEndMinute) },
            set: { quietEndMinute = Self.minute(of: $0) }
        )
    }

    private func apply(_ profile: ManagedSocialProfile?) {
        guard let profile else {
            if displayName.isEmpty {
                displayName = model.profile.displayName
            }
            return
        }
        displayName = profile.displayName
        pokeOptIn = profile.pokeOptIn
        quietStartMinute = profile.quietStartMinute
        quietEndMinute = profile.quietEndMinute
    }

    private func applyPendingProfileLink(_ noopID: String?) {
        guard let noopID else { return }
        searchID = noopID
    }

    private static func date(for minute: Int) -> Date {
        Calendar.current.date(
            byAdding: .minute,
            value: min(1439, max(0, minute)),
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()
    }

    private static func minute(of date: Date) -> Int {
        let components = Calendar.current.dateComponents(
            [.hour, .minute],
            from: date
        )
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

private struct ManagedFriendCard: View {
    let friend: ManagedSocialFriend
    let busy: Bool
    let onOpen: () -> Void
    let onPoke: () -> Void

    var body: some View {
        StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ManagedFriendAvatar(name: friend.displayName, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(friend.displayName)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(friend.latest?.day ?? "Waiting for a shared day")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Button(action: onOpen) {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .accessibilityLabel(
                        "Sharing settings for \(friend.displayName)"
                    )
                }

                if let summary = friend.latest?.summary {
                    HStack(spacing: 8) {
                        ManagedSocialScore(
                            label: "Charge",
                            value: summary.charge,
                            color: StrandPalette.chargeColor
                        )
                        ManagedSocialScore(
                            label: "Effort",
                            value: summary.effort,
                            color: StrandPalette.effortColor
                        )
                        ManagedSocialScore(
                            label: "Rest",
                            value: summary.rest,
                            color: StrandPalette.restColor
                        )
                    }
                    let details = ManagedSocialFormat.details(summary)
                    if !details.isEmpty {
                        Text(details.joined(separator: "  ·  "))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Shared details appear only when this friend allows them.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                if !friend.badges.isEmpty {
                    ManagedBadgeRow(badges: friend.badges)
                }

                if friend.sharedWithMe.pokeAllowed {
                    NoopButton(
                        "Poke",
                        systemImage: "hand.tap.fill",
                        kind: .secondary,
                        fullWidth: true,
                        action: onPoke
                    )
                    .disabled(busy)
                }
            }
        }
    }
}

private struct ManagedSocialScore: View {
    let label: LocalizedStringKey
    let value: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(StrandFont.overlineScaled(9))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            Text(value.map { String(Int($0.rounded())) } ?? "-")
                .font(StrandFont.number(24))
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

private struct ManagedBadgeRow: View {
    let badges: [ManagedSocialBadge]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(badges) { badge in
                    Label(
                        ManagedSocialFormat.badgeTitle(badge.code),
                        systemImage: ManagedSocialFormat.badgeSymbol(badge.code)
                    )
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        StrandPalette.surfaceInset,
                        in: Capsule()
                    )
                }
            }
        }
        .accessibilityLabel("Wellness badges")
    }
}

private struct ManagedFriendAvatar: View {
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
                .font(StrandFont.rounded(size * 0.30, weight: .bold))
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

private struct ManagedFriendDetailSheet: View {
    let friend: ManagedSocialFriend
    @ObservedObject var service: ManagedCloudService
    let repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var charge: Bool
    @State private var effort: Bool
    @State private var rest: Bool
    @State private var sleepDuration: Bool
    @State private var hrv: Bool
    @State private var rhr: Bool
    @State private var pokeAllowed: Bool
    @State private var confirmRemove = false
    @State private var confirmBlock = false

    private var sharedHistory: [ManagedSocialFeedDay] {
        Array(
            service.socialFeed
                .filter { $0.profileID == friend.profileID }
                .sorted { $0.day > $1.day }
                .prefix(7)
        )
    }

    init(
        friend: ManagedSocialFriend,
        service: ManagedCloudService,
        repo: Repository
    ) {
        self.friend = friend
        self.service = service
        self.repo = repo
        _charge = State(initialValue: friend.sharing.charge)
        _effort = State(initialValue: friend.sharing.effort)
        _rest = State(initialValue: friend.sharing.rest)
        _sleepDuration = State(initialValue: friend.sharing.sleepDuration)
        _hrv = State(initialValue: friend.sharing.hrv)
        _rhr = State(initialValue: friend.sharing.rhr)
        _pokeAllowed = State(initialValue: friend.sharing.pokeAllowed)
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: LocalizedStringKey(friend.displayName),
                subtitle: "Directional sharing. Change it any time.",
                topBackground: liquidScaffoldSky()
            ) {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if !sharedHistory.isEmpty {
                        StrandCard(padding: 18) {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader("Last 7 shared days")
                                ForEach(
                                    Array(sharedHistory.enumerated()),
                                    id: \.element.id
                                ) { index, day in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(day.day)
                                            .font(StrandFont.caption)
                                            .foregroundStyle(
                                                StrandPalette.textTertiary
                                            )
                                        Text(
                                            ManagedSocialFormat.compactDetails(
                                                day.summary
                                            ).joined(separator: "  ·  ")
                                        )
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(
                                            StrandPalette.textPrimary
                                        )
                                        .fixedSize(
                                            horizontal: false,
                                            vertical: true
                                        )
                                    }
                                    if index < sharedHistory.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    } else if let summary = friend.latest?.summary {
                        StrandCard(padding: 18) {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader("Latest shared details")
                                Text(
                                    ManagedSocialFormat.compactDetails(
                                        summary
                                    ).joined(separator: "  ·  ")
                                )
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    StrandCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader("I share with \(friend.displayName)")
                            ManagedSharingToggle(
                                "Charge",
                                isOn: $charge
                            )
                            ManagedSharingToggle(
                                "Effort",
                                isOn: $effort
                            )
                            ManagedSharingToggle(
                                "Rest",
                                isOn: $rest
                            )
                            ManagedSharingToggle(
                                "Sleep duration",
                                isOn: $sleepDuration
                            )
                            ManagedSharingToggle("HRV", isOn: $hrv)
                            ManagedSharingToggle(
                                "Resting heart rate",
                                isOn: $rhr
                            )
                            Divider()
                            ManagedSharingToggle(
                                "Allow this friend to poke me",
                                isOn: $pokeAllowed
                            )

                            NoopButton(
                                "Save sharing",
                                systemImage: "checkmark",
                                kind: .primary,
                                fullWidth: true
                            ) {
                                Task {
                                    await service.updateSocialVisibility(
                                        friendProfileID: friend.profileID,
                                        patch: ManagedSocialVisibilityPatch(
                                            charge: charge,
                                            effort: effort,
                                            rest: rest,
                                            sleepDuration: sleepDuration,
                                            hrv: hrv,
                                            rhr: rhr,
                                            pokeAllowed: pokeAllowed
                                        ),
                                        repo: repo
                                    )
                                    dismiss()
                                }
                            }
                            .disabled(service.isBusy)
                        }
                    }

                    StrandCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("\(friend.displayName) shares with me")
                            ManagedReadOnlySharing(
                                "Charge",
                                shared: friend.sharedWithMe.charge
                            )
                            ManagedReadOnlySharing(
                                "Effort",
                                shared: friend.sharedWithMe.effort
                            )
                            ManagedReadOnlySharing(
                                "Rest",
                                shared: friend.sharedWithMe.rest
                            )
                            ManagedReadOnlySharing(
                                "Sleep duration",
                                shared: friend.sharedWithMe.sleepDuration
                            )
                            ManagedReadOnlySharing(
                                "HRV",
                                shared: friend.sharedWithMe.hrv
                            )
                            ManagedReadOnlySharing(
                                "Resting heart rate",
                                shared: friend.sharedWithMe.rhr
                            )
                            ManagedReadOnlySharing(
                                "I can poke them",
                                shared: friend.sharedWithMe.pokeAllowed
                            )

                            if friend.sharedWithMe.pokeAllowed {
                                NoopButton(
                                    "Poke \(friend.displayName)",
                                    systemImage: "hand.tap.fill",
                                    kind: .secondary,
                                    fullWidth: true
                                ) {
                                    Task {
                                        await service.sendSocialPoke(
                                            to: friend.profileID
                                        )
                                    }
                                }
                                .disabled(service.isBusy)
                            }
                        }
                    }

                    StrandCard(padding: 18) {
                        VStack(spacing: 8) {
                            NoopButton(
                                "Remove friend",
                                systemImage: "person.badge.minus",
                                kind: .tertiary,
                                fullWidth: true
                            ) {
                                confirmRemove = true
                            }
                            NoopButton(
                                "Block profile",
                                systemImage: "hand.raised.fill",
                                kind: .destructive,
                                fullWidth: true
                            ) {
                                confirmBlock = true
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .noopSheetPresentation(largeFirst: true)
        .confirmationDialog(
            "Remove \(friend.displayName)?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove friend", role: .destructive) {
                Task {
                    await service.removeSocialFriend(
                        friend.profileID,
                        repo: repo
                    )
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sharing and pending pokes stop in both directions.")
        }
        .confirmationDialog(
            "Block \(friend.displayName)?",
            isPresented: $confirmBlock,
            titleVisibility: .visible
        ) {
            Button("Block profile", role: .destructive) {
                Task {
                    await service.blockSocialProfile(
                        friend.profileID,
                        repo: repo
                    )
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The friendship, requests, sharing, and pending pokes are removed. Exact-ID lookup is hidden between both profiles.")
        }
    }
}

private struct ManagedSharingToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .tint(StrandPalette.statusPositive)
    }
}

private struct ManagedReadOnlySharing: View {
    let title: LocalizedStringKey
    let shared: Bool

    init(_ title: LocalizedStringKey, shared: Bool) {
        self.title = title
        self.shared = shared
    }

    var body: some View {
        HStack {
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Label(
                shared ? "Shared" : "Hidden",
                systemImage: shared ? "checkmark.circle.fill" : "minus.circle"
            )
            .font(StrandFont.caption)
            .foregroundStyle(
                shared
                    ? StrandPalette.statusPositive
                    : StrandPalette.textTertiary
            )
        }
    }
}

private enum ManagedSocialFormat {
    static func compactDetails(_ summary: ManagedSocialSummary) -> [String] {
        var result: [String] = []
        if let charge = summary.charge {
            result.append("Charge \(Int(charge.rounded()))")
        }
        if let effort = summary.effort {
            result.append("Effort \(Int(effort.rounded()))")
        }
        if let rest = summary.rest {
            result.append("Rest \(Int(rest.rounded()))")
        }
        result.append(contentsOf: details(summary))
        return result
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
