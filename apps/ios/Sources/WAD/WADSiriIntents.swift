import AppIntents
import Foundation
import Observation

enum WADSiriRoute: String {
    case agents
    case chat
}

@MainActor
@Observable
final class WADSiriLaunchSignal {
    static let shared = WADSiriLaunchSignal()

    private static let pendingRouteKey = "wad.siri.pendingRoute"

    private(set) var activationToken = 0
    private var pendingRoute: WADSiriRoute?

    func request(_ route: WADSiriRoute) {
        self.pendingRoute = route
        self.activationToken += 1
        UserDefaults.standard.set(route.rawValue, forKey: Self.pendingRouteKey)
    }

    func consumePendingRoute() -> WADSiriRoute? {
        if let pendingRoute {
            self.pendingRoute = nil
            UserDefaults.standard.removeObject(forKey: Self.pendingRouteKey)
            return pendingRoute
        }

        guard let rawValue = UserDefaults.standard.string(forKey: Self.pendingRouteKey),
              let route = WADSiriRoute(rawValue: rawValue)
        else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: Self.pendingRouteKey)
        return route
    }
}

struct OpenWADChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Apri Chat WAD"
    static let description = IntentDescription("Apre la chat nativa dei canali WAD.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WADSiriLaunchSignal.shared.request(.chat)
        return .result()
    }
}

struct OpenWADAgentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Apri Agenti WAD"
    static let description = IntentDescription("Apre la chat nativa con gli agenti WAD.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WADSiriLaunchSignal.shared.request(.agents)
        return .result()
    }
}

struct WADAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWADChatIntent(),
            phrases: [
                "Apri Chat WAD in \(.applicationName)",
                "Apri la chat WAD in \(.applicationName)",
                "Mostra i canali WAD in \(.applicationName)",
            ],
            shortTitle: "Chat WAD",
            systemImageName: "text.bubble.fill")

        AppShortcut(
            intent: OpenWADAgentsIntent(),
            phrases: [
                "Apri Agenti WAD in \(.applicationName)",
                "Chatta con gli agenti in \(.applicationName)",
                "Parla con gli agenti WAD in \(.applicationName)",
            ],
            shortTitle: "Agenti WAD",
            systemImageName: "person.2.wave.2.fill")
    }
}
