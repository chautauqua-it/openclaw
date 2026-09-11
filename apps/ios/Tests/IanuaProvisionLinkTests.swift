import Foundation
import Testing
@testable import OpenClaw

@Suite struct IanuaProvisionLinkTests {
    /// Token di esempio nella forma del server: `ibs_` + 43 caratteri base64url.
    private static let token = "ibs_" + String(repeating: "a", count: 43)

    @Test func parsesTheOperatorQrPayload() throws {
        let link = try #require(
            IanuaProvisionLink.parse("ianua://provision?s=rstrt&t=\(Self.token)"))
        #expect(link.slug == "rstrt")
        #expect(link.token == Self.token)
    }

    /// `ianua:provision?…` mette la rotta nel path invece che nell'host: iOS
    /// consegna entrambe le forme, e l'attivazione non può dipendere da quale.
    @Test func parsesTheSchemeOnlyForm() throws {
        let link = try #require(
            IanuaProvisionLink.parse("ianua:provision?s=rstrt&t=\(Self.token)"))
        #expect(link.slug == "rstrt")
    }

    @Test func rejectsForeignSchemesAndRoutes() {
        #expect(IanuaProvisionLink.parse("openclaw://gateway?x=1") == nil)
        #expect(IanuaProvisionLink.parse("https://ianua.differen.it/provision?s=rstrt&t=\(Self.token)") == nil)
        #expect(IanuaProvisionLink.parse("ianua://altro?s=rstrt&t=\(Self.token)") == nil)
        #expect(IanuaProvisionLink.parse("non un url") == nil)
    }

    /// Slug e token malformati non valgono una chiamata di rete: riconoscerli
    /// qui è ciò che distingue "QR di un'altra app" da "codice rifiutato".
    @Test func enforcesTheServerShapeOfSlugAndToken() {
        #expect(!IanuaProvisionLink.isValidSlug(""))
        #expect(!IanuaProvisionLink.isValidSlug("1rstrt"))
        #expect(!IanuaProvisionLink.isValidSlug("RSTRT"))
        #expect(!IanuaProvisionLink.isValidSlug("r"))
        #expect(IanuaProvisionLink.isValidSlug("rstrt-demo"))

        #expect(!IanuaProvisionLink.isValidToken(""))
        #expect(!IanuaProvisionLink.isValidToken("ibs_corto"))
        #expect(!IanuaProvisionLink.isValidToken(String(repeating: "a", count: 47)))
        #expect(!IanuaProvisionLink.isValidToken("ibs_" + String(repeating: "a", count: 42) + "+"))
        #expect(IanuaProvisionLink.isValidToken(Self.token))

        #expect(IanuaProvisionLink.parse("ianua://provision?s=RSTRT&t=\(Self.token)") == nil)
        #expect(IanuaProvisionLink.parse("ianua://provision?s=rstrt&t=ibs_corto") == nil)
        #expect(IanuaProvisionLink.parse("ianua://provision?s=rstrt") == nil)
    }

    /// Il QR non trasporta l'host: è la ragione per cui un codice fotografato
    /// non può dirottare l'attivazione su un server di qualcun altro.
    @Test func ignoresAnyHostSmuggledIntoTheQr() throws {
        let link = try #require(
            IanuaProvisionLink.parse(
                "ianua://provision?s=rstrt&t=\(Self.token)&host=https://attaccante.example"))
        #expect(link.slug == "rstrt")
        #expect(link.token == Self.token)
    }

    @Test func base64URLDropsPaddingAndUrlUnsafeCharacters() {
        let raw = Data([0xFB, 0xFF, 0xBE])
        #expect(raw.base64EncodedString() == "+/++")
        #expect(raw.ianuaBase64URLEncodedString() == "-_--")
        #expect(Data([0x01]).ianuaBase64URLEncodedString() == "AQ")
    }
}
