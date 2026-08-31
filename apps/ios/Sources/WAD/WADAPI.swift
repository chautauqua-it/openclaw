import AppIntents
import Foundation

enum WADAPIError: LocalizedError {
    case unreachable
    case unauthorized
    case server(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            "Iànua non raggiungibile. Controlla la connessione Internet e riprova."
        case .unauthorized:
            "Sessione scaduta. Esegui di nuovo il login."
        case let .server(message):
            message
        case let .decoding(message):
            "Risposta WAD non valida: \(message)"
        }
    }
}

typealias WADJSON = [String: Any]

enum IanuaPublicEndpointPolicy {
    static let canonicalBaseURL = "https://ianua.differen.it"

    static func normalizedBaseURL(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "ianua.differen.it",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }
        return Self.canonicalBaseURL
    }

    static func resolvedBaseURL(_ persistedValue: String?) -> String {
        self.normalizedBaseURL(persistedValue) ?? self.canonicalBaseURL
    }
}

struct WADRequestOptions: @unchecked Sendable {
    let method: String
    let json: WADJSON?
    let login: Bool
    let rawBody: Data?
    let contentType: String?
    let timeout: TimeInterval

    init(
        method: String = "GET",
        json: WADJSON? = nil,
        login: Bool = false,
        rawBody: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval = 30)
    {
        self.method = method
        self.json = json
        self.login = login
        self.rawBody = rawBody
        self.contentType = contentType
        self.timeout = timeout
    }
}

