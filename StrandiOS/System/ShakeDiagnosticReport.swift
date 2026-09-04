#if os(iOS)
import SwiftUI
import StrandDesign
import UIKit

/// Owns the shake-created app report from consent through native ZIP sharing.
///
/// This is intentionally separate from TestCentreReport: a shake report should offer a file to any
/// support channel the user chooses, not automatically open a GitHub issue after the share sheet closes.
@MainActor
final class ShakeDiagnosticReportController: ObservableObject {
    enum Phase: Equatable {
        case explanation
        case building
        case review
        case sharing
        case failed
    }

    @Published var isPresented = false
    @Published private(set) var phase: Phase = .explanation
    @Published private(set) var entries: [FileExport.BundleEntry] = []
    @Published private(set) var statusMessage: String?

    private var lastShakeUptime: TimeInterval = 0
    #if DEBUG
    private var didRequestDemo = false
    #endif

    var preventsDismissal: Bool {
        phase == .building || phase == .sharing
    }

    var attachmentRows: [(name: String, size: String)] {
        entries.map {
            (
                $0.name,
                ByteCountFormatter.string(
                    fromByteCount: Int64($0.data.count),
                    countStyle: .file
                )
            )
        }
    }

    /// A bounded review excerpt. App-session and MetricKit streams are named but intentionally not laid
    /// out as one giant SwiftUI Text (that can itself freeze CoreText on a large diagnostic payload).
    var reviewPreview: String {
        let full = ReportReviewGate(entries: entries).previewText
        let limit = 16_000
        guard full.count > limit else { return full }
        let half = limit / 2
        return String(full.prefix(half))
            + "\n\n[Preview shortened. The complete bounded files are listed above.]\n\n"
            + String(full.suffix(half))
    }

    func requestFromShake() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastShakeUptime >= 2, !isPresented else { return }
        lastShakeUptime = now
        phase = .explanation
        entries = []
        statusMessage = nil
        AppDiagnosticsRecorder.shared.record(
            "report.shake_detected",
            includeResourceSnapshot: true
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isPresented = true
    }

    #if DEBUG
    /// Deterministic simulator/UI-test entrypoint. Production builds can open this flow only from a
    /// physical shake; the launch argument and this method are compiled out of Release.
    func requestDemoIfNeeded() {
        guard !didRequestDemo,
              CommandLine.arguments.contains("--demo-app-report") else { return }
        didRequestDemo = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.requestFromShake()
        }
    }
    #endif

    func build(live: LiveState) {
        guard phase == .explanation || phase == .failed else { return }
        phase = .building
        statusMessage = nil
        AppDiagnosticsRecorder.shared.record(
            "report.build_requested",
            includeResourceSnapshot: true
        )

        Task { @MainActor [weak self, weak live] in
            guard let self, let live else { return }
            // File-size-only storage evidence is deliberate here. Full table COUNTs can compete with a
            // large database at exactly the moment the user is reporting a freeze.
            let storage = await TestCentreReport.storageProbe(repo: nil, live: live)
            let runtimeDiagnostics = await AppDiagnosticsRecorder.shared.diagnosticEntriesAsync()
            let model = UserDefaults.standard.string(forKey: "selectedWhoopModel")
            let assembled = TestBundleAssembler.assemble(
                profile: .master,
                live: live,
                storage: storage,
                strapModel: model,
                purpose: .appHang,
                runtimeDiagnostics: runtimeDiagnostics
            )
            guard !assembled.isEmpty else {
                self.phase = .failed
                self.statusMessage = "NOOP could not prepare the report. Try again after reopening the app."
                return
            }
            self.entries = assembled
            self.phase = .review
            AppDiagnosticsRecorder.shared.record(
                "report.build_completed",
                fields: ["file_count": String(assembled.count)]
            )
        }
    }

    func share() {
        guard phase == .review, !entries.isEmpty else { return }
        phase = .sharing
        statusMessage = nil
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let name = FileExport.bundleName(
            profile: "app-report",
            platform: "ios",
            version: version
        )
        let reportEntries = entries
        AppDiagnosticsRecorder.shared.record(
            "report.share_requested",
            fields: ["file_count": String(reportEntries.count)]
        )
        Task { @MainActor [weak self] in
            let result = await FileExport.exportBundle(
                entries: reportEntries,
                suggestedName: name
            )
            guard let self else { return }
            if result == nil {
                self.phase = .failed
                self.statusMessage = "The ZIP could not be created. No report was shared."
            } else {
                self.phase = .review
                self.statusMessage = "Share sheet opened for \(name)"
            }
        }
    }

    func close() {
        guard !preventsDismissal else { return }
        isPresented = false
    }

    func didDismiss() {
        phase = .explanation
        entries = []
        statusMessage = nil
    }
}

