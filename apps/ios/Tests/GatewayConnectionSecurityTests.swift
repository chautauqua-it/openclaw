import Foundation
import Network
import OpenClawKit
import Testing
@testable import OpenClaw

@Suite(.serialized) struct GatewayConnectionSecurityTests {
    @MainActor
    private func makeController() -> GatewayConnectionController {
        GatewayConnectionController(appModel: NodeAppModel(), startDiscovery: false)
    }

    private func makeDiscoveredGateway(
        stableID: String,
        lanHost: String?,
        tailnetDns: String?,
        gatewayPort: Int?,
        fingerprint: String?) -> GatewayDiscoveryModel.DiscoveredGateway
    {
        let endpoint: NWEndpoint = .service(name: "Test", type: "_openclaw-gw._tcp", domain: "local.", interface: nil)
        return GatewayDiscoveryModel.DiscoveredGateway(
            name: "Test",
            endpoint: endpoint,
            stableID: stableID,
            debugID: "debug",
            lanHost: lanHost,
            tailnetDns: tailnetDns,
            gatewayPort: gatewayPort,
            canvasPort: nil,
            tlsEnabled: true,
            tlsFingerprintSha256: fingerprint,
            cliPath: nil)
    }

    private func clearTLSFingerprint(stableID: String) {
        GatewayTLSStore.clearFingerprint(stableID: stableID)
    }

    @Test @MainActor func discoveredTLSParams_prefersStoredPinOverAdvertisedTXT() async {
        let stableID = "test|\(UUID().uuidString)"
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        GatewayTLSStore.saveFingerprint("11", stableID: stableID)

        let gateway = makeDiscoveredGateway(
            stableID: stableID,
            lanHost: "evil.example.com",
            tailnetDns: "evil.example.com",
            gatewayPort: 12345,
            fingerprint: "22")
        let controller = makeController()

        let params = controller._test_resolveDiscoveredTLSParams(gateway: gateway, allowTOFU: true)
        #expect(params?.expectedFingerprint == "11")
        #expect(params?.allowTOFU == false)
    }

    @Test @MainActor func discoveredTLSParams_doesNotTrustAdvertisedFingerprint() async {
        let stableID = "test|\(UUID().uuidString)"
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let gateway = makeDiscoveredGateway(
            stableID: stableID,
            lanHost: nil,
            tailnetDns: nil,
            gatewayPort: nil,
            fingerprint: "22")
        let controller = makeController()

        let params = controller._test_resolveDiscoveredTLSParams(gateway: gateway, allowTOFU: true)
        #expect(params?.expectedFingerprint == nil)
        #expect(params?.allowTOFU == false)
    }

    @Test @MainActor func autoconnectRequiresStoredPinForDiscoveredGateways() async {
        let stableID = "test|\(UUID().uuidString)"
        defer { clearTLSFingerprint(stableID: stableID) }
        clearTLSFingerprint(stableID: stableID)

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "gateway.autoconnect")
        defaults.set(false, forKey: "gateway.manual.enabled")
        defaults.removeObject(forKey: "gateway.last.host")
        defaults.removeObject(forKey: "gateway.last.port")
        defaults.removeObject(forKey: "gateway.last.tls")
        defaults.removeObject(forKey: "gateway.last.stableID")
        defaults.removeObject(forKey: "gateway.last.kind")
        defaults.removeObject(forKey: "gateway.preferredStableID")
        defaults.set(stableID, forKey: "gateway.lastDiscoveredStableID")

        let gateway = makeDiscoveredGateway(
            stableID: stableID,
            lanHost: "test.local",
            tailnetDns: nil,
            gatewayPort: 18789,
            fingerprint: nil)
        let controller = makeController()
        controller._test_setGateways([gateway])
        controller._test_triggerAutoConnect()

