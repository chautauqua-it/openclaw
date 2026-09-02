import Foundation
import Testing
@testable import OpenClaw

@Suite("Iànua Realtime endpoint policy")
struct IanuaRealtimeEndpointPolicyTests {
    @Test("il client usa l'endpoint pubblico autenticato")
    @MainActor
    func publicEndpoint() {
        #expect(SpockTalkManager.defaultServerURL == "https://ianua.differen.it/api/mobile/realtime")
        #expect(!SpockTalkManager.defaultServerURL.contains(".ts.net"))
    }
}
