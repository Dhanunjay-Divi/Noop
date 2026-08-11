import Foundation
import ZIPFoundation

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Cross-platform "save / share a file" helper.
///
/// - macOS uses `NSSavePanel` (sandbox-safe via the user-selected-file entitlement).
/// - iOS presents the system share sheet (`UIActivityViewController`) so the user can save the file
///   to Files, AirDrop it, or send it on — the idiomatic iOS way to get a file out of the sandbox.
enum FileExport {

    /// A short `yyMMdd-HHmm` wall-clock stamp for export filenames (#510 — maddognik's protocol RE),
    /// so a reporter who saves several strap logs / raw captures in a row gets sortable, non-colliding
    /// files (e.g. `noop-strap-log-260617-1042.txt`) instead of repeatedly overwriting one name.
    /// Locale-independent (POSIX) so the stamp is stable on every machine.
    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd-HHmm"
        return f.string(from: date)
    }

    /// Compose a timestamped suggested filename — `<prefix>-<yyMMdd-HHmm>.<ext>`
    /// (e.g. `timestampedName("noop-strap-log", ext: "txt")` → `noop-strap-log-260617-1042.txt`).
    static func timestampedName(_ prefix: String, ext: String) -> String {
        "\(prefix)-\(timestamp()).\(ext)"
    }

    /// Profile-tagged, self-describing bundle filename: `noop-<profile>-<platform>-v<version>-<yyMMdd-HHmm>.zip`
    /// (spec section 5.1). Self-describing at a glance so a maintainer knows the profile, platform and
    /// version before opening the zip. `timestampedName` keeps its old 2-arg form for the existing
    /// strap-log / raw-capture callers; this is the new bundle-name builder.
    static func bundleName(profile: String, platform: String, version: String, date: Date = Date()) -> String {
        "noop-\(profile)-\(platform)-v\(version)-\(timestamp(date)).zip"
    }

    /// Redact and bound a diagnostics/log text file, show the mandatory review confirmation, then let the
    /// user choose where it goes. This API is intentionally diagnostics-only; normal health-data exports
    /// continue to use their purpose-built exporters and consent surfaces.
    @MainActor
    static func exportText(_ text: String, suggestedName: String) {
        let input = BundleEntry(name: suggestedName, data: Data(text.utf8))
        guard let prepared = TestBundleAssembler.prepareDiagnostics([input]) else { return }
        confirmDiagnosticShare(prepared: prepared) {
            savePreparedDiagnosticEntries(prepared.entries, suggestedName: suggestedName)
        }
    }

    /// Clipboard is an export boundary too: scrub and bound first, then require the same explicit review.
    /// The caller never receives the unredacted intermediate bytes.
    @MainActor
    static func copyDiagnosticText(_ text: String, suggestedName: String = "report.txt") {
        let input = BundleEntry(name: suggestedName, data: Data(text.utf8))
        guard let prepared = TestBundleAssembler.prepareDiagnostics([input]),
              let safe = prepared.entries.first.flatMap({ String(data: $0.data, encoding: .utf8) }) else { return }
        confirmDiagnosticShare(prepared: prepared, actionLabel: "Copy") {
            PlatformPasteboard.copy(safe)
        }
    }

    /// Read an existing diagnostics/raw/support text file off-main, then share only the fail-closed,
    /// redacted and bounded copy. The source remains private and is never handed to the share sheet.
    @MainActor
    static func exportDiagnosticFile(at src: URL, suggestedName: String,
                                     normalizedName: String) async {
        guard let data = await Task.detached(priority: .userInitiated, operation: {
            try? Data(contentsOf: src)
        }).value else { return }
        let input = BundleEntry(name: normalizedName, data: data)
        guard let prepared = TestBundleAssembler.prepareDiagnostics([input]) else { return }
        confirmDiagnosticShare(prepared: prepared) {
            savePreparedDiagnosticEntries(prepared.entries, suggestedName: suggestedName)
        }
    }

    /// Let the user save / share an existing file at `src`. On macOS this copies to a chosen
    /// destination; on iOS it offers the file through the share sheet. `src` is owned by the caller
    /// (e.g. a Puffin capture inside the app's container) and is NOT deleted by the share-sheet
    /// completion handler — only files we staged ourselves get cleaned up.
    @MainActor
    static func exportFile(at src: URL, suggestedName: String? = nil) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? src.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch { /* best-effort */ }
        #else
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        present(activityItems: [src], cleanup: [])
        #endif
    }

    /// Export an existing diagnostic file and log together. Both inputs pass through the same fail-closed
    /// redaction + total-size cap, and the resulting file list/preview must be explicitly confirmed before
    /// the zip is staged for sharing. If the source is absent, the bounded log still ships on its own.
    @MainActor
    static func exportPair(file src: URL, fileSuggestedName: String,
                           text: String, textSuggestedName: String) async {
        let normalizedFileName = fileSuggestedName.lowercased().contains("raw-capture")
            ? "raw-capture.jsonl" : fileSuggestedName
        let normalizedTextName = textSuggestedName.lowercased().contains("strap-log")
            ? "report.txt" : textSuggestedName
        let entries = await Task.detached(priority: .userInitiated) { () -> [BundleEntry] in
            var entries = [BundleEntry(name: normalizedTextName, data: Data(text.utf8))]
            if FileManager.default.fileExists(atPath: src.path), let fileData = try? Data(contentsOf: src) {
                entries.insert(BundleEntry(name: normalizedFileName, data: fileData), at: 0)
            }
            return entries
        }.value
        guard let prepared = TestBundleAssembler.prepareDiagnostics(entries) else { return }
        let zipName = timestampedName("noop-export", ext: "zip")
        confirmDiagnosticShare(prepared: prepared) {
            Task { @MainActor in
                _ = await exportBundle(entries: prepared.entries, suggestedName: zipName)
            }
        }
    }

    /// Review summary for standalone diagnostics. Large raw streams are named rather than laid out; small
    /// text is previewed after redaction. The explicit second tap is the only path to save/share/copy.
    @MainActor
    private static func confirmDiagnosticShare(prepared: TestBundleAssembler.PreparedDiagnostics,
                                               actionLabel: String = "Share",
                                               action: @escaping @MainActor () -> Void) {
        let gate = ReportReviewGate(entries: prepared.entries)
        let fileLines = prepared.entries.map {
            "• \($0.name) (\(ByteCountFormatter.string(fromByteCount: Int64($0.data.count), countStyle: .file)))"
        }.joined(separator: "\n")
        var preview = gate.previewText
        let previewLimit = 12_000
        if preview.count > previewLimit {
            preview = String(preview.prefix(previewLimit)) + "\n…preview shortened; the bounded file is listed above."
        }
        let truncation = prepared.truncated
            ? "\nOlder diagnostic content was removed to stay below the 20 MB share limit."
            : ""
        let message = """
        NOOP removed device identifiers before preparing these diagnostics. Raw biometric readings and \
        timestamps may still be present. Confirm the recipient before continuing.\(truncation)

        \(fileLines)

        \(preview)
        """

        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Review diagnostic export"
        alert.informativeText = message
        alert.addButton(withTitle: actionLabel)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        action()
        #else
        guard let presenter = topViewController() else { return }
        let alert = UIAlertController(title: "Review diagnostic export", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: actionLabel, style: .default) { [weak alert] _ in
            // Wait for the review alert to leave the presentation stack before opening the share sheet;
            // otherwise UIKit can reject the second presentation as "already presenting".
            alert?.dismiss(animated: true) {
                Task { @MainActor in action() }
            }
        })
        presenter.present(alert, animated: true)
        #endif
    }

    /// Persist only already-prepared bytes. A multi-entry diagnostic is a zip; a single entry retains the
    /// requested friendly filename. This helper is reachable only after the confirmation above.
    @MainActor
    private static func savePreparedDiagnosticEntries(_ entries: [BundleEntry], suggestedName: String) {
        guard !entries.isEmpty else { return }
        if entries.count > 1 {
            let zipName = suggestedName.hasSuffix(".zip") ? suggestedName : timestampedName("noop-export", ext: "zip")
            Task { @MainActor in _ = await exportBundle(entries: entries, suggestedName: zipName) }
            return
        }
        let data = entries[0].data
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        do { try data.write(to: url, options: .atomic) } catch { return }
        present(activityItems: [url], cleanup: [url])
        #endif
    }

    #if os(iOS)
    @MainActor
    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared
                .connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { return nil }
        var presenter = root
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        return presenter
    }

    /// Present `UIActivityViewController` and, once it closes, best-effort remove the URLs in
    /// `cleanup` so staged exports don't accumulate in `temporaryDirectory` across runs.
    @MainActor
    private static func present(activityItems: [Any], cleanup: [URL], completion: (() -> Void)? = nil) {
        guard let root = topViewController() else { completion?(); return }
        // Present from the TOP-MOST controller, not the root (#455). When the caller is itself inside a
        // SwiftUI sheet — e.g. the Trends report is shown via `.sheet` — root already has that sheet
        // presented, so `root.present(...)` is a no-op ("already presenting…") and the share sheet never
        // appears. Climb the presentedViewController chain so the share sheet stacks on top of whatever's
        // up. (The Share-strap-log path worked only because Settings isn't a sheet — root had nothing on it.)
        let presenter = root
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if !cleanup.isEmpty || completion != nil {
            // Fires after the share sheet is dismissed (saved or cancelled). We clean up staged files and
            // then run `completion` (M1/#812: the Test Centre report opens its prefilled issue here, once
            // the share sheet is gone, so the in-app SafariVC presents with nothing else on screen).
            vc.completionWithItemsHandler = { _, _, _, _ in
                let fm = FileManager.default
                for url in cleanup where fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
                completion?()
            }
        }
        // iPad: anchor the popover to the screen centre to avoid a crash.
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }
    #endif

    // MARK: - Bundle export (Test Centre, spec section 5.1)

    /// A file destined for the zip bundle: its in-zip name plus the bytes. Text entries (report.txt,
    /// meta.json) are produced by the assembler; existing on-disk files (raw-capture, screenshot) are
    /// read into Data by the assembler. EVERY entry must already be redacted by the caller (section 5.3).
    /// Equatable so the assembler cap can assert an undersized bundle is returned untouched (section 5.4).
    struct BundleEntry: Equatable { let name: String; let data: Data }

    /// Zip `entries` into a single staged `.zip` under the temporary directory and return its URL, or nil
    /// if there are no entries. Pure file IO, no UI, so it is unit-testable. Uses ZIPFoundation's `Archive`
    /// which is available on macOS and iOS without shelling out. The caller presents the URL (NSSavePanel
    /// on macOS, share sheet on iOS) and cleans it up.
    static func zipData(entries: [BundleEntry], baseName: String) -> URL? {
        guard !entries.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(baseName).zip")
        try? FileManager.default.removeItem(at: url)
        guard let archive = try? Archive(url: url, accessMode: .create) else { return nil }
        for entry in entries {
            try? archive.addEntry(with: entry.name, type: .file, uncompressedSize: Int64(entry.data.count)) { position, size in
                let start = Int(position)
                let end = min(start + size, entry.data.count)
                return entry.data.subdata(in: start..<end)
            }
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Zip `entries` into one `.zip` and hand it to the user (NSSavePanel on macOS, share sheet on iOS).
    /// EVERY entry must already be redacted by the caller (section 5.3); the 20 MB cap (section 5.4) is the
    /// assembler's job before it calls here. Returns the staged / saved zip URL, nil on cancel or failure.
    @MainActor @discardableResult
    static func exportBundle(entries: [BundleEntry], suggestedName: String,
                             completion: (() -> Void)? = nil) async -> URL? {
        let base = suggestedName.hasSuffix(".zip") ? String(suggestedName.dropLast(4)) : suggestedName
        guard let staged = await Task.detached(priority: .userInitiated, operation: {
            zipData(entries: entries, baseName: base)
        }).value else { completion?(); return nil }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else {
            try? FileManager.default.removeItem(at: staged)
            return nil
        }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: staged, to: dest)
        } catch {
            try? fm.removeItem(at: staged)
            return nil
        }
        try? fm.removeItem(at: staged)
        return dest
        #else
        present(activityItems: [staged], cleanup: [staged], completion: completion)
        return staged
        #endif
    }
}
