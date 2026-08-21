import CryptoKit
import Foundation
import Testing
@testable import OpenClaw

struct AuthenticatorApprovalTests {
    private func challenge(
        personId: String = String(repeating: "a", count: 64),
        initiatorDeviceId: String = String(repeating: "b", count: 64),
        expiresAtUnix: Int64 = 4_102_444_800) -> AuthenticatorChallenge
    {
        AuthenticatorChallenge(
            personId: personId,
            initiatorDeviceId: initiatorDeviceId,
            nonce: Data(repeating: 7, count: 32).base64EncodedString(),
            action: AuthenticatorActionContext(
                environment: "staging",
                tenant: "tenant-a",
                audience: "dtail-gate",
                actionId: "sip.credentials.read",
                requestHash: String(repeating: "ab", count: 32)),
            target: "centralino-a",
            parameterSummary: "Lettura credenziali SIP per interno 101",
            matchCodeDigits: 2,
            expiresAtUnix: expiresAtUnix)
    }

    @Test func `parses closed authenticator contract`() throws {
        let source = self.challenge()
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(AuthenticatorChallenge.self, from: data)
        #expect(decoded == source)
        #expect(decoded.validationError(now: Date(timeIntervalSince1970: 2_000_000_000)) == nil)
    }

    @Test func `rejects self approval expiry and incomplete binding`() {
        #expect(self.challenge(personId: "same", initiatorDeviceId: "same").validationError() != nil)
        #expect(self.challenge(expiresAtUnix: 1).validationError() == "La richiesta è scaduta.")
        let incomplete = AuthenticatorChallenge(
            personId: "person-a",
            initiatorDeviceId: "device-b",
            nonce: Data(repeating: 7, count: 32).base64EncodedString(),
            action: AuthenticatorActionContext(
                environment: "", tenant: "tenant-a", audience: "gate", actionId: "read", requestHash: "hash"),
            target: "target",
            parameterSummary: "summary",
            matchCodeDigits: 2,
            expiresAtUnix: 4_102_444_800)
        #expect(incomplete.validationError() != nil)
    }

    @Test func `canonical digest matches go authn vector`() throws {
        let digest = try self.challenge().digest(enteredCode: "42", decision: "approve")
        #expect(digest.map { String(format: "%02x", $0) }.joined() ==
            "18f9f536ec81e1e3635a3c002de4db6c79c5ce2cac781a9611eb5956d8b9da70")
    }

    @Test func `resolution payload uses wire keys`() throws {
        let payload = AuthenticatorResolutionPayload(
            enteredCode: "42",
            personId: "person-a",
            signatureDER: "signature",
            publicKeyDER: "public-key",
            decision: "approve")
        let object = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(payload)) as? [String: String])
        #expect(object["enteredCode"] == "42")
        #expect(object["personId"] == "person-a")
        #expect(object["signatureDer"] == "signature")
        #expect(object["publicKeyDer"] == "public-key")
        #expect(object["decision"] == "approve")
    }

    @Test func `ui state requires exact numeric match code`() {
        let challenge = self.challenge()
        #expect(AuthenticatorUIState.resolve(challenge: challenge, code: "4", resolving: false) != .ready)
        #expect(AuthenticatorUIState.resolve(challenge: challenge, code: "4x", resolving: false) != .ready)
        #expect(AuthenticatorUIState.resolve(challenge: challenge, code: "42", resolving: false) == .ready)
        #expect(AuthenticatorUIState.resolve(challenge: challenge, code: "42", resolving: true) == .resolving)
    }
}
