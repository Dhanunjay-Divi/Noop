import SwiftUI
import StrandDesign

/// First-run acknowledgment gate (clickwrap). Shown over the operational app shell — before onboarding
/// or any user-initiated pairing — until the current `Terms.currentVersion` is accepted, and again if the
/// terms materially change. The user must tick the (un-pre-checked) box and tap Accept; the accepted
/// version is then stored locally, the on-device equivalent of a consent record. See `Terms` / `TERMS.md`.
struct TermsGateView: View {
    let onAccept: () -> Void
    /// One flag per `Terms.attestations` entry; every one must be ticked before Accept enables.
    @State private var checks: [Bool] = Array(repeating: false, count: Terms.attestations.count)
    @State private var showingFullTerms = false

    private var allChecked: Bool { checks.allSatisfy { $0 } }

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Before you use NOOP")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityIdentifier("noop.terms.title")
                    Text("Please read the points below, then confirm each statement.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("noop.terms.intro")
                }
                .padding(.top, 36)
                .padding(.bottom, 22)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Terms.points, id: \.0) { point in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.0)
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(point.1)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Rectangle()
                            .fill(StrandPalette.hairline)
                            .frame(height: 1)
                            .padding(.vertical, 2)

                        Text("Please confirm each of these:")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)

                        ForEach(Array(Terms.attestations.enumerated()), id: \.offset) { idx, line in
                            Toggle(isOn: Binding(get: { checks[idx] }, set: { checks[idx] = $0 })) {
                                Text(line)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            #if os(macOS)
                            .toggleStyle(.checkbox)   // iOS falls back to the default switch toggle
                            #endif
                            .accessibilityIdentifier("noop.terms.attestation.\(idx)")
                        }

                        Button {
                            showingFullTerms = true
                        } label: {
                            Label("Read the full terms", systemImage: "doc.text")
                                .font(StrandFont.headline)
                        }
                        .buttonStyle(.bordered)

                        Text("The full terms are included with this build and open offline. This is not legal advice.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 18)
                }

                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)

                Button(action: onAccept) {
                    Text("Accept & Continue")
                        .frame(maxWidth: .infinity)
                }
                // The system prominent style can resolve both the fill and label to white when NOOP's
                // dark-mode accent is white. The house style explicitly pairs accent with accentInk.
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(!allChecked)
                .accessibilityIdentifier("noop.terms.accept")
                .keyboardShortcut(.defaultAction)
                .padding(26)
            }
            // The desktop gate stays compact, but an iPhone should use its full safe-area height.
            // Sharing the 720pt desktop cap left a large empty band around the column and needlessly
            // shortened the legal-copy viewport, so an attestation appeared clipped by the footer.
            #if os(iOS)
            .frame(maxWidth: 560, maxHeight: .infinity)
            #else
            .frame(maxWidth: 560, maxHeight: 720)
            #endif
        }
        .sheet(isPresented: $showingFullTerms) {
            BundledTermsView()
        }
    }
}

private struct BundledTermsView: View {
    @Environment(\.dismiss) private var dismiss

    private var terms: String {
        guard let url = Bundle.main.url(forResource: "TERMS", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "The bundled terms could not be opened. Do not accept until you can review TERMS.md in the NOOP source package.")
        }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(terms)
                    .font(StrandFont.mono(11))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Terms of use")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
