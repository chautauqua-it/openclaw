import AppIntents
import Foundation
import Observation

enum WADSiriRoute: String {
    case agents
    case chat
    case spockTalk
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

private enum WADSiriTarget {
    case explicit(WADChannelEntity)
    case agent(String)
    case lastOrFirst
}

private enum WADSiriChannels {
    static func resolve(api: WADAPIClient, target: WADSiriTarget) async -> WADChannelEntity? {
        switch target {
        case let .explicit(channel):
            return channel
        case let .agent(agentName):
            let normalized = agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Preferisce il thread DM dedicato: conversazione 1:1 sempre nello stesso
            // posto, invece del primo canale a tema in ordine alfabetico.
            if let dm = try? await api.agentDM(normalized) {
                return WADChannelEntity(
                    id: dm.channel.id,
                    channelId: dm.channel.id,
                    title: agentName.capitalized,
                    subtitle: "messaggi diretti")
            }
            let entities = await self.loadEntities(api: api)
            return entities.first { entity in
                entity.title.lowercased() == normalized && entity.id.hasPrefix("agent:")
            } ?? entities.first { entity in
                entity.title.lowercased() == normalized || entity.subtitle?.lowercased().contains(normalized) == true
            }
        case .lastOrFirst:
            if let last = WADSiriDefaults.lastChannel() {
                return WADChannelEntity(id: last.id, channelId: last.id, title: last.name, subtitle: nil)
            }
            let entities = await self.loadEntities(api: api)
            return entities.first { !$0.id.hasPrefix("agent:") } ?? entities.first
        }
    }

    static func loadEntities(api: WADAPIClient) async -> [WADChannelEntity] {
        let cached = WADChannelEntity.fromCache()
        if !cached.isEmpty { return cached }
        _ = try? await api.channels()
        return WADChannelEntity.fromCache()
    }
}

private enum WADSiriText {
    static func speakable(_ body: String) -> String {
        var text = body
        // Sostituisce i link markdown [testo](url) con il solo testo leggibile.
        text = text.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^\\)]+\\)",
            with: "$1",
            options: .regularExpression)
        // Rimuove i marcatori di lista a inizio riga.
        text = text.replacingOccurrences(
            of: "(?m)^\\s*[-*•]\\s+",
            with: "",
            options: .regularExpression)
        for token in ["**", "__", "`", "###", "##", "#", ">"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 600 {
            text = String(text.prefix(600)) + "… Il resto è in chat."
        }
        return text
    }
}

private enum WADSiriAskRunner {
    static func ask(_ text: String, target: WADSiriTarget) async -> String {
        let api = WADAPIClient.shared

        do {
            _ = try await api.me()
        } catch {
            return "Non sei collegato a WAD. Apri l'app, controlla Tailscale e fai il login."
        }

        guard let resolved = await WADSiriChannels.resolve(api: api, target: target) else {
            return "Non trovo un canale WAD. Apri la chat WAD almeno una volta e riprova."
        }

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return "Non ho capito il messaggio da inviare."
        }

        let sent: WADChatMessage
        do {
            sent = try await api.send(channelId: resolved.channelId, body: "🎤 " + body)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "errore sconosciuto"
            return "Invio fallito: \(reason)"
        }

        if let reply = await self.waitForAgentReply(
            api: api,
            channelId: resolved.channelId,
            afterMessageId: sent.id)
        {
            return "\(reply.userName) risponde: \(WADSiriText.speakable(reply.body))"
        }
        if case .agent = target {
            return "Inviato a \(resolved.title), che sta ancora lavorando. Tra un po' dimmi «Leggi \(resolved.title)», oppure trovi la risposta nella chat WAD nel thread di \(resolved.title)."
        }
        return "Inviato su \(resolved.title). L'agente sta ancora lavorando: trovi la risposta nella chat WAD."
    }

    private static func waitForAgentReply(
        api: WADAPIClient,
        channelId: String,
        afterMessageId: String) async -> WADChatMessage?
    {
        // Siri concede un budget breve: ~24 secondi di polling, poi si rimanda alla chat.
        var sawBusy = false
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let snapshot = try? await api.messages(channelId: channelId) else { continue }
            if let index = snapshot.messages.firstIndex(where: { $0.id == afterMessageId }) {
                let following = snapshot.messages.suffix(from: snapshot.messages.index(after: index))
                if let reply = following.last(where: { $0.isAgent && !$0.body.isEmpty }) {
                    return reply
                }
            }
            if snapshot.busy != nil {
                sawBusy = true
            } else if sawBusy {
                // Il turno era partito e si è chiuso senza risposta testuale: inutile aspettare.
                // (Senza sawBusy NON si esce: subito dopo l'invio busy può non essere ancora settato.)
                return nil
            }
        }
        return nil
    }
}

