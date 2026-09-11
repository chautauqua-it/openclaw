import AVFoundation
import SwiftUI
import UIKit

/// Inquadratura QR per l'attivazione, costruita su AVFoundation.
///
/// L'app ha già `QRScannerView` (VisionKit), ma è legata al pairing del gateway
/// e `DataScannerViewController` non è disponibile su tutto il parco macchine.
/// L'attivazione è il primo gesto che una persona fa con Iànua: deve funzionare
/// su qualunque iPhone supportato, quindi qui si usa `AVCaptureMetadataOutput`,
/// che c'è ovunque.
struct IanuaQRScannerView: UIViewControllerRepresentable {
    /// Chiamata una sola volta: al primo QR riconosciuto la sessione si ferma.
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context _: Context) -> IanuaQRScannerController {
        let controller = IanuaQRScannerController()
        controller.onCode = self.onCode
        controller.onFailure = self.onFailure
        return controller
    }

    func updateUIViewController(_: IanuaQRScannerController, context _: Context) {}
}

/// `AVCaptureSession` non è `Sendable`, ma `startRunning`/`stopRunning` vanno
/// chiamate fuori dal main thread perché bloccano. La scatola esiste solo per
/// portarla sulla coda dedicata: nessun altro la tocca, e le due chiamate sono
/// proprio quelle che Apple prescrive di eseguire lì.
private struct IanuaCaptureSessionRunner: @unchecked Sendable {
    let session: AVCaptureSession

    func start() {
        if !self.session.isRunning {
            self.session.startRunning()
        }
    }

    func stop() {
        if self.session.isRunning {
            self.session.stopRunning()
        }
    }
}

final class IanuaQRScannerController: UIViewController {
    var onCode: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "it.differen.ianua.qr-session")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    private var runner: IanuaCaptureSessionRunner {
        IanuaCaptureSessionRunner(session: self.session)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black
        self.requestAccessAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.preview?.frame = self.view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let runner = self.runner
        self.sessionQueue.async { runner.stop() }
    }

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard granted else {
                        self.fail("Senza accesso alla fotocamera non posso leggere il QR di attivazione.")
                        return
                    }
                    self.configure()
                }
            }
        default:
            // Negato o limitato da restrizioni: l'unico rimedio è Impostazioni,
            // e va detto, altrimenti resta uno schermo nero senza spiegazione.
            self.fail(
                "Accesso alla fotocamera negato. Abilitalo in Impostazioni > Iànua per inquadrare il QR.")
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              self.session.canAddInput(input)
        else {
            self.fail("Fotocamera non disponibile su questo dispositivo.")
            return
        }
        let output = AVCaptureMetadataOutput()
        guard self.session.canAddOutput(output) else {
            self.fail("Impossibile avviare la lettura del QR.")
            return
        }
        self.session.beginConfiguration()
        self.session.addInput(input)
        self.session.addOutput(output)
        // `metadataObjectTypes` accetta .qr solo dopo `addOutput`: prima quel
        // tipo non risulta ancora supportato e l'assegnazione va in trap.
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: .main)
        self.session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: self.session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = self.view.bounds
        self.view.layer.addSublayer(preview)
        self.preview = preview

        let runner = self.runner
        self.sessionQueue.async { runner.start() }
    }

    fileprivate func handle(payload: String) {
        guard !self.delivered else { return }
        self.delivered = true
        let runner = self.runner
        self.sessionQueue.async { runner.stop() }
        self.onCode?(payload)
    }

    private func fail(_ message: String) {
        guard !self.delivered else { return }
        self.delivered = true
        self.onFailure?(message)
    }
}

extension IanuaQRScannerController: AVCaptureMetadataOutputObjectsDelegate {
    /// Il delegate AVFoundation non è isolato al main actor: la stringa si
    /// estrae qui e il resto si decide sul main, dove vive il controller.
    nonisolated func metadataOutput(
        _: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from _: AVCaptureConnection)
    {
        guard let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let payload = object.stringValue
        else { return }
        Task { @MainActor [weak self] in
            self?.handle(payload: payload)
        }
    }
}
