import Foundation
import SwiftUI

private enum WADAPIError: LocalizedError {
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

private typealias WADJSON = [String: Any]
private typealias WADChannelGroup = (group: String, channels: [WADChatChannel])

private struct WADRequestOptions: @unchecked Sendable {
    let method: String
    let json: WADJSON?
    let login: Bool

    init(method: String = "GET", json: WADJSON? = nil, login: Bool = false) {
        self.method = method
        self.json = json
        self.login = login
    }
}

private actor WADAPIClient {
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
        request.timeoutInterval = 15
        if let json = options.json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
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
        return try self.decode(Response.self, from: data).channels
    }

    func messages(channelId: String) async throws -> [WADChatMessage] {
        struct Response: Decodable { let messages: [WADChatMessage] }
        let encoded = channelId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channelId
        let data = try await self.request("/api/chat/messages?channel=\(encoded)")
        return try self.decode(Response.self, from: data).messages
    }

    func send(channelId: String, body: String, replyTo: String? = nil) async throws -> WADChatMessage {
        struct Response: Decodable { let message: WADChatMessage }
        var payload: WADJSON = ["channel": channelId, "body": body]
        if let replyTo { payload["reply_to"] = replyTo }
        let data = try await self.request(
            "/api/chat/messages",
            options: WADRequestOptions(method: "POST", json: payload))
        return try self.decode(Response.self, from: data).message
    }

    nonisolated func attachmentURL(_ id: String) -> URL? {
        URL(string: self.baseURL + "/api/chat/attachments/\(id)")
    }
}

private struct WADCurrentUser: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let username: String?
    let role: String?
}

private struct WADChatChannel: Codable, Identifiable, Equatable, Hashable {
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

private struct WADChatReplyPreview: Codable, Equatable {
    let id: String
    let userName: String
    let kind: String
    let body: String
}

private struct WADChatReaction: Codable, Equatable {
    let emoji: String
    let users: [String]
    let count: Int
}

private struct WADChatAttachment: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let mime: String
    let size: Int

    var isImage: Bool {
        self.mime.hasPrefix("image/")
    }
}

private struct WADChatMessage: Codable, Identifiable, Equatable {
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

private func wadParseTimestamp(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]

    for formatter in [withFractional, plain] {
        if let date = formatter.date(from: value) {
            return date
        }
    }
    return nil
}

private func wadShortTime(_ value: String?) -> String {
    guard let date = wadParseTimestamp(value) else { return "" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "it_IT")
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm"
    return formatter.string(from: date)
}

private func wadSortChannelGroups(_ lhs: WADChannelGroup, _ rhs: WADChannelGroup) -> Bool {
    lhs.group.localizedCaseInsensitiveCompare(rhs.group) == .orderedAscending
}

@MainActor
private final class WADChatState: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loggedOut
        case loggedIn
    }

    @Published var phase: Phase = .loading
    @Published var user: WADCurrentUser?
    @Published var loginError: String?
    @Published var busy: Bool = false

    private let api = WADAPIClient.shared

    func bootstrap() async {
        do {
            self.user = try await self.api.me()
            self.phase = .loggedIn
        } catch {
            self.phase = .loggedOut
        }
    }

    func login(username: String, password: String) async {
        self.busy = true
        self.loginError = nil
        defer { self.busy = false }
        do {
            self.user = try await self.api.login(username: username, password: password)
            self.phase = .loggedIn
        } catch {
            self.loginError = (error as? LocalizedError)?.errorDescription ?? "Login fallito"
        }
    }

    func logout() async {
        try? await self.api.logout()
        self.user = nil
        self.phase = .loggedOut
    }
}

struct WADNativeChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = WADChatState()

    var body: some View {
        Group {
            switch self.state.phase {
            case .loading:
                ProgressView("Carico WAD...")
                    .task { await self.state.bootstrap() }
            case .loggedOut:
                WADLoginView()
                    .environmentObject(self.state)
            case .loggedIn:
                WADChannelListView()
                    .environmentObject(self.state)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Chiudi") { self.dismiss() }
            }
        }
    }
}

