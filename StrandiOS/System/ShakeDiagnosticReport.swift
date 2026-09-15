#if os(iOS)
import SwiftUI
import StrandDesign
import UIKit

private func appReportText(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

private func appReportFormat(
    _ key: String.LocalizationValue,
    _ arguments: CVarArg...
) -> String {
    String(
        format: appReportText(key),
        locale: Locale.current,
        arguments: arguments
    )
}

/// Owns the shake-created app report from consent through durable feedback delivery.
///
/// This is intentionally separate from TestCentreReport: a shake report goes only through the
/// reviewed feedback channel and never opens a GitHub issue after delivery.
@MainActor
final class ShakeDiagnosticReportController: ObservableObject {
    enum Phase: Equatable {
        case explanation
        case building
        case review
        case queued
        case uploading
        case retryScheduled
        case sent
        case cancelling
        case cancelled
        case failed
    }

    @Published var isPresented = false
    @Published private(set) var phase: Phase = .explanation
    @Published private(set) var entries: [FileExport.BundleEntry] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var userNote = ""
    @Published private(set) var includeScreenshot = false
    @Published private(set) var isScreenshotCaptureInProgress = false
    @Published private(set) var uploadProgress = 0.0
    @Published private(set) var receipt: String?

    private var lastShakeUptime: TimeInterval?
    private var capturedScreenPNG: Data?
    private var screenshotCaptureTask: Task<Void, Never>?
    private var screenshotCaptureGuard = FeedbackScreenshotCaptureGuard()
    private var feedbackID: UUID?
    private var deliveryAttempted = false
    private var enqueueTask: Task<Void, Never>?
    private var cancelRequestedBeforeQueue = false
    #if DEBUG
    private var didRequestDemo = false
    #endif

    init() {
        Task { @MainActor [weak self] in
            guard let self,
                  let record = try? await FeedbackOutbox.shared.latestActionable(),
                  !self.isPresented,
                  self.feedbackID == nil,
                  self.phase == .explanation else { return }
            self.feedbackID = record.id
            self.deliveryAttempted = true
            self.apply(record)
        }
    }

    var preventsDismissal: Bool {
        phase == .building
    }

    var isDeliveryFailure: Bool {
        deliveryAttempted
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

    var screenPreviewImage: UIImage? {
        guard let entry = entries.first(where: {
            $0.name == DisplayScreenshot.bundleName
        }) else {
            return nil
        }
        return UIImage(data: entry.data)
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
        if feedbackID != nil {
            isPresented = true
            refreshFeedbackState()
            return
        }

        invalidateScreenshotCapture(clearSelection: true)
        phase = .explanation
        entries = []
        statusMessage = nil
        userNote = ""
        AppDiagnosticsRecorder.shared.record("report.capture_prepared")
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

    func updateScreenshotInclusion(_ isIncluded: Bool) {
        guard phase == .explanation
                || (phase == .failed && !deliveryAttempted) else {
            return
        }
        invalidateScreenshotCapture(clearSelection: false)
        includeScreenshot = isIncluded
        guard isIncluded else { return }

        let token = screenshotCaptureGuard.begin()
        isScreenshotCaptureInProgress = true
        AppDiagnosticsRecorder.shared.record("report.screen_snapshot_requested")
        screenshotCaptureTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.screenshotCaptureGuard.accepts(
                      token,
                      isPresented: self.isPresented,
                      isOptedIn: self.includeScreenshot
                  ) else {
                return
            }

            let rawPNG = DisplayScreenshot.captureFeedbackPNG()
            let sanitized = await Task.detached(priority: .userInitiated) {
                TestBundleAssembler.appReportScreenshotEntry(rawPNG)?.data
            }.value
            guard !Task.isCancelled,
                  self.screenshotCaptureGuard.accepts(
                      token,
                      isPresented: self.isPresented,
                      isOptedIn: self.includeScreenshot
                  ) else {
                return
            }

            self.screenshotCaptureTask = nil
            self.isScreenshotCaptureInProgress = false
            self.capturedScreenPNG = sanitized
            if sanitized == nil {
                self.includeScreenshot = false
            }
            AppDiagnosticsRecorder.shared.record(
                "report.screen_snapshot_captured",
                fields: [
                    "available": sanitized == nil ? "false" : "true",
                ]
            )
        }
    }

    func build(live: LiveState, repo: Repository) {
        guard (phase == .explanation || phase == .failed),
              !isScreenshotCaptureInProgress else {
            return
        }
        phase = .building
        statusMessage = nil
        let note = userNote
        let screenshot = includeScreenshot ? capturedScreenPNG : nil
        AppDiagnosticsRecorder.shared.record(
            "report.build_requested",
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
                self.statusMessage = appReportText("app_report_error_prepare")
                AppDiagnosticsRecorder.shared.record(
                    "report.build_failed",
                    fields: ["reason": "empty_bundle"],
                    includeResourceSnapshot: true
                )
                return
            }
            self.entries = assembled
            self.phase = .review
            AppDiagnosticsRecorder.shared.record("report.build_completed")
        }
    }

    func removeScreenAttachment() {
        guard phase == .review, includesScreenAttachment else { return }
        entries.removeAll { $0.name == DisplayScreenshot.bundleName }
        invalidateScreenshotCapture(clearSelection: true)
        statusMessage = appReportText("app_report_status_snapshot_removed")
        AppDiagnosticsRecorder.shared.record("report.review_updated")
    }

    func sendFeedback() {
        guard phase == .review, !entries.isEmpty else { return }
        deliveryAttempted = true
        phase = .queued
        statusMessage = appReportText("app_report_status_securing")
        uploadProgress = 0
        receipt = nil
        cancelRequestedBeforeQueue = false
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let reportEntries = entries
        enqueueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.enqueueTask = nil }
            do {
                let record = try await FeedbackUploadCoordinator.shared.enqueue(
                    entries: reportEntries,
                    appVersion: version
                )
                self.feedbackID = record.id
                if self.cancelRequestedBeforeQueue || Task.isCancelled {
                    self.phase = .cancelling
                    self.statusMessage = appReportText(
                        "app_report_status_canceling"
                    )
                    await FeedbackUploadCoordinator.shared.cancel(id: record.id)
                    if let latest = await FeedbackUploadCoordinator.shared.record(
                        id: record.id
                    ) {
                        self.apply(latest)
                    }
                    return
                }
                self.apply(record)
            } catch {
                if self.cancelRequestedBeforeQueue || Task.isCancelled {
                    self.phase = .cancelled
                    self.statusMessage = appReportText(
                        "app_report_status_cancel_before_queue"
                    )
                    return
                }
                self.phase = .failed
                self.statusMessage = appReportText("app_report_error_queue")
                FeedbackDiagnostics.record(
                    state: .failed,
                    outcome: .failed,
                    failureKind: .archiveIntegrity
                )
            }
        }
    }

    func refreshFeedbackState() {
        guard let feedbackID else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let record = await FeedbackUploadCoordinator.shared.record(
                      id: feedbackID
                  ) else { return }
            self.apply(record)
        }
    }

    func retryFeedback() {
        guard deliveryAttempted else { return }
        phase = .queued
        statusMessage = appReportText("app_report_status_queued")
        uploadProgress = 0
        if let feedbackID {
            Task {
                await FeedbackUploadCoordinator.shared.retry(id: feedbackID)
            }
        } else {
            phase = .review
            sendFeedback()
        }
    }

    func cancelFeedback() {
        guard let feedbackID else {
            cancelRequestedBeforeQueue = true
            enqueueTask?.cancel()
            phase = enqueueTask == nil ? .cancelled : .cancelling
            statusMessage = enqueueTask == nil
                ? appReportText("app_report_status_cancel_before_queue")
                : appReportText("app_report_status_cancel_queueing")
            return
        }
        phase = .cancelling
        statusMessage = appReportText("app_report_status_canceling")
        Task {
            await FeedbackUploadCoordinator.shared.cancel(id: feedbackID)
        }
    }

    func close() {
        guard !preventsDismissal else { return }
        isPresented = false
    }

    func didDismiss() {
        entries = []
        userNote = ""
        invalidateScreenshotCapture(clearSelection: true)
        let retainsDelivery =
            feedbackID != nil && phase != .sent && phase != .cancelled
        if retainsDelivery {
            return
        }
        phase = .explanation
        statusMessage = nil
        feedbackID = nil
        if enqueueTask == nil {
            cancelRequestedBeforeQueue = false
        }
        deliveryAttempted = false
        uploadProgress = 0
        receipt = nil
    }

    private func invalidateScreenshotCapture(clearSelection: Bool) {
        screenshotCaptureGuard.invalidate()
        screenshotCaptureTask?.cancel()
        screenshotCaptureTask = nil
        isScreenshotCaptureInProgress = false
        capturedScreenPNG = nil
        if clearSelection {
            includeScreenshot = false
        }
    }

    private func apply(_ record: FeedbackOutboxRecord) {
        uploadProgress = record.uploadProgress
        receipt = record.receipt
        switch record.state {
        case .queued, .reserving:
            phase = .queued
            statusMessage = appReportText("app_report_status_queued")
        case .uploading:
            phase = .uploading
            statusMessage = appReportText("app_report_status_uploading")
        case .completing:
            phase = .uploading
            uploadProgress = 1
            statusMessage = appReportText("app_report_status_confirming")
        case .retryScheduled:
            phase = .retryScheduled
            statusMessage = record.cancelRequested
                ? appReportText("app_report_status_cancel_retry_scheduled")
                : appReportText("app_report_status_retry_scheduled")
        case .sent:
            phase = .sent
            statusMessage = record.localArchiveIsRemoved
                ? appReportText("app_report_status_sent")
                : appReportText("app_report_status_sent_cleanup_pending")
        case .failed:
            phase = .failed
            statusMessage = record.cancelRequested
                ? appReportText("app_report_error_cancel_failed")
                : appReportText("app_report_error_delivery")
        case .cancelling:
            phase = .cancelling
            statusMessage = appReportText("app_report_status_canceling")
        case .cancelled:
            phase = .cancelled
            statusMessage = record.localArchiveIsRemoved
                ? appReportText("app_report_status_canceled")
                : appReportText("app_report_status_canceled_cleanup_pending")
        }
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
                        case .review:
                            review
                        case .queued, .uploading, .retryScheduled, .sent,
                                .cancelling, .cancelled:
                            delivery
                        case .failed:
                            failure
                        }
                    }
                    .screenPadding()
                    .padding(.vertical, NoopMetrics.space5)
                }
            }
            .navigationTitle(appReportText("app_report_title"))
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
                    .accessibilityLabel(
                        appReportText("app_report_close_content_description")
                    )
                }
            }
        }
        .interactiveDismissDisabled(controller.preventsDismissal)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .onReceive(
            NotificationCenter.default.publisher(
                for: .feedbackOutboxDidChange
            )
        ) { _ in
            controller.refreshFeedbackState()
        }
        .task {
            controller.refreshFeedbackState()
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            reportHeader(
                symbol: "waveform.path.ecg.rectangle",
                title: appReportText("app_report_capture_title"),
                detail: appReportText("app_report_capture_detail")
            )

            NoopCard {
                VStack(alignment: .leading, spacing: 0) {
                    evidenceRow(
                        symbol: "speedometer",
                        title: appReportText(
                            "app_report_evidence_performance_title"
                        ),
                        detail: appReportText(
                            "app_report_evidence_performance_detail"
                        )
                    )
                    Divider().overlay(StrandPalette.hairline)
                    evidenceRow(
                        symbol: "rectangle.stack",
                        title: appReportText(
                            "app_report_evidence_recent_path_title"
                        ),
                        detail: appReportText(
                            "app_report_evidence_recent_path_detail"
                        )
                    )
                    Divider().overlay(StrandPalette.hairline)
                    evidenceRow(
                        symbol: "cylinder",
                        title: appReportText(
                            "app_report_evidence_data_pipeline_title"
                        ),
                        detail: appReportText(
                            "app_report_evidence_data_pipeline_detail"
                        )
                    )
                    Divider().overlay(StrandPalette.hairline)
                    evidenceRow(
                        symbol: "waveform.path.ecg",
                        title: appReportText(
                            "app_report_evidence_band_status_title"
                        ),
                        detail: appReportText(
                            "app_report_evidence_band_status_detail"
                        )
                    )
                    Divider().overlay(StrandPalette.hairline)
                    evidenceRow(
                        symbol: "apple.logo",
                        title: appReportText(
                            "app_report_evidence_apple_title"
                        ),
                        detail: appReportText(
                            "app_report_evidence_apple_detail"
                        )
                    )
                }
            }

            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text(appReportText("app_report_user_note_title"))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(appReportText("app_report_user_note_detail"))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(
                        appReportText("app_report_user_note_placeholder"),
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
                        set: { controller.updateScreenshotInclusion($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appReportText("app_report_include_snapshot"))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(
                            controller.hasCapturedScreen
                                ? appReportText(
                                    "app_report_snapshot_available_detail"
                                )
                                : appReportText(
                                    "app_report_snapshot_unavailable_detail"
                                )
                        )
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(StrandPalette.statusPositive)
                .accessibilityIdentifier("noop.app-report.include-screenshot")
            }

            Label {
                Text(appReportText("app_report_privacy_detail_apple"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(StrandPalette.statusPositive)
            }

            VStack(spacing: NoopMetrics.space3) {
                NoopButton(
                    "app_report_build",
                    systemImage: "doc.zipper",
                    kind: .primary,
                    fullWidth: true
                ) {
                    controller.build(live: live, repo: repo)
                }
                .disabled(controller.isScreenshotCaptureInProgress)
                NoopButton(
                    "app_report_cancel",
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
            Text(appReportText("app_report_preparing_title"))
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(appReportText("app_report_preparing_detail"))
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
                title: appReportText("app_report_ready_title"),
                detail: appReportText("app_report_ready_detail")
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

            if let image = controller.screenPreviewImage {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text(appReportText("app_report_snapshot_preview_title"))
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(StrandPalette.surfaceBase)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    StrandPalette.hairline,
                                    lineWidth: 1
                                )
                        }
                        .accessibilityLabel(
                            appReportText(
                                "app_report_snapshot_preview_content_description"
                            )
                        )
                        .accessibilityIdentifier(
                            "noop.app-report.screenshot-preview"
                        )
                }
            }

            if !controller.reviewPreview.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text(appReportText("app_report_redacted_preview"))
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

            Label {
                Text(
                    appReportText("app_report_send_disclosure")
                )
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(StrandPalette.statusPositive)
            }

            NoopButton(
                "app_report_send_feedback",
                systemImage: "paperplane.fill",
                kind: .primary,
                fullWidth: true
            ) {
                controller.sendFeedback()
            }
            .accessibilityIdentifier("noop.app-report.send")

            if controller.includesScreenAttachment {
                NoopButton(
                    "app_report_remove_snapshot",
                    systemImage: "photo.badge.minus",
                    kind: .secondary,
                    fullWidth: true
                ) {
                    controller.removeScreenAttachment()
                }
            }
        }
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            reportHeader(
                symbol: deliverySymbol,
                title: deliveryTitle,
                detail: controller.statusMessage
                    ?? appReportText("app_report_delivery_in_progress")
            )

            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if controller.phase == .uploading {
                        ProgressView(value: controller.uploadProgress)
                            .progressViewStyle(.linear)
                            .tint(StrandPalette.accent)
                            .accessibilityLabel(
                                appReportText("app_report_upload_progress_label")
                            )
                            .accessibilityValue(
                                appReportFormat(
                                    "app_report_progress_percent",
                                    Int(
                                        (controller.uploadProgress * 100)
                                            .rounded()
                                    )
                                )
                            )
                            .accessibilityIdentifier(
                                "noop.app-report.upload-progress"
                            )
                        Text(
                            appReportFormat(
                                "app_report_progress_percent",
                                Int(
                                    (controller.uploadProgress * 100)
                                        .rounded()
                                )
                            )
                        )
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                    } else if controller.phase == .queued
                                || controller.phase == .cancelling {
                        ProgressView()
                            .tint(StrandPalette.accent)
                            .accessibilityLabel(
                                controller.phase == .cancelling
                                    ? appReportText(
                                        "app_report_cancel_progress_label"
                                    )
                                    : appReportText(
                                        "app_report_queued_progress_label"
                                    )
                            )
                    }

                    if controller.phase == .sent,
                       let receipt = controller.receipt {
                        Text(
                            appReportFormat(
                                "app_report_receipt",
                                receipt
                            )
                        )
                            .font(StrandFont.mono)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier(
                                "noop.app-report.receipt"
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            switch controller.phase {
            case .retryScheduled:
                NoopButton(
                    "app_report_retry_now",
                    systemImage: "arrow.clockwise",
                    kind: .primary,
                    fullWidth: true
                ) {
                    controller.retryFeedback()
                }
                NoopButton(
                    "app_report_cancel_send",
                    systemImage: "xmark",
                    kind: .destructive,
                    fullWidth: true
                ) {
                    controller.cancelFeedback()
                }
            case .sent, .cancelled:
                NoopButton(
                    "app_report_close",
                    systemImage: "xmark",
                    kind: .primary,
                    fullWidth: true
                ) {
                    controller.close()
                    dismiss()
                }
            case .queued, .uploading:
                NoopButton(
                    "app_report_cancel_send",
                    systemImage: "xmark",
                    kind: .destructive,
                    fullWidth: true
                ) {
                    controller.cancelFeedback()
                }
            case .cancelling:
                NoopButton(
                    "app_report_canceling_title",
                    systemImage: "hourglass",
                    kind: .secondary,
                    fullWidth: true
                ) {}
                .disabled(true)
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("noop.app-report.delivery")
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            reportHeader(
                symbol: "exclamationmark.triangle",
                title: controller.isDeliveryFailure
                    ? appReportText("app_report_send_failed_title")
                    : appReportText("app_report_not_ready_title"),
                detail: controller.statusMessage
                    ?? appReportText("app_report_prepare_zip_fallback")
            )
            NoopButton(
                controller.isDeliveryFailure
                    ? "app_report_retry_now"
                    : "app_report_try_again",
                systemImage: "arrow.clockwise",
                kind: .primary,
                fullWidth: true
            ) {
                if controller.isDeliveryFailure {
                    controller.retryFeedback()
                } else {
                    controller.build(live: live, repo: repo)
                }
            }
            if controller.isDeliveryFailure {
                NoopButton(
                    "app_report_cancel_send",
                    systemImage: "xmark",
                    kind: .destructive,
                    fullWidth: true
                ) {
                    controller.cancelFeedback()
                }
            }
            NoopButton(
                "app_report_close",
                systemImage: "xmark",
                kind: .secondary,
                fullWidth: true
            ) {
                controller.close()
                dismiss()
            }
        }
    }

    private var deliveryTitle: String {
        switch controller.phase {
        case .queued:
            return appReportText("app_report_queued_title")
        case .uploading:
            return appReportText("app_report_uploading_title")
        case .retryScheduled:
            return appReportText("app_report_retry_scheduled_title")
        case .sent:
            return appReportText("app_report_sent_title")
        case .cancelling:
            return appReportText("app_report_canceling_title")
        case .cancelled:
            return appReportText("app_report_canceled_title")
        default:
            return appReportText("app_report_title")
        }
    }

    private var deliverySymbol: String {
        switch controller.phase {
        case .queued: return "tray.and.arrow.up"
        case .uploading: return "arrow.up.circle"
        case .retryScheduled: return "clock.arrow.circlepath"
        case .sent: return "checkmark.circle.fill"
        case .cancelling: return "hourglass"
        case .cancelled: return "xmark.circle"
        default: return "paperplane"
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
