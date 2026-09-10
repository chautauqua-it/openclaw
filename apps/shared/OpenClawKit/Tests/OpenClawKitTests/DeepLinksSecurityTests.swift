import Foundation
import OpenClawKit
import Testing

private func encodeSetupCode(_ payload: String) -> String {
    Data(payload.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Suite struct DeepLinksSecurityTests {
    @Test func gatewayDeepLinkRejectsInsecureNonLoopbackWs() {
        let url = URL(
            string: "openclaw://gateway?host=attacker.example&port=18789&tls=0&token=abc")!
        #expect(DeepLinkParser.parse(url) == nil)
    }

    @Test func gatewayDeepLinkRejectsInsecurePrefixBypassHost() {
        let url = URL(
            string: "openclaw://gateway?host=127.attacker.example&port=18789&tls=0&token=abc")!
        #expect(DeepLinkParser.parse(url) == nil)
    }

    @Test func gatewayDeepLinkAllowsLoopbackWs() {
        let url = URL(
            string: "openclaw://gateway?host=127.0.0.1&port=18789&tls=0&token=abc")!
        #expect(
            DeepLinkParser.parse(url) == .gateway(
                .init(
                    host: "127.0.0.1",
                    port: 18789,
                    tls: false,
                    bootstrapToken: nil,
                    token: "abc",
                    password: nil)))
    }

    @Test func setupCodeRejectsInsecureNonLoopbackWs() {
        let payload = #"{"url":"ws://attacker.example:18789","bootstrapToken":"tok"}"#
        let encoded = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(GatewayConnectDeepLink.fromSetupCode(encoded) == nil)
    }

    @Test func setupCodeRejectsInsecurePrefixBypassHost() {
        let payload = #"{"url":"ws://127.attacker.example:18789","bootstrapToken":"tok"}"#
        let encoded = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(GatewayConnectDeepLink.fromSetupCode(encoded) == nil)
    }

    @Test func setupCodeAllowsLoopbackWs() {
        let payload = #"{"url":"ws://127.0.0.1:18789","bootstrapToken":"tok"}"#
        let encoded = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(
            GatewayConnectDeepLink.fromSetupCode(encoded) == .init(
                host: "127.0.0.1",
                port: 18789,
                tls: false,
                bootstrapToken: "tok",
                token: nil,
                password: nil))
    }

    @Test func setupCodeKeepsSecretRoutePath() {
        let payload = #"{"url":"wss://ianua.differen.it/gw-secret/","bootstrapToken":"tok"}"#
        let link = GatewayConnectDeepLink.fromSetupCode(encodeSetupCode(payload))

        #expect(link?.path == "/gw-secret/")
        #expect(link?.websocketURL?.absoluteString == "wss://ianua.differen.it:443/gw-secret/")
    }

    @Test func setupCodeWithoutPathKeepsRootBehaviour() {
        let payload = #"{"url":"wss://ianua.differen.it:443","bootstrapToken":"tok"}"#
        let link = GatewayConnectDeepLink.fromSetupCode(encodeSetupCode(payload))

        #expect(link?.path == nil)
        #expect(link?.websocketURL?.absoluteString == "wss://ianua.differen.it:443")
    }

    @Test func setupCodeTreatsRootPathAsAbsent() {
        let payload = #"{"url":"wss://ianua.differen.it/","bootstrapToken":"tok"}"#
        #expect(GatewayConnectDeepLink.fromSetupCode(encodeSetupCode(payload))?.path == nil)
    }

    @Test func setupCodeRejectsTraversalPath() {
        let payload = #"{"url":"wss://ianua.differen.it/gw/../admin","bootstrapToken":"tok"}"#
        #expect(GatewayConnectDeepLink.fromSetupCode(encodeSetupCode(payload)) == nil)
    }

    @Test func setupCodeIgnoresQueryAndFragment() {
        let payload = #"{"url":"wss://ianua.differen.it/gw-secret/?a=b#frag","bootstrapToken":"tok"}"#
        let link = GatewayConnectDeepLink.fromSetupCode(encodeSetupCode(payload))

        #expect(link?.path == "/gw-secret/")
        #expect(link?.websocketURL?.absoluteString == "wss://ianua.differen.it:443/gw-secret/")
    }

    @Test func setupCodeRejectsInsecureNonLoopbackWsEvenWithPath() {
        let payload = #"{"url":"ws://attacker.example:18789/gw-secret/","bootstrapToken":"tok"}"#
        #expect(GatewayConnectDeepLink.fromSetupCode(encodeSetupCode(payload)) == nil)
    }

    @Test func gatewayDeepLinkParsesPathQueryParam() {
        let url = URL(
            string: "openclaw://gateway?host=gateway.example&port=443&tls=1&path=gw-secret")!
        guard case let .gateway(link)? = DeepLinkParser.parse(url) else {
            Issue.record("expected a gateway route")
            return
        }
        #expect(link.path == "/gw-secret")
        #expect(link.websocketURL?.absoluteString == "wss://gateway.example:443/gw-secret")
    }

    @Test func gatewayDeepLinkRejectsTraversalPathQueryParam() {
        let url = URL(
            string: "openclaw://gateway?host=gateway.example&port=443&tls=1&path=/gw/../admin")!
        #expect(DeepLinkParser.parse(url) == nil)
    }

    @Test func normalizePathHandlesBlankRootAndTraversal() {
        #expect(GatewayConnectDeepLink.normalizePath(nil) == .absent)
        #expect(GatewayConnectDeepLink.normalizePath("") == .absent)
        #expect(GatewayConnectDeepLink.normalizePath("   ") == .absent)
        #expect(GatewayConnectDeepLink.normalizePath("/") == .absent)
        #expect(GatewayConnectDeepLink.normalizePath("gw-secret") == .value("/gw-secret"))
        #expect(GatewayConnectDeepLink.normalizePath("  /gw-secret/  ") == .value("/gw-secret/"))
        #expect(GatewayConnectDeepLink.normalizePath("/gw/../admin") == .invalid)
        #expect(GatewayConnectDeepLink.normalizePath("..") == .invalid)
    }
}
