import AppIntents
import Observation

/// Signal used by the Watch app intent to ask the running app to open
/// the push-to-talk screen.
@MainActor
@Observable
final class WatchTalkLaunchSignal {
    static let shared = WatchTalkLaunchSignal()
    private(set) var activationToken = 0

    func request() {
        self.activationToken += 1
    }
}

struct StartWatchTalkIntent: AppIntent {
    static let title: LocalizedStringResource = "Parla con WAD"
    static let description = IntentDescription("Avvia una conversazione vocale con l'agente predefinito dal polso.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchTalkLaunchSignal.shared.request()
        return .result()
    }
}

struct WatchTalkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWatchTalkIntent(),
            phrases: [
                "Parla con \(.applicationName)",
                "Chiedi a \(.applicationName)",
                "Parla con UAD in \(.applicationName)",
                "Parla con WAD in \(.applicationName)",
                "Chiedi a UAD in \(.applicationName)",
                "Chiedi a WAD in \(.applicationName)",
                "Parla con Spock in \(.applicationName)",
                "Chiedi a Spock in \(.applicationName)",
                "Parla con Spock su \(.applicationName)",
                "Chiedi a Spock su \(.applicationName)",
            ],
            shortTitle: "Parla con WAD",
            systemImageName: "mic.fill")
    }
}
