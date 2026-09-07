#if os(iOS)
import SwiftUI
import StrandDesign

struct OwnershipAccountView: View {
    @StateObject private var service = OwnershipService.shared
    @State private var createMode = true
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var phone = ""
    @State private var phoneCode = ""
    @State private var acceptedTerms = false
    @State private var selectedPlan = NoopProductPlan.stored()
    @State private var pendingRevocation: OwnershipInstallation?
    @State private var confirmsLocalReset = false

    var body: some View {
        ScreenScaffold(
            title: "Band Account",
            subtitle: "Ownership activation is separate from NOOP+ and never stores health data."
        ) {
            switch service.phase {
            case .unavailable:
                unavailable
            case .localRecoveryRequired:
                localRecovery
            case .signedOut:
                authentication
            case .emailVerification:
                emailVerification
            case .termsReview:
                termsReview
            case .registering:
                progress(
                    title: "Securing your account",
                    detail: "NOOP is reconciling the versioned terms and this phone installation."
                )
            case .accountReady, .possessionUnavailable, .claimed, .complete:
                account
            case .claiming:
                progress(
                    title: "Confirming band ownership",
                    detail: "Keep the band worn and nearby until confirmation completes."
                )
            case .replacementRequired:
                replacement
            case .authorizingReplacement:
                progress(
                    title: "Authorizing this phone",
                    detail: "Keep the claimed band worn and nearby while NOOP verifies possession."
                )
            }
            status
            localBoundary
        }
        .task {
            service.bootstrap()
            selectedPlan = service.overview?.plan ?? NoopProductPlan.stored()
        }
        .onChange(of: service.overview) { _, value in
            if let value { selectedPlan = value.plan }
        }
        .alert(item: $pendingRevocation) { installation in
            Alert(
                title: Text("Revoke this phone?"),
                message: Text(
                    "It will lose access to the ownership account. Local health data and other authorized phones are not deleted."
                ),
                primaryButton: .destructive(Text("Revoke")) {
                    Task { await service.revokeInstallation(installation) }
                },
                secondaryButton: .cancel()
            )
        }
        .confirmationDialog(
            "Reset ownership setup on this phone?",
            isPresented: $confirmsLocalReset,
            titleVisibility: .visible
        ) {
            Button("Reset this phone", role: .destructive) {
                service.resetLocalOwnershipSetup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes only local ownership credentials and progress. Health data stays on this phone. Sign in to recover access; a claimed account must confirm its band again."
            )
        }
    }

