import SwiftUI
import VisionKit

struct AuthenticatorQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            return UIViewController()
        }
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_: UIViewController, context _: Context) {}

    static func dismantleUIViewController(_ controller: UIViewController, coordinator _: Coordinator) {
        (controller as? DataScannerViewController)?.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: AuthenticatorQRScanner
        private var handled = false

        init(parent: AuthenticatorQRScanner) {
            self.parent = parent
        }

        func dataScanner(
            _: DataScannerViewController,
            didAdd items: [RecognizedItem],
            allItems _: [RecognizedItem])
        {
            guard !self.handled else { return }
            for item in items {
                guard case let .barcode(barcode) = item,
                      let value = barcode.payloadStringValue,
                      value.lowercased().hasPrefix("otpauth://")
                else { continue }
                self.handled = true
                self.parent.onCode(value)
                return
            }
        }
    }
}
