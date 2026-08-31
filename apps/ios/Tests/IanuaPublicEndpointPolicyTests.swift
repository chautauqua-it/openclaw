import Testing
@testable import OpenClaw

struct IanuaPublicEndpointPolicyTests {
    @Test func `canonical endpoint is accepted and normalized`() {
        #expect(
            IanuaPublicEndpointPolicy.normalizedBaseURL("https://ianua.differen.it/")
                == "https://ianua.differen.it")
        #expect(
            IanuaPublicEndpointPolicy.resolvedBaseURL(nil)
                == "https://ianua.differen.it")
    }

    @Test func `legacy tailnet and insecure endpoints fail closed`() {
        #expect(
            IanuaPublicEndpointPolicy.normalizedBaseURL(
                "https://mac-mini-di-stefano.tail1e9216.ts.net:8456") == nil)
        #expect(IanuaPublicEndpointPolicy.normalizedBaseURL("http://ianua.differen.it") == nil)
        #expect(IanuaPublicEndpointPolicy.normalizedBaseURL("https://ianua.differen.it:443") == nil)
    }

    @Test func `endpoint rejects URL confusion and extra components`() {
        #expect(IanuaPublicEndpointPolicy.normalizedBaseURL("https://ianua.differen.it.evil.example") == nil)
        #expect(IanuaPublicEndpointPolicy.normalizedBaseURL("https://user@ianua.differen.it") == nil)
        #expect(IanuaPublicEndpointPolicy.normalizedBaseURL("https://ianua.differen.it/api") == nil)
        #expect(IanuaPublicEndpointPolicy.normalizedBaseURL("https://ianua.differen.it?next=evil") == nil)
    }
}
