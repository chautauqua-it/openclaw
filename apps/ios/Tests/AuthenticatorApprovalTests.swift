import CryptoKit
import Foundation
import Testing
@testable import OpenClaw

struct AuthenticatorApprovalTests {
    @Test func productionSourceDoesNotLoadSoftwareAuthenticatorKeys() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Authenticator/AuthenticatorStore.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let softwareLoad = "P256.Signing.PrivateKey(rawRepresentation: stored)"
        let simulatorGuard = "#if targetEnvironment(simulator)"

        guard let softwareRange = source.range(of: softwareLoad) else {
            Issue.record("Software-key compatibility loader is missing")
            return
        }
        let guardedPrefix = source[..<softwareRange.lowerBound]
        guard let guardRange = guardedPrefix.range(of: simulatorGuard, options: .backwards) else {
            Issue.record("Software Authenticator keys must be simulator-only")
            return
        }
        #expect(!guardedPrefix[guardRange.upperBound...].contains("#endif"))
    }

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

    @Test func `decodes Iànua pending challenge envelope`() throws {
        let request: [String: Any] = [
            "personId": String(repeating: "a", count: 64),
            "initiatorDeviceId": String(repeating: "b", count: 64),
            "nonce": Data(repeating: 7, count: 32).base64EncodedString(),
            "action": [
                "environment": "production",
                "tenant": "restart",
                "audience": "ianua-critical-config",
                "actionId": "network.vlan.apply",
                "requestHash": String(repeating: "ab", count: 32),
            ],
            "target": "cluster-management",
            "parameterSummary": "Applica VLAN management",
            "matchCodeDigits": 2,
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "challenges": [[
                "id": "7f6177dc-f5dc-4104-b411-3d2f91b00d41",
                "request": request,
                "expiresAt": "2100-01-01T00:00:00.000Z",
            ]],
        ])
        let challenges = try IanuaAuthenticatorClient.decodePending(data)
        let challenge = try #require(challenges.first)
        #expect(challenge.id == "7f6177dc-f5dc-4104-b411-3d2f91b00d41")
        #expect(challenge.action.actionId == "network.vlan.apply")
        #expect(challenge.validationError(now: Date(timeIntervalSince1970: 2_000_000_000)) == nil)
    }

    @Test func `screen shows pending challenge outside chat`() {
        let challenge = self.challenge()
        #expect(AuthenticatorScreenPendingState.resolve(
            challenge: challenge,
            hasPrompt: true,
            operatorConnected: true) == .challenge(challenge))
        #expect(AuthenticatorScreenPendingState.resolve(
            challenge: challenge,
            hasPrompt: true,
            operatorConnected: false) == .challenge(challenge))
    }

    @Test func `screen separates foreign prompts from searchable idle`() {
        #expect(AuthenticatorScreenPendingState.resolve(
            challenge: nil,
            hasPrompt: true,
            operatorConnected: true) == .foreignPrompt)
        #expect(AuthenticatorScreenPendingState.resolve(
            challenge: nil,
            hasPrompt: false,
            operatorConnected: true) == .idle(canSearch: true))
        #expect(AuthenticatorScreenPendingState.resolve(
            challenge: nil,
            hasPrompt: false,
            operatorConnected: false) == .idle(canSearch: false))
    }

    @Test func `ui state requires exact numeric match code`() {
        let challenge = self.challenge()
        #expect(AuthenticatorUIState.resolve(challenge: challenge, code: "4", resolving: false) != .ready)
        #expect(AuthenticatorUIState.resolve(challenge: challenge, code: "4x", resolving: false) != .ready)
        #expect(AuthenticatorUIState.resolve(challenge: challenge, code: "42", resolving: false) == .ready)
        #expect(AuthenticatorUIState.resolve(challenge: challenge, code: "42", resolving: true) == .resolving)
    }
}