private enum WADSiriReadRunner {
    static func readLatest(target: WADSiriTarget) async -> String {
        let api = WADAPIClient.shared

        do {
            _ = try await api.me()
        } catch {
            return "Non sei collegato a WAD. Apri l'app, controlla Tailscale e fai il login."
        }

        guard let resolved = await WADSiriChannels.resolve(api: api, target: target) else {
            return "Non trovo un canale WAD. Apri la chat WAD almeno una volta e riprova."
        }

        guard let snapshot = try? await api.messages(channelId: resolved.channelId) else {
            return "Non riesco a leggere i messaggi di \(resolved.title). Controlla Tailscale e riprova."
        }

        guard let latest = snapshot.messages.last(where: { !$0.body.isEmpty }) else {
            return "Non ci sono messaggi in \(resolved.title)."
        }

        return "\(latest.userName) su \(resolved.title): \(WADSiriText.speakable(latest.body))"
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
        let target: WADSiriTarget = if let canale {
            .explicit(canale)
        } else {
            .lastOrFirst
        }
        return await .result(dialog: "\(WADSiriAskRunner.ask(self.testo, target: target))")
    }
}

struct AskAletovIntent: AppIntent {
    static let title: LocalizedStringResource = "Chiedi ad Aletov"
    static let description = IntentDescription("Invia un messaggio ad Aletov su WAD e legge la risposta.")

    @Parameter(title: "Messaggio", requestValueDialog: "Cosa vuoi chiedere ad Aletov?")
    var testo: String

    static var parameterSummary: some ParameterSummary {
        Summary("Chiedi ad Aletov \(\.$testo)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await .result(dialog: "\(WADSiriAskRunner.ask(self.testo, target: .agent("Aletov")))")
    }
}

struct AskSpockIntent: AppIntent {
    static let title: LocalizedStringResource = "Chiedi a Spock"
    static let description = IntentDescription("Invia un messaggio a Spock su WAD e legge la risposta.")

    @Parameter(title: "Messaggio", requestValueDialog: "Cosa vuoi chiedere a Spock?")
    var testo: String

    static var parameterSummary: some ParameterSummary {
        Summary("Chiedi a Spock \(\.$testo)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await .result(dialog: "\(WADSiriAskRunner.ask(self.testo, target: .agent("Spock")))")
    }
}

struct AskGianlutovIntent: AppIntent {
    static let title: LocalizedStringResource = "Chiedi a Gianlutov"
    static let description = IntentDescription("Invia un messaggio a Gianlutov su WAD e legge la risposta.")

    @Parameter(title: "Messaggio", requestValueDialog: "Cosa vuoi chiedere a Gianlutov?")
    var testo: String

    static var parameterSummary: some ParameterSummary {
        Summary("Chiedi a Gianlutov \(\.$testo)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await .result(dialog: "\(WADSiriAskRunner.ask(self.testo, target: .agent("Gianlutov")))")
    }
}

struct AskElenovaIntent: AppIntent {
    static let title: LocalizedStringResource = "Chiedi a Elenova"
    static let description = IntentDescription("Invia un messaggio a Elenova su WAD e legge la risposta.")

    @Parameter(title: "Messaggio", requestValueDialog: "Cosa vuoi chiedere a Elenova?")
    var testo: String

    static var parameterSummary: some ParameterSummary {
        Summary("Chiedi a Elenova \(\.$testo)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await .result(dialog: "\(WADSiriAskRunner.ask(self.testo, target: .agent("Elenova")))")
    }
}

struct AskPolpotovIntent: AppIntent {
    static let title: LocalizedStringResource = "Chiedi a Polpotov"
    static let description = IntentDescription("Invia un messaggio a Polpotov su WAD e legge la risposta.")

    @Parameter(title: "Messaggio", requestValueDialog: "Cosa vuoi chiedere a Polpotov?")
    var testo: String

    static var parameterSummary: some ParameterSummary {
        Summary("Chiedi a Polpotov \(\.$testo)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await .result(dialog: "\(WADSiriAskRunner.ask(self.testo, target: .agent("Polpotov")))")
    }
}

struct ReadWADIntent: AppIntent {
    static let title: LocalizedStringResource = "Leggi WAD"
    static let description = IntentDescription("Legge ad alta voce l'ultimo messaggio di un canale WAD.")

