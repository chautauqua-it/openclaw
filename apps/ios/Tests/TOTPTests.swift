import Foundation
import Testing
@testable import OpenClaw

struct TOTPTests {
    @Test func `parses authenticator URI`() throws {
        let uri =
            try #require(URL(string: "otpauth://totp/Ianua:stefano@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Ianua"))
        let account = try TOTP.parse(uri: uri)
        #expect(account.issuer == "Ianua")
        #expect(account.name == "stefano@example.com")
        #expect(account.digits == 6)
        #expect(account.period == 30)
    }

    @Test func `matches RFC 6238 SHA 1 vector`() throws {
        let account = TOTPAccount(
            id: UUID(), issuer: "RFC", name: "test",
            secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            algorithm: .sha1, digits: 8, period: 30)
        #expect(try TOTP.code(for: account, at: Date(timeIntervalSince1970: 59)) == "94287082")
    }

    @Test func `rejects HOTP and unsafe parameters`() throws {
        let hotp = try #require(URL(string: "otpauth://hotp/Test?a=1&secret=JBSWY3DPEHPK3PXP"))
        #expect(throws: TOTPError.unsupportedType) { try TOTP.parse(uri: hotp) }
        let invalid = try #require(URL(string: "otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP&digits=12"))
        #expect(throws: TOTPError.invalidParameters) { try TOTP.parse(uri: invalid) }
        let duplicate = try #require(URL(string:
            "otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP&secret=GEZDGNBVGY3TQOJQ"))
        #expect(throws: TOTPError.invalidURI) { try TOTP.parse(uri: duplicate) }
    }
}
