import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

/// `IanuaProvisioningClient.Claim` is decoded from `/api/provision/claim`. The gateway
/// self-hosted setup code is never part of that response by server design — the public
/// Iànua server that answers `/claim` doesn't hold it — so `Claim.Gateway` only ever
/// carries `status`.
@Suite struct IanuaProvisioningClaimDecodingTests {
    private static func decode(_ json: String) throws -> IanuaProvisioningClient.Claim {
        try JSONDecoder().decode(IanuaProvisioningClient.Claim.self, from: Data(json.utf8))
    }

    @Test func decodesTheServerShapeWithStatusOnly() throws {
        let claim = try Self.decode(#"""
        {
          "tenant": {"slug": "rstrt", "nome": "Ristretto"},
          "user": {"id": 1, "email": "s@example.com", "nome": "Stefano"},
          "device": {"id": "dev1", "trust": "trusted"},
          "gateway": {"status": "pending"}
        }
        """#)
        #expect(claim.gateway?.status == "pending")
    }

    @Test func decodesWithNoGatewayFieldAtAll() throws {
        let claim = try Self.decode(#"""
        {
          "tenant": {"slug": "rstrt", "nome": "Ristretto"},
          "user": {"id": 1, "email": "s@example.com", "nome": "Stefano"},
          "device": {"id": "dev1", "trust": "trusted"}
        }
        """#)
        #expect(claim.gateway == nil)
    }
}

/// `IanuaProvisioningClient.interpret(_:)` is the pure decision function behind
/// `pollGatewaySetupCode`: given a `GET /api/provision/gateway` response, it decides
/// whether to hand back a `GatewayConnectDeepLink`, retry after a delay, or fail with a
/// specific `IanuaProvisionError`. It's tested here without any network involved, using
/// the exact field names the coordinator confirmed against the real server
/// (`provisioning.mjs`/`server.mjs`, `apiProvisionGateway`): `status`, `retry_after`,
/// `setup_code`.
@Suite struct GatewayPollOutcomeTests {
    private static func decode(_ json: String) throws -> IanuaProvisioningClient.GatewayPollResponse {
        try JSONDecoder().decode(IanuaProvisioningClient.GatewayPollResponse.self, from: Data(json.utf8))
    }

    private static func encodeSetupCode(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func noneMeansNoGatewayPairingStarted() throws {
        let response = try Self.decode(#"{"status":"none"}"#)
        #expect(
            IanuaProvisioningClient.interpret(response)
                == .failure(.gatewayNotPaired))
    }

    @Test func pendingRetriesAfterTheServerSuppliedInterval() throws {
        let response = try Self.decode(#"{"status":"pending","retry_after":5}"#)
        #expect(IanuaProvisioningClient.interpret(response) == .retry(after: 5))
    }

    @Test func pendingWithoutRetryAfterFallsBackToTheDefaultInterval() throws {
        let response = try Self.decode(#"{"status":"pending"}"#)
        #expect(
            IanuaProvisioningClient.interpret(response)
                == .retry(after: IanuaProvisioningClient.defaultGatewayPollInterval))
    }

    @Test func readyWithAValidSetupCodeYieldsAConnectLink() throws {
        let setupCode = Self.encodeSetupCode(#"{"url":"ws://192.168.1.20:18789","token":"abc"}"#)
        let response = try Self.decode(#"{"status":"ready","setup_code":"\#(setupCode)"}"#)
        guard case let .ready(link) = IanuaProvisioningClient.interpret(response) else {
            Issue.record("expected a ready outcome with a parsed link")
            return
        }
        #expect(link.host == "192.168.1.20")
        #expect(link.token == "abc")
    }

    @Test func readyWithoutASetupCodeFieldIsUnreadable() throws {
        let response = try Self.decode(#"{"status":"ready"}"#)
        #expect(
            IanuaProvisioningClient.interpret(response)
                == .failure(.gatewayCodeUnreadable))
    }

    @Test func readyWithAMalformedSetupCodeIsUnreadable() throws {
        let response = try Self.decode(#"{"status":"ready","setup_code":"not-base64url-json"}"#)
        #expect(
            IanuaProvisioningClient.interpret(response)
                == .failure(.gatewayCodeUnreadable))
    }

    @Test func unknownStatusFailsWithTheStatusNamedInTheMessage() throws {
        let response = try Self.decode(#"{"status":"revoked"}"#)
        guard case let .failure(error) = IanuaProvisioningClient.interpret(response),
              case let .server(message) = error
        else {
            Issue.record("expected a .server failure naming the unknown status")
            return
        }
        #expect(message.contains("revoked"))
    }
}
