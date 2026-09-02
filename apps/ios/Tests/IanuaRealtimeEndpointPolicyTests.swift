import Foundation
import Testing
@testable import OpenClaw

@Suite("Iànua Realtime endpoint policy")
struct IanuaRealtimeEndpointPolicyTests {
    @Test
    @MainActor
    func `il client usa l'endpoint pubblico autenticato`() {
        #expect(SpockTalkManager.defaultServerURL == "https://ianua.differen.it/api/mobile/realtime")
        #expect(!SpockTalkManager.defaultServerURL.contains(".ts.net"))
    }
}

@Suite("SIP terminal state")
struct WADSipTerminalStateTests {
    @Test
    func `non mostra errore dopo una chiamata con audio connesso`() {
        #expect(!WADSipManager.shouldDisplayCallError(reachedMedia: true, secondsSinceSuccessfulEnd: 99))
        #expect(!WADSipManager.shouldDisplayCallError(reachedMedia: false, secondsSinceSuccessfulEnd: 1))
    }

    @Test
    func `mostra un errore prima della connessione`() {
        #expect(WADSipManager.shouldDisplayCallError(reachedMedia: false, secondsSinceSuccessfulEnd: 4))
    }
}
