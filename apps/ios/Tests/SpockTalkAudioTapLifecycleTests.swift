import Testing
@testable import OpenClaw

@Suite("Spock Talk audio tap lifecycle")
struct SpockTalkAudioTapLifecycleTests {
    @Test
    func `il primo avvio non rimuove tap inesistenti`() {
        let lifecycle = SpockTalkAudioTapLifecycle()
        var removals = 0

        lifecycle.prepareInputTapForInstall { removals += 1 }
        lifecycle.preparePlayerTapForInstall { removals += 1 }

        #expect(removals == 0)
    }

    @Test
    func `il rebuild sostituisce una sola volta i tap installati`() {
        let lifecycle = SpockTalkAudioTapLifecycle()
        var inputRemovals = 0
        var playerRemovals = 0

        lifecycle.didInstallInputTap()
        lifecycle.didInstallPlayerTap()
        lifecycle.prepareInputTapForInstall { inputRemovals += 1 }
        lifecycle.preparePlayerTapForInstall { playerRemovals += 1 }

        #expect(inputRemovals == 1)
        #expect(playerRemovals == 1)
    }

    @Test
    func `il teardown ripetuto e idempotente`() {
        let lifecycle = SpockTalkAudioTapLifecycle()
        var inputRemovals = 0
        var playerRemovals = 0

        lifecycle.didInstallInputTap()
        lifecycle.didInstallPlayerTap()
        for _ in 0..<2 {
            lifecycle.removeInputTapIfInstalled { inputRemovals += 1 }
            lifecycle.removePlayerTapIfInstalled { playerRemovals += 1 }
        }

        #expect(inputRemovals == 1)
        #expect(playerRemovals == 1)
    }
}