    @Parameter(title: "Canale o agente")
    var canale: WADChannelEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Leggi l'ultimo messaggio di \(\.$canale)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target: WADSiriTarget = if let canale {
            .explicit(canale)
        } else {
            .lastOrFirst
        }
        return await .result(dialog: "\(WADSiriReadRunner.readLatest(target: target))")
    }
}

struct ReadSpockIntent: AppIntent {
    static let title: LocalizedStringResource = "Leggi Spock"
    static let description = IntentDescription("Legge ad alta voce l'ultimo messaggio di Spock su WAD.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await .result(dialog: "\(WADSiriReadRunner.readLatest(target: .agent("Spock")))")
    }
}

struct ReadAletovIntent: AppIntent {
    static let title: LocalizedStringResource = "Leggi Aletov"
    static let description = IntentDescription("Legge ad alta voce l'ultimo messaggio di Aletov su WAD.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await .result(dialog: "\(WADSiriReadRunner.readLatest(target: .agent("Aletov")))")
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

struct OpenSpockVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Avvia Spock vocale"
    static let description = IntentDescription(
        "Apre la conversazione vocale in tempo reale con Spock (mani libere, ideale in auto).")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WADSiriLaunchSignal.shared.request(.spockTalk)
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
            intent: AskAletovIntent(),
            phrases: [
                "Chiedi ad Aletov su \(.applicationName)",
                "Parla con Aletov su \(.applicationName)",
                "Scrivi ad Aletov su \(.applicationName)",
                "Di ad Aletov su \(.applicationName)",
                "Dì ad Aletov su \(.applicationName)",
                "Manda un messaggio ad Aletov su \(.applicationName)",
            ],
            shortTitle: "Aletov",
            systemImageName: "person.wave.2.fill")

        AppShortcut(
            intent: AskSpockIntent(),
            phrases: [
                "Chiedi a Spock su \(.applicationName)",
                "Parla con Spock su \(.applicationName)",
                "Scrivi a Spock su \(.applicationName)",
                "Di a Spock su \(.applicationName)",
                "Dì a Spock su \(.applicationName)",
                "Manda un messaggio a Spock su \(.applicationName)",
            ],
            shortTitle: "Spock",
            systemImageName: "person.wave.2.fill")

        AppShortcut(
            intent: AskGianlutovIntent(),
            phrases: [
                "Chiedi a Gianlutov su \(.applicationName)",
                "Parla con Gianlutov su \(.applicationName)",
                "Scrivi a Gianlutov su \(.applicationName)",
                "Di a Gianlutov su \(.applicationName)",
                "Dì a Gianlutov su \(.applicationName)",
                "Manda un messaggio a Gianlutov su \(.applicationName)",
            ],
            shortTitle: "Gianlutov",
            systemImageName: "person.wave.2.fill")

        AppShortcut(
            intent: AskElenovaIntent(),
            phrases: [
                "Chiedi a Elenova su \(.applicationName)",
                "Chiedi ad Elenova su \(.applicationName)",
                "Parla con Elenova su \(.applicationName)",
                "Scrivi a Elenova su \(.applicationName)",
                "Scrivi ad Elenova su \(.applicationName)",
                "Di a Elenova su \(.applicationName)",
                "Dì a Elenova su \(.applicationName)",
                "Dì ad Elenova su \(.applicationName)",
                "Manda un messaggio a Elenova su \(.applicationName)",
            ],
            shortTitle: "Elenova",
            systemImageName: "person.wave.2.fill")

        AppShortcut(
            intent: AskPolpotovIntent(),
            phrases: [
                "Chiedi a Polpotov su \(.applicationName)",
                "Parla con Polpotov su \(.applicationName)",
                "Scrivi a Polpotov su \(.applicationName)",
                "Di a Polpotov su \(.applicationName)",
                "Dì a Polpotov su \(.applicationName)",
                "Manda un messaggio a Polpotov su \(.applicationName)",
            ],
            shortTitle: "Polpotov",
            systemImageName: "person.wave.2.fill")

        AppShortcut(
            intent: ReadWADIntent(),
            phrases: [
                "Leggi \(.applicationName)",
                "Leggimi \(.applicationName)",
                "Cosa c'è di nuovo su \(.applicationName)",
                "Leggi l'ultimo messaggio di \(\.$canale) su \(.applicationName)",
            ],
            shortTitle: "Leggi WAD",
            systemImageName: "ear.badge.waveform")

        AppShortcut(
            intent: ReadSpockIntent(),
            phrases: [
                "Leggimi l'ultimo messaggio di Spock su \(.applicationName)",
                "Cosa ha detto Spock su \(.applicationName)",
                "Leggi Spock su \(.applicationName)",
            ],
            shortTitle: "Leggi Spock",
            systemImageName: "ear.badge.waveform")

        AppShortcut(
            intent: ReadAletovIntent(),
            phrases: [
                "Leggimi l'ultimo messaggio di Aletov su \(.applicationName)",
                "Cosa ha detto Aletov su \(.applicationName)",
                "Leggi Aletov su \(.applicationName)",
            ],
            shortTitle: "Leggi Aletov",
            systemImageName: "ear.badge.waveform")

        AppShortcut(
            intent: OpenSpockVoiceIntent(),
            phrases: [
                "Avvia Spock vocale su \(.applicationName)",
                "Spock vocale su \(.applicationName)",
                "Modalità voce su \(.applicationName)",
                "Parla a voce con Spock su \(.applicationName)",
            ],
            shortTitle: "Spock vocale",
            systemImageName: "waveform.circle.fill")
        // Limite Apple: 10 App Shortcut per app — con "Spock vocale" siamo al pieno.
        // Niente tile "Apri Chat/Agenti": gli intent restano utilizzabili come
        // azioni manuali in Comandi Rapidi.
    }
}