    private var unavailable: some View {
        StrandCard(padding: 20) {
            header(
                symbol: "lock.shield",
                title: "Band ownership is not enabled",
                detail: "This build keeps the future account flow dormant. Core local NOOP remains available without an account."
            )
            Text(
                "Activation will be enabled only after the approved band SDK can provide fresh, cryptographic possession proof."
            )
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localRecovery: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                header(
                    symbol: "key.slash",
                    title: "Repair ownership setup",
                    detail: "Secure ownership credentials on this phone could not be read. NOOP has stopped the account flow rather than replacing them silently."
                )
                Text(
                    "Resetting removes only this phone's ownership credentials and progress. It does not delete local health data, release the band, or change another authorized phone."
                )
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                NoopButton(
                    "Reset this phone",
                    systemImage: "arrow.counterclockwise",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    confirmsLocalReset = true
                }
                .disabled(service.isBusy)
            }
        }
    }

    private var authentication: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                header(
                    symbol: "person.badge.key.fill",
                    title: createMode ? "Create ownership account" : "Sign in",
                    detail: "Use a verified email and password. Credentials are handled by the identity provider and never stored in NOOP databases."
                )

                Picker("Account action", selection: $createMode) {
                    Text("Create").tag(true)
                    Text("Sign in").tag(false)
                }
                .pickerStyle(.segmented)

                if createMode {
                    authenticationTerms
                }

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .disabled(service.isBusy)
                    .accessibilityIdentifier("noop.ownership.email")

                SecureField("Password", text: $password)
                    .textContentType(createMode ? .newPassword : .password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(service.isBusy)
                    .accessibilityIdentifier("noop.ownership.password")

                if createMode {
                    SecureField("Confirm password", text: $confirmation)
                        .textContentType(.newPassword)
                        .textFieldStyle(.roundedBorder)
                        .disabled(service.isBusy)
                        .accessibilityIdentifier("noop.ownership.password-confirmation")
                }

                NoopButton(
                    service.isBusy
                        ? "Working..."
                        : (createMode ? "Create account" : "Sign in"),
                    systemImage: createMode ? "person.badge.plus" : "person.crop.circle.badge.checkmark",
                    kind: .primary,
                    fullWidth: true
                ) {
                    let suppliedPassword = password
                    let suppliedConfirmation = confirmation
                    password = ""
                    confirmation = ""
                    Task {
                        if createMode {
                            await service.createAccount(
                                email: email,
                                password: suppliedPassword,
                                confirmation: suppliedConfirmation,
                                acceptedTerms: acceptedTerms
                            )
                        } else {
                            await service.signIn(
                                email: email,
                                password: suppliedPassword
                            )
                        }
                    }
                }
                .disabled(
                    service.isBusy
                        || email.isEmpty
                        || password.isEmpty
                        || (createMode
                            && (confirmation.isEmpty
                                || service.terms == nil
                                || !acceptedTerms))
                )
                .accessibilityIdentifier("noop.ownership.authenticate")

                Button("Send password reset") {
                    Task { await service.sendPasswordReset(email: email) }
                }
                .buttonStyle(.plain)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.accent)
                .disabled(service.isBusy || email.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var authenticationTerms: some View {
        if let terms = service.terms {
            Text("Review and accept the ownership policy before creating an account.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(terms.text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 150, maxHeight: 240)
            .padding(12)
            .background(
                StrandPalette.surfaceInset,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .accessibilityIdentifier("noop.ownership.pre-account-terms")
            Toggle(isOn: $acceptedTerms) {
                Text("I agree to this ownership policy.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.noopSwitch)
        } else {
            NoopButton(
                service.isBusy ? "Loading..." : "Review ownership terms",
                systemImage: "doc.text.magnifyingglass",
                kind: .secondary,
                fullWidth: true
            ) {
                acceptedTerms = false
                Task { await service.loadTerms(forAccountCreation: true) }
            }
            .disabled(service.isBusy)
        }
    }

    private var emailVerification: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                header(
                    symbol: "envelope.badge.shield.half.filled",
                    title: "Verify your email",
                    detail: emailVerificationDetail
                )
                NoopButton(
                    service.isBusy ? "Checking..." : "I verified my email",
                    systemImage: "checkmark.shield",
                    kind: .primary,
                    fullWidth: true
                ) {
                    Task { await service.checkEmailVerification() }
                }
                .disabled(service.isBusy)

                NoopButton(
                    "Resend verification",
                    systemImage: "arrow.clockwise",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    Task { await service.resendEmailVerification() }
                }
                .disabled(service.isBusy)

                signOutButton
            }
        }
    }

    private var termsReview: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                header(
                    symbol: "doc.text.magnifyingglass",
                    title: "Review ownership terms",
                    detail: "The exact immutable document is fetched from NOOP-controlled storage and verified before acceptance."
                )

                if let terms = service.terms {
                    ScrollView {
                        Text(terms.text)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 180, maxHeight: 320)
                    .padding(12)
                    .background(
                        StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityIdentifier("noop.ownership.terms")

                    Toggle(isOn: $acceptedTerms) {
                        Text("I agree to this ownership policy.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.noopSwitch)

                    NoopButton(
                        service.isBusy ? "Registering..." : "I agree and continue",
                        systemImage: "checkmark.seal.fill",
                        kind: .primary,
                        fullWidth: true
                    ) {
                        Task { await service.acceptTermsAndRegister() }
                    }
                    .disabled(service.isBusy || !acceptedTerms)
                    .accessibilityIdentifier("noop.ownership.accept-terms")
                } else {
                    NoopButton(
                        service.isBusy ? "Loading..." : "Load current terms",
                        systemImage: "arrow.down.doc",
                        kind: .primary,
                        fullWidth: true
                    ) {
                        acceptedTerms = false
                        Task { await service.loadTerms() }
                    }
                    .disabled(service.isBusy)
                }

                signOutButton
            }
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            StrandCard(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    header(
                        symbol: service.overview?.bandState == "claimed"
                            ? "checkmark.shield.fill"
                            : "person.badge.key.fill",
                        title: "Ownership account",
                        detail: accountSummary
                    )

                    if service.possessionAvailable,
                       service.overview?.bandState != "claimed" {
                        NoopButton(
                            "Confirm worn band",
                            systemImage: "wave.3.right.circle.fill",
                            kind: .primary,
                            fullWidth: true
                        ) {
                            Task { await service.claimBand() }
                        }
                        .disabled(service.isBusy)
                    } else if service.overview?.bandState != "claimed" {
                        Text(
                            "Physical band confirmation remains locked until the approved SDK supplies signed possession proof."
                        )
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker("Product", selection: $selectedPlan) {
                        Text("NOOP").tag(NoopProductPlan.noop)
                        Text("NOOP+").tag(NoopProductPlan.noopPlus)
                    }
                    .pickerStyle(.segmented)
                    .disabled(service.isBusy)

                    NoopButton(
                        "Save product preference",
                        systemImage: "checkmark.circle",
                        kind: .secondary,
                        fullWidth: true
                    ) {
                        Task { await service.selectPlan(selectedPlan) }
                    }
                    .disabled(service.isBusy)

                    Text(
                        "NOOP+ payment and entitlement are unavailable. This preference cannot activate, deactivate, or transfer a band."
                    )
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            optionalPhone
            installations

            NoopButton(
                service.isBusy ? "Refreshing..." : "Refresh account",
                systemImage: "arrow.clockwise",
                kind: .secondary,
                fullWidth: true
            ) {
                Task { await service.refreshOverview() }
            }
            .disabled(service.isBusy)

            signOutButton
        }
    }

    private var replacement: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                header(
                    symbol: "iphone.and.arrow.forward",
                    title: "Authorize this phone",
                    detail: "This account already owns a band. Confirm the worn band before this phone can access ownership controls. This does not create a second claim."
                )
                if service.possessionAvailable {
                    NoopButton(
                        "Confirm band and authorize phone",
                        systemImage: "wave.3.right.circle.fill",
                        kind: .primary,
                        fullWidth: true
                    ) {
                        Task { await service.authorizeReplacementPhone() }
                    }
                    .disabled(service.isBusy)
                } else {
                    Text(
                        "Replacement-phone authorization is ready, but physical confirmation remains locked until the approved band SDK supplies signed possession proof."
                    )
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                }
                signOutButton
            }
        }
    }

    private var optionalPhone: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Optional mobile recovery")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if service.overview?.phoneVerified == true {
                    Label("Mobile number verified", systemImage: "checkmark.circle.fill")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.statusPositive)
                } else {
                    TextField("Mobile number with country code", text: $phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(service.isBusy)
                    NoopButton(
                        "Send verification code",
                        systemImage: "message",
                        kind: .secondary,
                        fullWidth: true
                    ) {
                        Task { await service.sendPhoneCode(to: phone) }
                    }
                    .disabled(service.isBusy || phone.isEmpty)

                    TextField("Verification code", text: $phoneCode)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(service.isBusy)
                    NoopButton(
                        "Verify optional number",
                        systemImage: "checkmark.shield",
                        kind: .secondary,
                        fullWidth: true
                    ) {
                        Task { await service.linkPhone(code: phoneCode) }
                    }
                    .disabled(service.isBusy || phoneCode.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var installations: some View {
        let active = service.installations.filter { $0.status == "active" }
        if !active.isEmpty {
            StrandCard(padding: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Authorized phones")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    ForEach(active) { installation in
                        HStack(spacing: 12) {
                            Image(systemName: installation.platform == "ios"
                                  ? "iphone"
                                  : "apps.iphone")
                                .foregroundStyle(
                                    installation.current
                                        ? StrandPalette.statusPositive
                                        : StrandPalette.textSecondary
                                )
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(installation.current ? "This phone" : "Authorized phone")
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("Last seen \(ownershipRelativeTime(installation.lastSeenAt))")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer(minLength: 8)
                            if !installation.current {
                                Button("Revoke", role: .destructive) {
                                    pendingRevocation = installation
                                }
                                .font(StrandFont.caption)
                                .disabled(service.isBusy)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func progress(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                ProgressView()
                    .tint(StrandPalette.accent)
                Text(title)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func header(
        symbol: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 40, height: 40)
                .background(
                    StrandPalette.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: 8)
                )
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(detail)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signOutButton: some View {
        NoopButton(
            "Sign out",
            systemImage: "rectangle.portrait.and.arrow.right",
            kind: .tertiary,
            fullWidth: true
        ) {
            password = ""
            confirmation = ""
            phoneCode = ""
            service.signOut()
        }
        .disabled(service.isBusy)
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

    private var localBoundary: some View {
        Text(
            "The ownership service stores identity and device-control records only. Local collection, metrics, workouts, Journal, Coach, backup and export do not require NOOP+."
        )
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emailVerificationDetail: LocalizedStringKey {
        if service.maskedEmail.isEmpty {
            return "Open the verification message, then return here."
        }
        return "A verification message was sent to \(service.maskedEmail)."
    }

    private var accountSummary: LocalizedStringKey {
        guard let overview = service.overview else {
            return "Account details are being reconciled with the ownership authority."
        }
        if overview.bandState == "claimed" {
            return "The band is claimed. Local operation remains independent of account-service and NOOP+ availability."
        }
        return "The account is ready. No band is claimed on this phone yet."
    }
}

private func ownershipRelativeTime(_ raw: String) -> String {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = fractional.date(from: raw)
        ?? ISO8601DateFormatter().date(from: raw) else {
        return String(localized: "recently")
    }
    return RelativeDateTimeFormatter().localizedString(
        for: date,
        relativeTo: Date()
    )
}
#endif
