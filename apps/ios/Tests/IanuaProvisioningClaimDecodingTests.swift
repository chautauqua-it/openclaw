import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

/// `IanuaProvisioningClient.Claim` is decoded from `/api/provision/claim`. That
/// server route lives outside this repo, so these tests pin the *contract* both
/// sides need to agree on: today's server only sends `gateway.status`, and a
/// future server needs to be free to add connection fields without breaking
/// clients that predate them (and vice versa).
@Suite struct IanuaProvisioningClaimDecodingTests {
    private static func decode(_ json: String) throws -> IanuaProvisioningClient.Claim {
        try JSONDecoder().decode(IanuaProvisioningClient.Claim.self, from: Data(json.utf8))
    }

    @Test func decodesTodaysServerShapeWithStatusOnly() throws {
        let claim = try Self.decode(#"""
        {
          "tenant": {"slug": "rstrt", "nome": "Ristretto"},
          "user": {"id": 1, "email": "s@example.com", "nome": "Stefano"},
          "device": {"id": "dev1", "trust": "trusted"},
          "gateway": {"status": "pending"}
        }
        """#)
        #expect(claim.gateway?.status == "pending")
        #expect(claim.gateway?.connectDeepLink == nil)
    }

    @Test func decodesAFutureServerShapeWithGatewayConnectionFields() throws {
        let claim = try Self.decode(#"""
        {
          "tenant": {"slug": "rstrt", "nome": "Ristretto"},
          "user": {"id": 1, "email": "s@example.com", "nome": "Stefano"},
          "device": {"id": "dev1", "trust": "trusted"},
          "gateway": {
            "status": "ready",
            "url": "ws://192.168.1.20:18789",
            "token": "abc",
            "password": "pw"
          }
        }
        """#)
        let link = try #require(claim.gateway?.connectDeepLink)
        #expect(link.host == "192.168.1.20")
        #expect(link.port == 18789)
        #expect(link.tls == false)
        #expect(link.token == "abc")
        #expect(link.password == "pw")
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