actor WADAPIClient {
    static let shared = WADAPIClient()

    private let decoder: JSONDecoder

    init() {
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    nonisolated var baseURL: String {
        IanuaPublicEndpointPolicy.resolvedBaseURL(
            UserDefaults.standard.string(forKey: "wad.native.baseURL"))
    }

    nonisolated func setBaseURL(_ url: String) {
        if let normalized = IanuaPublicEndpointPolicy.normalizedBaseURL(url) {
            UserDefaults.standard.set(normalized, forKey: "wad.native.baseURL")
        } else {
            // Migrazione fail-closed: le build precedenti potevano conservare
            // un host tailnet. Un valore non pubblico/non HTTPS non deve mai
            // diventare il percorso ordinario della nuova app Iànua.
            UserDefaults.standard.removeObject(forKey: "wad.native.baseURL")
        }
    }

    private func makeURL(_ path: String) throws -> URL {
        guard let url = URL(string: self.baseURL + path) else {
            throw WADAPIError.server("URL WAD non valido")
        }
        return url
    }

    private func request(_ path: String, options: WADRequestOptions = WADRequestOptions()) async throws -> Data {
        let url = try self.makeURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = options.method
        request.timeoutInterval = options.timeout
        if let json = options.json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let rawBody = options.rawBody {
            request.setValue(options.contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WADAPIError.server("Risposta WAD sconosciuta")
            }
            if http.statusCode == 401 {
                if options.login {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    throw WADAPIError.server(message ?? "Credenziali non valide")
                }
                throw WADAPIError.unauthorized
            }
            if !(200...299).contains(http.statusCode) {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw WADAPIError.server(message ?? "Errore WAD \(http.statusCode)")
            }
            return data
        } catch let error as WADAPIError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost:
                throw WADAPIError.unreachable
            default:
                throw WADAPIError.server(error.localizedDescription)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try self.decoder.decode(T.self, from: data)
        } catch {
            throw WADAPIError.decoding(String(describing: error))
        }
    }

    func login(username: String, password: String) async throws -> WADCurrentUser {
        struct Response: Decodable { let user: WADCurrentUser }
        let data = try await self.request(
            "/api/login",
            options: WADRequestOptions(
                method: "POST",
                json: ["username": username, "password": password],
                login: true))
        return try self.decode(Response.self, from: data).user
    }

    func me() async throws -> WADCurrentUser {
        struct Response: Decodable { let user: WADCurrentUser }
        let data = try await self.request("/api/me")
        return try self.decode(Response.self, from: data).user
    }

    func logout() async throws {
        _ = try await self.request("/api/logout", options: WADRequestOptions(method: "POST"))
    }

    func channels() async throws -> [WADChatChannel] {
        struct Response: Decodable { let channels: [WADChatChannel] }
        let data = try await self.request("/api/chat/channels")
        let channels = try self.decode(Response.self, from: data).channels
        WADChannelCache.store(channels)
        // Ripubblica i valori dei parametri: senza, Siri non impara i nomi di
        // canali/agenti usati nelle frasi parametriche degli AppShortcut.
        WADAppShortcuts.updateAppShortcutParameters()
        return channels
    }

    /// Thread DM di un agente: il server lo crea pigramente alla prima richiesta.
    func agentDM(_ agent: String) async throws -> WADAgentDMSnapshot {
        let encoded = agent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? agent
        let data = try await self.request("/api/agents/\(encoded)/dm")
        return try self.decode(WADAgentDMSnapshot.self, from: data)
    }

    func messages(channelId: String) async throws -> WADChatSnapshot {
        let encoded = channelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channelId
        let data = try await self.request("/api/chat/messages?channel=\(encoded)")
        return try self.decode(WADChatSnapshot.self, from: data)
    }

    func send(
        channelId: String,
        body: String,
        replyTo: String? = nil,
        withAttachments: Bool = false) async throws -> WADChatMessage
    {
        struct Response: Decodable { let message: WADChatMessage }
        var payload: WADJSON = ["channel": channelId, "body": body]
        if let replyTo { payload["reply_to"] = replyTo }
        if withAttachments { payload["with_attachments"] = true }
        let data = try await self.request(
            "/api/chat/messages",
            options: WADRequestOptions(method: "POST", json: payload))
        return try self.decode(Response.self, from: data).message
    }

    func uploadAttachment(messageId: String, name: String, mime: String, data: Data) async throws {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        _ = try await self.request(
            "/api/chat/messages/\(messageId)/attachments?name=\(encodedName)",
            options: WADRequestOptions(method: "POST", rawBody: data, contentType: mime))
    }

    func markReady(messageId: String, timeout: TimeInterval = 30) async throws {
        _ = try await self.request(
            "/api/chat/messages/\(messageId)/ready",
            options: WADRequestOptions(method: "POST", json: [:], timeout: timeout))
    }

    /// Messaggio vocale: audio come allegato riproducibile; al /ready il server
    /// trascrive con whisper e mette il testo nel body (timeout largo apposta).
    func sendVoice(channelId: String, audio: Data, replyTo: String? = nil) async throws -> WADChatMessage {
        let message = try await self.send(channelId: channelId, body: "", replyTo: replyTo, withAttachments: true)
        let name = "vocale-\(Int(Date().timeIntervalSince1970)).m4a"
        try await self.uploadAttachment(messageId: message.id, name: name, mime: "audio/mp4", data: audio)
        try await self.markReady(messageId: message.id, timeout: 150)
        return message
    }

    func setPinned(messageId: String, pinned: Bool) async throws {
        _ = try await self.request(
            "/api/chat/messages/\(messageId)/pin",
            options: WADRequestOptions(method: "POST", json: ["pinned": pinned]))
    }

    func toggleReaction(messageId: String, emoji: String) async throws {
        _ = try await self.request(
            "/api/chat/messages/\(messageId)/react",
            options: WADRequestOptions(method: "POST", json: ["emoji": emoji]))
    }

    /// 🔒 Consegna sicura di una password nel canale: il valore non finisce mai
    /// nel body, il server salva cifrato e nel messaggio resta solo il marker.
    @discardableResult
    func sendSecret(
        channelId: String,
        label: String,
        value: String,
        replyTo: String? = nil) async throws -> WADChatMessage
    {
        struct Response: Decodable { let message: WADChatMessage }
        var payload: WADJSON = ["channel": channelId, "label": label, "value": value]
        if let replyTo { payload["reply_to"] = replyTo }
        let data = try await self.request(
            "/api/chat/secret",
            options: WADRequestOptions(method: "POST", json: payload))
        return try self.decode(Response.self, from: data).message
    }

    /// Rivela il valore di un segreto on-demand. Il valore NON viene mai messo in
    /// cache su disco né in log: resta solo in memoria finché la card è aperta.
    func revealSecret(id: String) async throws -> WADChatSecret {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let data = try await self.request(
            "/api/chat/secrets/\(encoded)/reveal",
            options: WADRequestOptions(method: "POST", json: [:]))
        return try self.decode(WADChatSecret.self, from: data)
    }

    nonisolated func attachmentURL(_ id: String) -> URL? {
        URL(string: self.baseURL + "/api/chat/attachments/\(id)")
    }

    /// Credenziali SIP personali (interno Mercurio) per il telefono nativo.
    func sipConfig() async throws -> WADSipConfig {
        let data = try await self.request("/api/sip/config")
        return try self.decode(WADSipConfig.self, from: data)
    }

    /// Rubrica degli interni RESTART (nome + interno).
    func sipDirectory() async throws -> [WADSipContact] {
        let data = try await self.request("/api/sip/directory")
        return try self.decode(WADSipDirectory.self, from: data).contacts
    }

    /// Preferiti telefonici personali (salvati in WAD: Mercurio non li gestisce).
    func sipFavorites() async throws -> [WADSipFavorite] {
        struct Response: Decodable { let favorites: [WADSipFavorite] }
        let data = try await self.request("/api/sip/favorites")
        return try self.decode(Response.self, from: data).favorites
    }

    @discardableResult
    func addSipFavorite(name: String, number: String, kind: String) async throws -> WADSipFavorite {
        struct Response: Decodable { let favorite: WADSipFavorite }
        let data = try await self.request(
            "/api/sip/favorites",
            options: WADRequestOptions(
                method: "POST",
                json: ["name": name, "number": number, "kind": kind]))
        return try self.decode(Response.self, from: data).favorite
    }

    func deleteSipFavorite(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await self.request(
            "/api/sip/favorites/\(encoded)",
            options: WADRequestOptions(method: "DELETE"))
    }

    /// Stato "Non disturbare" centralizzato sul PBX Mercurio: identico per
    /// web, mobile e telefoni SIP fisici (il server compone *78/*79).
    func sipDnd() async throws -> Bool {
        struct Response: Decodable { let dnd: Bool }
        let data = try await self.request("/api/sip/dnd")
        return try self.decode(Response.self, from: data).dnd
    }

    func setSipDnd(_ on: Bool) async throws -> Bool {
        struct Response: Decodable { let dnd: Bool }
        let data = try await self.request(
            "/api/sip/dnd",
            options: WADRequestOptions(method: "POST", json: ["on": on]))
        return try self.decode(Response.self, from: data).dnd
    }

    /// Registra il token push VoIP (PushKit) dell'utente: lo usa il ponte
    /// Mercurio→APNs per svegliare l'app alle chiamate in arrivo.
    func registerVoipToken(_ token: String) async throws {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        _ = try await self.request(
            "/api/sip/push-token",
            options: WADRequestOptions(
                method: "POST",
                json: ["token": token, "platform": "ios", "environment": environment]))
    }
}

