import Foundation
import Testing
@testable import OpenClaw

@Suite struct IanuaSessionPolicyTests {
    @Test func realtimeUsesOnlyCanonicalPublicEndpoint() {
        #expect(IanuaRealtimeEndpointPolicy.resolvedBaseURL(nil) == IanuaRealtimeEndpointPolicy.canonicalBaseURL)
        #expect(
            IanuaRealtimeEndpointPolicy.resolvedBaseURL("http://127.0.0.1:40813") ==
                IanuaRealtimeEndpointPolicy.canonicalBaseURL)
        #expect(
            IanuaRealtimeEndpointPolicy.resolvedBaseURL("https://pilot.example.ts.net/realtime") ==
                IanuaRealtimeEndpointPolicy.canonicalBaseURL)
        #expect(
            IanuaRealtimeEndpointPolicy.resolvedBaseURL(IanuaRealtimeEndpointPolicy.canonicalBaseURL) ==
                IanuaRealtimeEndpointPolicy.canonicalBaseURL)
    }

    @Test func realtimeMapsUnauthorizedToLoginMessage() {
        let data = Data(#"{"error":"unauthorized"}"#.utf8)
        #expect(
            IanuaRealtimeHTTPPolicy.errorMessage(statusCode: 401, data: data) ==
                IanuaSessionStore.expiredMessage)
        #expect(
            IanuaRealtimeHTTPPolicy.errorMessage(statusCode: 403, data: data) ==
                IanuaSessionStore.expiredMessage)
        #expect(IanuaRealtimeHTTPPolicy.requiresLogin(statusCode: 401))
        #expect(IanuaRealtimeHTTPPolicy.requiresLogin(statusCode: 403))
        #expect(!IanuaRealtimeHTTPPolicy.requiresLogin(statusCode: 500))
        #expect(IanuaRealtimeHTTPPolicy.errorMessage(statusCode: 200, data: data) == nil)
    }

    @Test func clearRemovesOnlyIanuaSessionCookies() throws {
        let jar = HTTPCookieStorage.shared
        let session = try #require(HTTPCookie(properties: [
            .name: "ianua_session",
            .value: "revoked-test-token",
            .domain: "ianua.differen.it",
            .path: "/",
            .secure: "TRUE",
        ]))
        let unrelated = try #require(HTTPCookie(properties: [
            .name: "unrelated_test_cookie",
            .value: "keep",
            .domain: "example.invalid",
            .path: "/",
        ]))
        jar.setCookie(session)
        jar.setCookie(unrelated)
        defer { jar.deleteCookie(unrelated) }

        IanuaSessionStore.clear()

        #expect(!(jar.cookies ?? []).contains { $0.name == session.name && $0.domain.contains("ianua.differen.it") })
        #expect((jar.cookies ?? []).contains { $0.name == unrelated.name && $0.domain == unrelated.domain })
    }
}
