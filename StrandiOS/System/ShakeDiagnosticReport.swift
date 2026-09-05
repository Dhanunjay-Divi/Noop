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
    @Published private(set) var userNote = ""
    @Published var includeScreenshot = false

    private var lastShakeUptime: TimeInterval?
    private var capturedScreenPNG: Data?
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

    var hasCapturedScreen: Bool {
        capturedScreenPNG != nil
    }

    var includesScreenAttachment: Bool {
        entries.contains { $0.name == DisplayScreenshot.bundleName }
    }

    var userNoteCountLabel: String {
        "\(userNote.count)/\(TestBundleAssembler.maxUserNoteCharacters)"
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
        guard !isPresented,
              lastShakeUptime.map({ now - $0 >= 2 }) ?? true else { return }
        lastShakeUptime = now

        // Persist the trigger before asking UIKit to render the visible hierarchy. If the render path is
        // itself slow or broken, the session still proves exactly when the user reported the problem and
        // records the process resources at that edge.
        AppDiagnosticsRecorder.shared.record(
            "report.shake_detected",
            includeResourceSnapshot: true
        )

        // Capture the frame before presenting this sheet, otherwise the report UI itself would obscure the
        // screen the user is trying to explain. The bytes stay transient in memory, default to excluded,
        // and are discarded on dismissal unless the user explicitly turns the attachment on and shares.
        capturedScreenPNG = TestBundleAssembler.appReportScreenshotEntry(
            DisplayScreenshot.capturePNG()
        )?.data
        phase = .explanation
        entries = []
        statusMessage = nil
        userNote = ""
        includeScreenshot = false
        AppDiagnosticsRecorder.shared.record(
            "report.screen_snapshot_captured",
            fields: [
                "available": capturedScreenPNG == nil ? "false" : "true",
            ]
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

    func updateUserNote(_ value: String) {
        userNote = TestBundleAssembler.boundedUserNoteInput(value)
    }

    func build(live: LiveState, repo: Repository) {
        guard phase == .explanation || phase == .failed else { return }
        phase = .building
        statusMessage = nil
        let note = userNote
        let screenshot = includeScreenshot ? capturedScreenPNG : nil
        AppDiagnosticsRecorder.shared.record(
            "report.build_requested",
            fields: [
                "user_context_provided":
                    note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true",
                "screen_snapshot_included": screenshot == nil ? "false" : "true",
            ],
            includeResourceSnapshot: true
        )

        Task { @MainActor [weak self, weak live] in
            guard let self, let live else { return }
            // Read only filesystem/resource counts here. A normal app report must not query or attach the
            // latest health timestamp, and full table COUNTs can compete with a large database at exactly
            // the moment the user is reporting a freeze.
            let storage = await TestCentreReport.storageProbe(
                repo: repo,
                live: live,
                includeRowCounts: false,
                includeHealthFrontier: false
            )
            let nowUnix = Date().timeIntervalSince1970
            let latestHrUnix = await repo.latestPersistedHRSampleTs()
            let bondState = live.encryptedBond
                ? "encrypted"
                : live.bonded
                ? "partial"
                : "none"
            let historySyncState: String
            if live.backfilling {
                switch HistorySyncDurableProgressPolicy.activity(
                    startedAt: live.historySyncStartedAt,
                    lastDurableProgressAt: live.historySyncLastDurableProgressAt,
                    now: nowUnix
                ) {
                case .starting: historySyncState = "starting"
                case .advancing: historySyncState = "advancing"
                case .waiting: historySyncState = "waiting"
                case .stalled: historySyncState = "stalled"
                }
            } else {
                historySyncState = "idle"
            }
            AppDiagnosticsRecorder.shared.record(
                "band.collection_snapshot",
                fields: [
                    "connection_state": live.connected ? "connected" : "disconnected",
                    "bond_state": bondState,
                    "history_sync_state": historySyncState,
                    "live_frame_freshness": AppDiagnosticsRecorder.freshnessBucket(
                        ageSeconds: live.lastFrameAtUnix.map { nowUnix - Double($0) }
                    ),
                    "collection_freshness": AppDiagnosticsRecorder.freshnessBucket(
                        ageSeconds: latestHrUnix.map { nowUnix - Double($0) }
                    ),
                ]
            )
            let runtimeDiagnostics = await AppDiagnosticsRecorder.shared.diagnosticEntriesAsync()
            let model = UserDefaults.standard.string(forKey: "selectedWhoopModel")
            let assembled = TestBundleAssembler.assemble(
                profile: .master,
                live: live,
                storage: storage,
                strapModel: model,
                purpose: .appHang,
                runtimeDiagnostics: runtimeDiagnostics,
                userNote: note,
                appReportScreenshotPNG: screenshot
            )
            guard !assembled.isEmpty else {
                self.phase = .failed
                self.statusMessage = "NOOP could not prepare the report. Try again after reopening the app."
                AppDiagnosticsRecorder.shared.record(
                    "report.build_failed",
                    fields: ["reason": "empty_bundle"],
                    includeResourceSnapshot: true
                )
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

    func removeScreenAttachment() {
        guard phase == .review, includesScreenAttachment else { return }
        entries.removeAll { $0.name == DisplayScreenshot.bundleName }
        includeScreenshot = false
        statusMessage = "Screen snapshot removed from this report."
        AppDiagnosticsRecorder.shared.record("report.screen_snapshot_removed")
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
                AppDiagnosticsRecorder.shared.record(
                    "report.share_completed",
                    fields: ["outcome": "archive_failed"]
                )
            } else {
                self.phase = .review
                self.statusMessage = "Share sheet opened for \(name)"
                AppDiagnosticsRecorder.shared.record(
                    "report.share_completed",
                    fields: ["outcome": "share_sheet_opened"]
                )
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
        userNote = ""
        includeScreenshot = false
        capturedScreenPNG = nil
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
    let repo: Repository
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
                title: "Capture what happened",
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
                        symbol: "cylinder",
                        title: "Data pipeline",
                        detail: "Database open and refresh timing, saved heart-rate freshness, and bounded sync outcomes"
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

            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("What felt buggy? (optional)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Briefly say what you tapped, what you expected, and what happened. Avoid names or contact details.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(
                        "Example: scrolling Health paused after I opened a metric",
                        text: Binding(
                            get: { controller.userNote },
                            set: { controller.updateUserNote($0) }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .font(StrandFont.body)
                    .padding(12)
                    .background(
                        StrandPalette.surfaceBase,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                    }
                    .accessibilityIdentifier("noop.app-report.user-note")

                    Text(verbatim: controller.userNoteCountLabel)
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            NoopCard {
                Toggle(
                    isOn: Binding(
                        get: { controller.includeScreenshot },
                        set: { controller.includeScreenshot = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include screen snapshot")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(
                            controller.hasCapturedScreen
                                ? "Shows the screen from just before this report opened. It may contain health values."
                                : "A screen snapshot was not available for this report."
                        )
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(StrandPalette.statusPositive)
                .disabled(!controller.hasCapturedScreen)
                .accessibilityIdentifier("noop.app-report.include-screenshot")
            }

            Label {
                Text("Never included: your health database, raw sensor history, account credentials or API keys. The temporary screen snapshot is discarded when you close this report.")
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
                    controller.build(live: live, repo: repo)
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
            Text("Reading bounded logs, file size and the latest saved heart-rate timestamp. Your health database stays on this iPhone.")
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

            if controller.includesScreenAttachment {
                NoopButton(
                    "Remove screen snapshot",
                    systemImage: "photo.badge.minus",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    controller.removeScreenAttachment()
                }
            }
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
                controller.build(live: live, repo: repo)
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
        if name.hasSuffix(".png") { return "photo" }
        if name.hasSuffix(".txt") { return "doc.text" }
        return "doc"
    }
}
#endif