private struct WADLoginView: View {
    @EnvironmentObject private var state: WADChatState
    @State private var username = ""
    @State private var password = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.tint)
                Text("WAD Chat")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("Canali nativi sincronizzati con WAD web")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    TextField("Username", text: self.$username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: self.$password)
                        .textContentType(.password)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 32)

                if let error = state.loginError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    Task { await self.state.login(username: self.username, password: self.password) }
                } label: {
                    if self.state.busy {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Entra").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
                .disabled(self.username.isEmpty || self.password.isEmpty || self.state.busy)

                Spacer()
                Text("Richiede Tailscale connesso")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { self.showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Impostazioni WAD")
                }
            }
            .sheet(isPresented: self.$showSettings) {
                WADChatSettingsView()
                    .environmentObject(self.state)
            }
        }
    }
}

private struct WADChannelListView: View {
    @EnvironmentObject private var state: WADChatState
    @State private var channels: [WADChatChannel] = []
    @State private var error: String?
    @State private var loading = true
    @State private var showSettings = false

    private let api = WADAPIClient.shared

    var body: some View {
        NavigationStack {
            Group {
                if self.loading, self.channels.isEmpty {
                    ProgressView("Canali...")
                } else if let error, self.channels.isEmpty {
                    self.errorView(error)
                } else {
                    List(self.groupedChannels, id: \.group) { group in
                        Section(group.group) {
                            ForEach(group.channels) { channel in
                                NavigationLink(value: channel) {
                                    WADChannelRow(channel: channel)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await self.load() }
                }
            }
            .navigationTitle("Chat")
            .navigationDestination(for: WADChatChannel.self) { channel in
                WADChatThreadView(channel: channel)
                    .environmentObject(self.state)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { self.showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Impostazioni WAD")
                }
            }
            .sheet(isPresented: self.$showSettings) {
                WADChatSettingsView()
                    .environmentObject(self.state)
            }
            .task { await self.load() }
        }
    }

    private var groupedChannels: [(group: String, channels: [WADChatChannel])] {
        let groups = Dictionary(grouping: self.channels) { channel in
            let trimmed = (channel.grp ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Canali" : trimmed
        }
        return groups
            .map { key, value -> WADChannelGroup in
                let channels = value.sorted(by: WADChatChannel.sortByName)
                return (group: key, channels: channels)
            }
            .sorted(by: wadSortChannelGroups)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Riprova") { Task { await self.load() } }
                .buttonStyle(.bordered)
        }
    }

    private func load() async {
        self.loading = true
        defer { self.loading = false }
        do {
            self.channels = try await self.api.channels()
            self.error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Errore di caricamento"
        }
    }
}

private struct WADChannelRow: View {
    let channel: WADChatChannel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .font(.headline.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.channel.name)
                    .font(.body.weight(.semibold))
                if let topic = channel.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let agent = channel.agent, !agent.isEmpty {
                Text(agent)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WADChatThreadView: View {
    let channel: WADChatChannel
    @EnvironmentObject private var state: WADChatState

    @State private var messages: [WADChatMessage] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var sending = false
    @State private var replyTarget: WADChatMessage?
    @State private var pollTask: Task<Void, Never>?

    private let api = WADAPIClient.shared

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color.red.opacity(0.85))
            }
            self.messageList
            self.composer
        }
        .navigationTitle("#\(self.channel.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await self.load(initial: true)
            self.startPolling()
        }
        .onDisappear {
            self.pollTask?.cancel()
            self.pollTask = nil
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(self.messages) { message in
                        WADMessageBubbleView(message: message, isMine: self.isMine(message))
                            .id(message.id)
                            .onTapGesture { self.replyTarget = message }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: self.messages.count) { _, _ in
                if let last = self.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let reply = replyTarget {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption2)
                    Text("Rispondi a \(reply.userName): \(reply.body.prefix(48))")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { self.replyTarget = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                TextField("Messaggio...", text: self.$draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button { Task { await self.sendDraft() } } label: {
                    if self.sending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.sending)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func isMine(_ message: WADChatMessage) -> Bool {
        guard let userId = self.state.user?.id else { return false }
        return message.userId == userId
    }

    private func load(initial: Bool) async {
        do {
            self.messages = try await self.api.messages(channelId: self.channel.id)
            self.error = nil
        } catch {
            if initial || self.messages.isEmpty {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Errore"
            }
        }
    }

    private func startPolling() {
        self.pollTask?.cancel()
        self.pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                await self.load(initial: false)
            }
        }
    }

    private func sendDraft() async {
        let body = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        self.sending = true
        defer { self.sending = false }
        do {
            let message = try await self.api.send(channelId: self.channel.id, body: body, replyTo: self.replyTarget?.id)
            self.draft = ""
            self.replyTarget = nil
            if !self.messages.contains(where: { $0.id == message.id }) {
                self.messages.append(message)
            }
            self.error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Invio fallito"
        }
    }
}

private struct WADMessageBubbleView: View {
    let message: WADChatMessage
    let isMine: Bool

    private let api = WADAPIClient.shared

    var body: some View {
        HStack {
            if self.isMine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(self.message.userName)
                        .font(.caption.bold())
                        .foregroundStyle(self.message.isAgent ? Color.accentColor : .primary)
                    if self.message.isAgent {
                        Image(systemName: "cpu")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if self.message.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                if let reply = message.reply {
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(.secondary)
                            .frame(width: 2)
                        Text("\(reply.userName): \(reply.body)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if !self.message.body.isEmpty {
                    Text(self.message.body)
                        .font(.body)
                        .textSelection(.enabled)
                }
                self.attachmentsView
                if let reactions = message.reactions, !reactions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(reactions, id: \.emoji) { reaction in
                            Text("\(reaction.emoji) \(reaction.count)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                    }
                }
                Text(wadShortTime(self.message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(self.bubbleColor)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !self.isMine { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        if self.isMine { return Color.accentColor.opacity(0.18) }
        if self.message.isAgent { return Color(.secondarySystemBackground) }
        return Color(.tertiarySystemBackground)
    }

    @ViewBuilder
    private var attachmentsView: some View {
        if let attachments = message.attachments, !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(attachments) { attachment in
                    if attachment.isImage, let url = api.attachmentURL(attachment.id) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            case .failure:
                                self.attachmentChip(attachment)
                            default:
                                ProgressView().frame(height: 80)
                            }
                        }
                    } else if let url = api.attachmentURL(attachment.id) {
                        Link(destination: url) {
                            self.attachmentChip(attachment)
                        }
                    }
                }
            }
        }
    }

    private func attachmentChip(_ attachment: WADChatAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
            Text(attachment.name).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary)
        .clipShape(Capsule())
    }
}

private struct WADChatSettingsView: View {
    @EnvironmentObject private var state: WADChatState
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = WADAPIClient.shared.baseURL

    private let api = WADAPIClient.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Server WAD") {
                    TextField("https://...ts.net:8456", text: self.$baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Salva URL") {
                        self.api.setBaseURL(self.baseURL)
                        self.baseURL = self.api.baseURL
                    }
                }
                if let user = state.user {
                    Section("Account") {
                        LabeledContent("Nome", value: user.name)
                        if let role = user.role {
                            LabeledContent("Ruolo", value: role)
                        }
                    }
                    Section {
                        Button("Logout", role: .destructive) {
                            Task {
                                await self.state.logout()
                                self.dismiss()
                            }
                        }
                    }
                }
                Section {
                    LabeledContent("Versione", value: "WAD Chat nativa")
                    Text("La chat usa le API WAD, non il sito web incorporato.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Impostazioni WAD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { self.dismiss() }
                }
            }
        }
    }
}