        #expect(controller._test_didAutoConnect() == false)
    }

    @Test @MainActor func manualConnectionsForceTLSForNonLoopbackHosts() async {
        let controller = makeController()

        #expect(controller._test_resolveManualUseTLS(host: "gateway.example.com", useTLS: false) == true)
        #expect(controller._test_resolveManualUseTLS(host: "openclaw.local", useTLS: false) == true)
        #expect(controller._test_resolveManualUseTLS(host: "127.attacker.example", useTLS: false) == true)

        #expect(controller._test_resolveManualUseTLS(host: "localhost", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "127.0.0.1", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "::1", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "[::1]", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "::ffff:127.0.0.1", useTLS: false) == false)
        #expect(controller._test_resolveManualUseTLS(host: "0.0.0.0", useTLS: false) == false)
    }

    @Test @MainActor func manualDefaultPortUses443OnlyForTailnetTLSHosts() async {
        let controller = makeController()

        #expect(controller._test_resolveManualPort(host: "gateway.example.com", port: 0, useTLS: true) == 18789)
        #expect(controller._test_resolveManualPort(host: "device.sample.ts.net", port: 0, useTLS: true) == 443)
        #expect(controller._test_resolveManualPort(host: "device.sample.ts.net.", port: 0, useTLS: true) == 443)
        #expect(controller._test_resolveManualPort(host: "device.sample.ts.net", port: 18789, useTLS: true) == 18789)
    }

    @Test @MainActor func publicGatewayHost_matchesAllowlistOnly() async {
        #expect(GatewayConnectionController.isPublicGatewayHost("ianua.differen.it") == true)
        #expect(GatewayConnectionController.isPublicGatewayHost(" IANUA.DIFFEREN.IT ") == true)
        #expect(GatewayConnectionController.isPublicGatewayHost("ianua.differen.it.") == true)

        #expect(GatewayConnectionController.isPublicGatewayHost("evil-ianua.differen.it") == false)
        #expect(GatewayConnectionController.isPublicGatewayHost("ianua.differen.it.attacker.com") == false)
        #expect(GatewayConnectionController.isPublicGatewayHost("differen.it") == false)
        #expect(GatewayConnectionController.isPublicGatewayHost("") == false)
    }

    @Test @MainActor func publicGatewayHost_forcesTLS() async {
        let controller = makeController()
        #expect(controller._test_shouldForceTLS(host: "ianua.differen.it") == true)
        #expect(controller._test_shouldForceTLS(host: "gateway.example.com") == false)
    }

    @Test @MainActor func publicGatewayTLSParams_useSystemTrustWithoutPinOrTOFU() async {
        let params = GatewayConnectionController._test_publicGatewayTLSParams()
        #expect(params.required == true)
        #expect(params.expectedFingerprint == nil)
        #expect(params.allowTOFU == false)
        #expect(params.storeKey == nil)
    }

    @Test @MainActor func normalizedGatewayPath_handlesPrefixAndBlank() async {
        #expect(GatewayConnectionController.normalizedGatewayPath("gw-abc123") == "/gw-abc123")
        #expect(GatewayConnectionController.normalizedGatewayPath("/gw-abc123") == "/gw-abc123")
        #expect(GatewayConnectionController.normalizedGatewayPath("  gw-abc123  ") == "/gw-abc123")
        #expect(GatewayConnectionController.normalizedGatewayPath("") == "")
        #expect(GatewayConnectionController.normalizedGatewayPath("   ") == "")
        #expect(GatewayConnectionController.normalizedGatewayPath("/") == "")
    }

    @Test @MainActor func buildGatewayURL_appendsOptionalPath() async {
        let controller = makeController()

        let plain = controller._test_buildGatewayURL(
            host: "ianua.differen.it", port: 443, useTLS: true, path: nil)
        #expect(plain?.absoluteString == "wss://ianua.differen.it:443")

        let withPath = controller._test_buildGatewayURL(
            host: "ianua.differen.it", port: 443, useTLS: true, path: "gw-abc123")
        #expect(withPath?.absoluteString == "wss://ianua.differen.it:443/gw-abc123")

        let blankPath = controller._test_buildGatewayURL(
            host: "ianua.differen.it", port: 443, useTLS: true, path: "   ")
        #expect(blankPath?.absoluteString == "wss://ianua.differen.it:443")
    }

    @Test @MainActor func clearAllTLSFingerprints_removesStoredPins() async {
        let stableID1 = "test|\(UUID().uuidString)"
        let stableID2 = "test|\(UUID().uuidString)"
        defer { GatewayTLSStore.clearAllFingerprints() }

        GatewayTLSStore.saveFingerprint("11", stableID: stableID1)
        GatewayTLSStore.saveFingerprint("22", stableID: stableID2)

        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID1) == "11")
        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID2) == "22")

        GatewayTLSStore.clearAllFingerprints()

        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID1) == nil)
        #expect(GatewayTLSStore.loadFingerprint(stableID: stableID2) == nil)
    }
}
