import SwiftUI
import StrandDesign

/// Project-level legal and attribution files that ship inside every Apple app bundle.
///
/// TermsGateView has always told users that `TERMS.md` ships with NOOP, but a bare Xcode app bundle
/// does not include repository-root files automatically. `project.yml` now copies these five files as
/// resources and this screen makes them reachable without leaving the app or requiring a network.
struct LegalDocumentsView: View {
    private enum Document: String, CaseIterable, Identifiable {
        case terms
        case license
        case notices
        case attribution
        case disclaimer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .terms: return String(localized: "Terms of use")
            case .license: return String(localized: "Source license")
            case .notices: return String(localized: "Project notices")
            case .attribution: return String(localized: "Attribution")
            case .disclaimer: return String(localized: "Disclaimer")
            }
        }

        var resource: (name: String, extension: String?) {
            switch self {
            case .terms: return ("TERMS", "md")
            case .license: return ("LICENSE", nil)
            case .notices: return ("NOTICE", nil)
            case .attribution: return ("ATTRIBUTION", "md")
            case .disclaimer: return ("DISCLAIMER", "md")
            }
        }
    }

    @State private var selection: Document = .terms

    var body: some View {
        ScreenScaffold(
            title: "Legal & acknowledgements",
            subtitle: "Project documents included with this build. Available offline."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                StrandCard {
                    HStack(spacing: NoopMetrics.space2) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Picker("Document", selection: $selection) {
                            ForEach(Document.allCases) { document in
                                Text(document.title).tag(document)
                            }
                        }
                        .pickerStyle(.menu)
                        Spacer(minLength: 0)
                    }
                }

                StrandCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text(selection.title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)

                        Text(documentText(selection))
                            .font(StrandFont.mono(11))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .navigationTitle(selection.title)
    }

    private func documentText(_ document: Document) -> String {
        let resource = document.resource
        guard let url = Bundle.main.url(forResource: resource.name, withExtension: resource.extension),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return String(localized: "This legal document is missing from the app bundle. Please report the build number from Settings so the packaging can be corrected.")
        }
        return text
    }
}