/// A zero-polling shake detector. UIKit sends a physical/simulator shake through the responder chain,
/// so this consumes no accelerometer sampling and has no idle battery cost.
struct DeviceShakeDetector: UIViewControllerRepresentable {
    let onShake: @MainActor () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        ShakeViewController(onShake: onShake)
    }

    func updateUIViewController(_ controller: ShakeViewController, context: Context) {
        controller.onShake = onShake
    }

    final class ShakeViewController: UIViewController {
        var onShake: @MainActor () -> Void

        init(onShake: @escaping @MainActor () -> Void) {
            self.onShake = onShake
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override var canBecomeFirstResponder: Bool { true }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reclaimFirstResponder),
                name: UIResponder.keyboardDidHideNotification,
                object: nil
            )
        }

        override func viewWillDisappear(_ animated: Bool) {
            NotificationCenter.default.removeObserver(
                self,
                name: UIResponder.keyboardDidHideNotification,
                object: nil
            )
            resignFirstResponder()
            super.viewWillDisappear(animated)
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard motion == .motionShake else {
                super.motionEnded(motion, with: event)
                return
            }
            onShake()
        }

        @objc private func reclaimFirstResponder() {
            // A text field correctly owns first responder while the keyboard is visible. Reclaim only
            // after UIKit confirms the keyboard has closed, so installing diagnostics never disrupts input.
            becomeFirstResponder()
        }
    }
}

struct ShakeDiagnosticReportSheet: View {
    @ObservedObject var controller: ShakeDiagnosticReportController
    let live: LiveState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                StrandPalette.surfaceBase.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                        switch controller.phase {
                        case .explanation:
                            explanation
                        case .building:
                            building
                        case .review, .sharing:
                            review
                        case .failed:
                            failure
                        }
                    }
                    .screenPadding()
                    .padding(.vertical, NoopMetrics.space5)
                }
            }
            .navigationTitle("App report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        controller.close()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(controller.preventsDismissal)
                    .accessibilityLabel("Close app report")
                }
            }
        }
        .interactiveDismissDisabled(controller.preventsDismissal)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            reportHeader(
                symbol: "waveform.path.ecg.rectangle",
                title: "Capture the freeze",
                detail: "NOOP will package the evidence already on this iPhone. Nothing is uploaded automatically."
            )

            NoopCard {
                VStack(alignment: .leading, spacing: 0) {
                    evidenceRow(
                        symbol: "speedometer",
                        title: "Performance",
                        detail: "Scroll hitches, main-thread stalls, memory pressure, storage size and thermal state"
                    )
                    Divider().overlay(StrandPalette.hairline)
                    evidenceRow(
                        symbol: "rectangle.stack",
                        title: "Recent path",
                        detail: "App lifecycle and fixed screen names from this and the previous launch"
                    )
                    Divider().overlay(StrandPalette.hairline)
                    evidenceRow(
                        symbol: "waveform.path.ecg",
                        title: "Band status",
                        detail: "The existing redacted connection and sync log"
                    )
                    Divider().overlay(StrandPalette.hairline)
                    evidenceRow(
                        symbol: "apple.logo",
                        title: "Apple diagnostics",
                        detail: "Delayed system hang or crash reports, when iOS has made them available"
                    )
                }
            }

            Label {
                Text("Not included: your health database, raw sensor history, screenshots, account credentials or API keys.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(StrandPalette.statusPositive)
            }

            VStack(spacing: NoopMetrics.space3) {
                NoopButton(
                    "Build report",
                    systemImage: "doc.zipper",
                    kind: .primary,
                    fullWidth: true
                ) {
                    controller.build(live: live)
                }
                NoopButton(
                    "Cancel",
                    systemImage: "xmark",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    controller.close()
                    dismiss()
                }
            }
        }
    }

    private var building: some View {
        VStack(spacing: NoopMetrics.space5) {
            ProgressView()
                .controlSize(.large)
                .tint(StrandPalette.accent)
            Text("Preparing a private ZIP")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Reading bounded logs and file-size metadata. Your health database stays on this iPhone.")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space6)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            reportHeader(
                symbol: "checkmark.circle",
                title: "Report ready",
                detail: "Review the attachment list, then choose where to send or save the ZIP."
            )

            NoopCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(controller.attachmentRows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().overlay(StrandPalette.hairline) }
                        HStack(spacing: 12) {
                            Image(systemName: fileSymbol(row.name))
                                .foregroundStyle(StrandPalette.accent)
                                .frame(width: 22)
                            Text(row.name)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text(row.size)
                                .font(StrandFont.mono)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(.vertical, 11)
                    }
                }
            }

            if !controller.reviewPreview.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("REDACTED PREVIEW")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    NoopCard {
                        ScrollView {
                            Text(controller.reviewPreview)
                                .font(StrandFont.mono)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 260)
                    }
                }
            }

            if let message = controller.statusMessage {
                Text(message)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            NoopButton(
                controller.phase == .sharing ? "Preparing ZIP" : "Share ZIP",
                systemImage: "square.and.arrow.up",
                kind: .primary,
                fullWidth: true
            ) {
                controller.share()
            }
            .disabled(controller.phase == .sharing)
        }
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            reportHeader(
                symbol: "exclamationmark.triangle",
                title: "Report not ready",
                detail: controller.statusMessage ?? "NOOP could not prepare the ZIP."
            )
            NoopButton(
                "Try again",
                systemImage: "arrow.clockwise",
                kind: .primary,
                fullWidth: true
            ) {
                controller.build(live: live)
            }
            NoopButton(
                "Close",
                systemImage: "xmark",
                kind: .secondary,
                fullWidth: true
            ) {
                controller.close()
                dismiss()
            }
        }
    }

    private func reportHeader(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 48, height: 48)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 4) {
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

    private func evidenceRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
    }

    private func fileSymbol(_ name: String) -> String {
        if name.hasSuffix(".json") || name.hasSuffix(".jsonl") {
            return "curlybraces"
        }
        if name.hasSuffix(".txt") { return "doc.text" }
        return "doc"
    }
}
#endif
