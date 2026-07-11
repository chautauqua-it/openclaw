import Foundation

enum WADAPIError: LocalizedError {
    case unreachable
    case unauthorized
    case server(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            "WAD non raggiungibile. Controlla Tailscale."
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

struct WADRequestOptions: @unchecked Sendable {
    let method: String
    let json: WADJSON?
    let login: Bool
    let rawBody: Data?
    let contentType: String?

    init(
        method: String = "GET",
        json: WADJSON? = nil,
        login: Bool = false,
        rawBody: Data? = nil,
        contentType: String? = nil)
    {
        self.method = method
        self.json = json
        self.login = login
        self.rawBody = rawBody
        self.contentType = contentType
    }
}

actor WADAPIClient {
    static let shared = WADAPIClient()
    static let fallbackBaseURL = "https://mac-mini-di-stefano.tail1e9216.ts.net:8456"

    private let decoder: JSONDecoder

    init() {
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    nonisolated var baseURL: String {
        UserDefaults.standard.string(forKey: "wad.native.baseURL") ?? Self.fallbackBaseURL
    }

    nonisolated func setBaseURL(_ url: String) {
        let trimmed = url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        UserDefaults.standard.set(trimmed, forKey: "wad.native.baseURL")
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
        request.timeoutInterval = 30
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

    func markReady(messageId: String) async throws {
        _ = try await self.request(
            "/api/chat/messages/\(messageId)/ready",
            options: WADRequestOptions(method: "POST", json: [:]))
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

    nonisolated func attachmentURL(_ id: String) -> URL? {
        URL(string: self.baseURL + "/api/chat/attachments/\(id)")
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
