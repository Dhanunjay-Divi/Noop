#if os(iOS)
import AVFoundation
import StrandDesign
import SwiftUI
import VisionKit

struct NutritionBarcodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    @State private var authorized =
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var permissionResolved =
        AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined

    var body: some View {
        NavigationStack {
            Group {
                if authorized,
                   DataScannerViewController.isSupported,
                   DataScannerViewController.isAvailable {
                    NutritionDataScanner(onScan: onScan)
                        .ignoresSafeArea(edges: .bottom)
                } else if permissionResolved {
                    ScreenStateCard(
                        kind: .error,
                        title: "nutrition.barcode.camera_unavailable_title",
                        message: authorized
                            ? "nutrition.barcode.camera_unsupported"
                            : "nutrition.barcode.camera_denied",
                        symbol: "camera.fill"
                    )
                    .padding(20)
                } else {
                    ProgressView()
                }
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("nutrition.barcode.scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("nutrition.cancel") { dismiss() }
                }
            }
        }
        .task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                authorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            permissionResolved = true
        }
    }
}

private struct NutritionDataScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(
        _ uiViewController: DataScannerViewController,
        context: Context
    ) {
        if !uiViewController.isScanning {
            try? uiViewController.startScanning()
        }
    }

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var delivered = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !delivered else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue,
                      !value.isEmpty
                else { continue }
                delivered = true
                dataScanner.stopScanning()
                onScan(value)
                return
            }
        }
    }
}
#endif
