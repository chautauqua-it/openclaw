import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

/// Regression coverage for the routing bug behind build 8: the first-run wizard's
/// QR scanner (`QRScannerView`/`OnboardingWizardView`) used to try only the two
/// gateway-pairing shapes (`GatewayConnectDeepLink.fromSetupCode`, the
/// `openclaw://gateway` deep link) and never `IanuaProvisionLink.parse`. Scanning
/// the QR minted from a person's Iànua profile page (`ianua://provision?s=...&t=...`)
/// therefore fell through to a generic "not a valid pairing code" message, even
/// though the code itself was perfectly well-formed.
///
/// Before `WizardQRRecognizer` existed, this exact payload — reconstructed in the
/// same shape the server mints (`ibs_` + 43 base64url characters, per
/// `IanuaProvisionLink.isValidToken`) — had no code path in the wizard that
/// recognized it at all.
@Suite struct WizardQRRecognizerTests {
    private static let token = "ibs_" + String(repeating: "a", count: 43)
    private static let profileQRPayload = "ianua://provision?s=rstrt&t=\(Self.token)"

    @Test func recognizesTheProfileActivationQrMintedByTheServer() throws {
        guard case let .provision(link)? = WizardQRRecognizer.recognize(Self.profileQRPayload) else {
            Issue.record("expected the profile QR to be recognized as an IanuaProvisionLink")
            return
        }
        #expect(link.slug == "rstrt")
        #expect(link.token == Self.token)
    }

    /// Confirms the profile QR genuinely fails both gateway-pairing shapes on its
    /// own: the routing bug wasn't in either individual parser, it was that the
    /// wizard never tried the third one.
    @Test func profileActivationQrIsNotAGatewaySetupCodeOrDeepLink() {
        #expect(GatewayConnectDeepLink.fromSetupCode(Self.profileQRPayload) == nil)
        let url = URL(string: Self.profileQRPayload)
        #expect(url.flatMap { DeepLinkParser.parse($0) } == nil)
    }

    @Test func stillRecognizesAGatewaySetupCode() throws {
        let payload = Data(#"{"url":"ws://192.168.1.20:18789","token":"abc"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard case let .gateway(link)? = WizardQRRecognizer.recognize(payload) else {
            Issue.record("expected a gateway setup code to still be recognized")
            return
        }
        #expect(link.host == "192.168.1.20")
    }

    @Test func stillRecognizesAnOpenclawGatewayDeepLink() throws {
        let payload = "openclaw://gateway?host=192.168.1.20&port=18789&tls=0&token=abc"
        guard case let .gateway(link)? = WizardQRRecognizer.recognize(payload) else {
            Issue.record("expected an openclaw://gateway deep link to still be recognized")
            return
        }
        #expect(link.host == "192.168.1.20")
    }

    @Test func rejectsGarbage() {
        #expect(WizardQRRecognizer.recognize("not a qr code at all") == nil)
    }
}