struct WADSipConfig: Codable, Equatable {
    let domain: String
    let ext: String
    let password: String
    let pickupCode: String?
}

struct WADSipFavorite: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let number: String
    let kind: String
}

struct WADSipDirectory: Codable {
    let contacts: [WADSipContact]
}

struct WADSipContact: Codable, Equatable, Identifiable {
    let ext: String
    let name: String
    /// Non disturbare sul PBX Mercurio: true/false, nil se lo stato non è noto.
    let dnd: Bool?
    /// Registrato sul PBX (telefono online): true/false, nil se lo stato non è
    /// noto (Mercurio non raggiunto). Alimenta il semaforo presenza.
    let registered: Bool?
    /// Occupato in una chiamata attiva: true/false, nil se non noto.
    let busy: Bool?
    var id: String {
        self.ext
    }
}

/// Cache locale dei canali per suggerimenti Siri anche ad app fredda.
enum WADChannelCache {
    private static let key = "wad.native.channelCache"

    static func store(_ channels: [WADChatChannel]) {
        let items = channels.map { channel -> [String: String] in
            var item = ["id": channel.id, "name": channel.name]
            if let agent = channel.agent, !agent.isEmpty { item["agent"] = agent }
            return item
        }
        UserDefaults.standard.set(items, forKey: self.key)
    }

