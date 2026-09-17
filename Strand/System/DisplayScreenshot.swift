import Foundation
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

// Captures screen pixels as PNG bytes for the Display & Performance test bundle or, only after a
// separate explicit opt-in, for the transient app-report attachment. The feedback boundary strips
// PNG metadata before review so pixels cannot carry hidden EXIF, text, timestamp, or private chunks.
//
// The PNG is BINARY image bytes, not a text line, so it is NOT run through redactPii (that is correct and
// intentional - redaction scrubs text identifiers, not pixels). The screenshot IS covered by the mandatory
// review-before-send gate: the report never ships until the user taps Send feedback on the review
// sheet, and the gate names the attachment. Test Centre captures only for an enabled screenshot
// profile. The app-report controller requests its separate underlying-content capture only when the
// user enables that attachment and discards it on opt-out or dismissal.

enum DisplayScreenshot {

    /// The in-zip name of the captured screenshot.
    static let bundleName = "screenshot.png"

    /// Capture the key window as PNG bytes, or nil if there is no window to capture / the render failed.
    /// Called on the main thread (the Report button tap path), so it can touch UIKit / AppKit directly.
    @MainActor
    static func capturePNG() -> Data? {
        #if os(iOS)
        guard let window = foregroundWindow() else { return nil }
        return capture(view: window)
        #elseif os(macOS)
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first,
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// Captures the presenting app content beneath the report sheet. Callers must invoke this only
    /// after the user explicitly opts into the feedback screenshot.
    @MainActor
    static func captureFeedbackPNG() -> Data? {
        guard let window = foregroundWindow(),
              let rootView = window.rootViewController?.view,
              rootView.bounds.width > 0,
              rootView.bounds.height > 0 else {
            return nil
        }
        return capture(view: rootView)
    }

    @MainActor
    private static func foregroundWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first
    }

    @MainActor
    private static func capture(view: UIView) -> Data? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            // Preserve the visible frame without forcing a relayout at the reporting boundary.
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        return image.pngData()
    }
    #endif
}
