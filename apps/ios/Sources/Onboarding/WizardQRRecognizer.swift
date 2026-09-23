import Foundation
import OpenClawKit

/// What a QR code scanned during the first-run wizard can turn out to be.
///
/// The wizard's camera feeds raw barcode text to a single scanner (see
/// `QRScannerView`), but two unrelated QR kinds can land there: a Mac-side
/// `/pair` gateway setup code, and the `ianua://provision` activation code
/// minted from a person's Iànua profile page. Before this type existed, the
/// wizard only ever tried the gateway shapes and silently treated a
/// profile QR as "not a valid pairing code" — this recognizer is the single
/// place that tries every shape the wizard understands, so both entry
/// points (live camera, photo picker) can't drift out of sync again.
enum WizardQRPayload: Equatable {
    case gateway(GatewayConnectDeepLink)
    case provision(IanuaProvisionLink)
}

enum WizardQRRecognizer {
    static func recognize(_ payload: String) -> WizardQRPayload? {
        // Setup code format first (base64url JSON from /pair qr).
        if let link = GatewayConnectDeepLink.fromSetupCode(payload) {
            return .gateway(link)
        }
        // Deep link URL format (openclaw://gateway?...).
        if let url = URL(string: payload),
           let route = DeepLinkParser.parse(url),
           case let .gateway(link) = route
        {
            return .gateway(link)
        }
        // Account-activation QR from the person's Iànua profile page.
        if let link = IanuaProvisionLink.parse(payload) {
            return .provision(link)
        }
        return nil
    }
}