    static func load() -> [(id: String, name: String, agent: String?)] {
        guard let items = UserDefaults.standard.array(forKey: self.key) as? [[String: String]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"], let name = item["name"] else { return nil }
            return (id: id, name: name, agent: item["agent"])
        }
    }
}

struct WADCurrentUser: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let username: String?
    let role: String?
}

struct WADChatChannel: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let topic: String?
    let agent: String?
    let model: String?
    let grp: String?
    let lastAt: String?

    static func sortByName(_ lhs: WADChatChannel, _ rhs: WADChatChannel) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

struct WADChatReplyPreview: Codable, Equatable {
    let id: String
    let userName: String
    let kind: String
    let body: String
}

struct WADChatReaction: Codable, Equatable {
    let emoji: String
    let users: [String]
    let count: Int
}

struct WADChatAttachment: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let mime: String
    let size: Int

    var isImage: Bool {
        self.mime.hasPrefix("image/")
    }

    var isAudio: Bool {
        self.mime.hasPrefix("audio/")
    }
}

struct WADChatMessage: Codable, Identifiable, Equatable {
    let id: String
    let channelId: String
    let userId: String?
    let userName: String
    let body: String
    let kind: String
    let replyTo: String?
    let pinned: Bool?
    let createdAt: String
    let reply: WADChatReplyPreview?
    let reactions: [WADChatReaction]?
    let attachments: [WADChatAttachment]?

    var isAgent: Bool {
        self.kind == "agent"
    }

    var isPinned: Bool {
        self.pinned == true
    }

    /// Segreto 🔒 contenuto nel body come marker `[[segreto:<id>|<label>]]`: il
    /// valore non è mai nel testo, si ottiene solo con `revealSecret`.
    var secret: WADSecretMarker? {
        WADSecretMarker.parse(from: self.body)
    }

    /// Body senza il marker del segreto, per non mostrare la stringa grezza.
    var bodyWithoutSecret: String {
        WADSecretMarker.stripping(from: self.body)
    }
}

/// Marker `[[segreto:<id>|<label>]]` estratto dal body di un messaggio.
struct WADSecretMarker: Equatable {
    let id: String
    let label: String

    // id: caratteri "sicuri" (no `|` né `]`); label: tutto tranne `]`.
    private static let regex = try? NSRegularExpression(
        pattern: "\\[\\[segreto:([^|\\]]+)\\|([^\\]]*)\\]\\]")

    static func parse(from body: String) -> WADSecretMarker? {
        guard let regex else { return nil }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              let idRange = Range(match.range(at: 1), in: body),
              let labelRange = Range(match.range(at: 2), in: body) else { return nil }
        let id = String(body[idRange]).trimmingCharacters(in: .whitespaces)
        let label = String(body[labelRange]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        return WADSecretMarker(id: id, label: label)
    }

    static func stripping(from body: String) -> String {
        guard let regex else { return body }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let stripped = regex.stringByReplacingMatches(in: body, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Valore rivelato di un segreto: tenuto solo in memoria, mai persistito.
struct WADChatSecret: Codable, Equatable {
    let label: String
    let value: String
    let senderName: String?
}

struct WADChatBusy: Codable, Equatable {
    let since: Double?
    let beat: Double?
    let status: String?
    let runId: String?
}

struct WADChatSnapshot: Decodable {
    let messages: [WADChatMessage]
    let busy: WADChatBusy?
    let model: String?
}

struct WADAgentDMSnapshot: Decodable {
    let channel: WADChatChannel
    let messages: [WADChatMessage]
    let busy: WADChatBusy?
    let model: String?
}
