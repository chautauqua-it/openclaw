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

enum WADSiriDefaults {
    private static let lastChannelIdKey = "wad.siri.lastChannelId"
    private static let lastChannelNameKey = "wad.siri.lastChannelName"

    static func rememberLastChannel(id: String, name: String) {
        UserDefaults.standard.set(id, forKey: self.lastChannelIdKey)
        UserDefaults.standard.set(name, forKey: self.lastChannelNameKey)
    }

    static func lastChannel() -> (id: String, name: String)? {
        guard let id = UserDefaults.standard.string(forKey: self.lastChannelIdKey),
              let name = UserDefaults.standard.string(forKey: self.lastChannelNameKey)
        else { return nil }
        return (id: id, name: name)
    }
}

struct WADChannelEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Canale WAD")
    static let defaultQuery = WADChannelEntityQuery()

    /// id = channelId, oppure "agent:<channelId>" per l'alias con il nome dell'agente.
    let id: String
    let channelId: String
    let title: String
    let subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        if let subtitle {
            DisplayRepresentation(title: "\(self.title)", subtitle: "\(subtitle)")
        } else {
            DisplayRepresentation(title: "\(self.title)")
        }
    }

    static func fromCache() -> [WADChannelEntity] {
        var entities: [WADChannelEntity] = []
        for channel in WADChannelCache.load() {
            entities.append(WADChannelEntity(
                id: channel.id,
                channelId: channel.id,
                title: channel.name,
                subtitle: channel.agent.map { "agente \($0)" }))
            if let agent = channel.agent, !agent.isEmpty {
                entities.append(WADChannelEntity(
                    id: "agent:\(channel.id)",
                    channelId: channel.id,
                    title: agent.capitalized,
                    subtitle: "canale #\(channel.name)"))
            }
        }
        return entities
    }
}

struct WADChannelEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WADChannelEntity] {
        let all = await self.allEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WADChannelEntity] {
        await self.allEntities()
    }

    private func allEntities() async -> [WADChannelEntity] {
        let cached = WADChannelEntity.fromCache()
        if !cached.isEmpty { return cached }
        _ = try? await WADAPIClient.shared.channels()
        return WADChannelEntity.fromCache()
    }
}

struct AskWADIntent: AppIntent {
    static let title: LocalizedStringResource = "Chiedi a WAD"
    static let description = IntentDescription(
        "Invia un messaggio a un canale WAD e legge la risposta dell'agente.")

    @Parameter(title: "Canale o agente")
    var canale: WADChannelEntity?

    @Parameter(title: "Messaggio", requestValueDialog: "Cosa vuoi chiedere?")
    var testo: String

    static var parameterSummary: some ParameterSummary {
        Summary("Chiedi \(\.$testo) a \(\.$canale)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let api = WADAPIClient.shared

        do {
            _ = try await api.me()
        } catch {
            return .result(dialog: "Non sei collegato a WAD. Apri l'app, controlla Tailscale e fai il login.")
        }

        guard let target = await self.resolveChannel(api: api) else {
            return .result(dialog: "Non trovo un canale WAD. Apri la chat WAD almeno una volta e riprova.")
        }

        let body = self.testo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return .result(dialog: "Non ho capito il messaggio da inviare.")
        }

        let sent: WADChatMessage
        do {
            sent = try await api.send(channelId: target.channelId, body: "🎤 " + body)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "errore sconosciuto"
            return .result(dialog: "Invio fallito: \(reason)")
        }

        if let reply = await self.waitForAgentReply(api: api, channelId: target.channelId, afterMessageId: sent.id) {
            return .result(dialog: "\(reply.userName) risponde: \(Self.speakable(reply.body))")
        }
        return .result(
            dialog: "Inviato su \(target.title). L'agente sta ancora lavorando: la risposta arriva in chat WAD.")
    }

    private func resolveChannel(api: WADAPIClient) async -> WADChannelEntity? {
        if let canale { return canale }
        if let last = WADSiriDefaults.lastChannel() {
            return WADChannelEntity(id: last.id, channelId: last.id, title: last.name, subtitle: nil)
        }
        let entities = await (try? WADChannelEntityQuery().suggestedEntities()) ?? []
        return entities.first { !$0.id.hasPrefix("agent:") } ?? entities.first
    }

    private func waitForAgentReply(
        api: WADAPIClient,
        channelId: String,
        afterMessageId: String) async -> WADChatMessage?
    {
        // Siri concede un budget breve: ~20 secondi di polling, poi si rimanda alla chat.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let snapshot = try? await api.messages(channelId: channelId) else { continue }
            if let index = snapshot.messages.firstIndex(where: { $0.id == afterMessageId }) {
                let following = snapshot.messages.suffix(from: snapshot.messages.index(after: index))
                if let reply = following.last(where: { $0.isAgent && !$0.body.isEmpty }) {
                    return reply
                }
            }
            if snapshot.busy == nil, snapshot.messages.contains(where: { $0.id == afterMessageId }) {
                // Turno chiuso senza risposta testuale: inutile continuare ad aspettare.
                return nil
            }
        }
        return nil
    }

    private static func speakable(_ body: String) -> String {
        var text = body
        for token in ["**", "__", "`", "###", "##", "#"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 600 {
            text = String(text.prefix(600)) + "… Il resto è in chat."
        }
        return text
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
            intent: AskWADIntent(),
            phrases: [
                "Chiedi a \(.applicationName)",
                "Chiedi a \(\.$canale) su \(.applicationName)",
                "Parla con \(\.$canale) su \(.applicationName)",
                "Scrivi a \(\.$canale) su \(.applicationName)",
                "Manda un messaggio su \(.applicationName)",
            ],
            shortTitle: "Chiedi a WAD",
            systemImageName: "waveform.circle.fill")

        AppShortcut(
            intent: OpenWADChatIntent(),
            phrases: [
                "Apri Chat \(.applicationName)",
                "Apri la chat \(.applicationName)",
                "Mostra i canali \(.applicationName)",
            ],
            shortTitle: "Chat WAD",
            systemImageName: "text.bubble.fill")

        AppShortcut(
            intent: OpenWADAgentsIntent(),
            phrases: [
                "Apri Agenti \(.applicationName)",
                "Chatta con gli agenti in \(.applicationName)",
                "Parla con gli agenti \(.applicationName)",
            ],
            shortTitle: "Agenti WAD",
            systemImageName: "person.2.wave.2.fill")
    }
}
