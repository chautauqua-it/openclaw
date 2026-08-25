import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

private typealias WADChannelGroup = (group: String, channels: [WADChatChannel])

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

// MARK: - Iànua Chat autoritativa

private struct IanuaRunStatus: Decodable, Equatable { let status: String }

private struct IanuaChannel: Decodable, Identifiable, Hashable {
    let id: String
    let rawName: String?
    let nome: String?
    let email: String?
    let emoji: String?
    let topic: String?
    let sottotitolo: String?
    let unread: Int?
    let archived: Bool?
    let runStatus: IanuaRunStatus?

    /// I colleghi arrivano dal server con `nome`/`email`, gli altri canali con `name`.
    var name: String {
        self.rawName ?? self.nome ?? self.email ?? self.id
    }

    var subtitle: String? {
        let value = self.topic ?? self.sottotitolo ?? self.email
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    var isBusy: Bool {
        let status = self.runStatus?.status
        return status == "queued" || status == "running"
    }

    enum CodingKeys: String, CodingKey {
        case id, nome, email, emoji, topic, sottotitolo, unread, archived
        case rawName = "name"
        case runStatus = "run_status"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.unread == rhs.unread
            && lhs.runStatus == rhs.runStatus
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }
}

private struct IanuaMe: Decodable {
    let userId: Int?
    enum CodingKeys: String, CodingKey { case userId = "user_id" }
}

private struct IanuaChannelPayload: Decodable {
    let agent: IanuaChannel
    let agents: [IanuaChannel]
    let agentChannels: [IanuaChannel]
    let groups: [IanuaChannel]
    let colleagues: [IanuaChannel]
    let me: IanuaMe?
    enum CodingKeys: String, CodingKey {
        case agent, agents, groups, colleagues, me
        case agentChannels = "agent_channels"
    }
}

private struct IanuaAttachment: Decodable, Identifiable {
    let id: String; let name: String; let mime: String?; let size: Int?
    var isImage: Bool {
        (self.mime ?? "").hasPrefix("image/")
    }

    var isAudio: Bool {
        (self.mime ?? "").hasPrefix("audio/")
    }
}

private struct IanuaReaction: Decodable { let emoji: String; let n: Int; let mine: Bool }

private struct IanuaMessage: Decodable, Identifiable {
    let id: Int; let userId: Int?; let autore: String; let role: String; let body: String
    let replyTo: Int?; let pinned: Bool?; let createdAt: String?
    let replyAutore: String?; let replyBody: String?
    let reactions: [IanuaReaction]?; let attachments: [IanuaAttachment]?

    /// Il marker 🔒 è identico a quello WAD: [[segreto:<id>|<label>]].
    var secret: WADSecretMarker? {
        WADSecretMarker.parse(from: self.body)
    }

    var bodyWithoutSecret: String {
        WADSecretMarker.stripping(from: self.body)
    }

    enum CodingKeys: String, CodingKey {
        case id, autore, role, body, pinned, reactions, attachments
        case userId = "user_id", replyTo = "reply_to", createdAt = "created_at"
        case replyAutore = "reply_autore", replyBody = "reply_body"
    }
}

private struct IanuaChatSnapshot {
    let messages: [IanuaMessage]
    let typing: Bool
    let typingStep: String?
}

private struct IanuaSecret: Decodable {
    let label: String; let value: String; let senderName: String?
    enum CodingKeys: String, CodingKey { case label, value; case senderName = "sender_name" }
}

private actor IanuaChatAPI {
    static let shared = IanuaChatAPI()
    let baseURL = "https://ianua.differen.it"
    private let decoder: JSONDecoder = { let value = JSONDecoder(); return value }()

    private func call(
        _ path: String,
        method: String = "GET",
        json: [String: Any]? = nil,
        data: Data? = nil,
        mime: String? = nil) async throws -> Data
    {
        guard let url = URL(string: self.baseURL + path) else { throw WADAPIError.server("URL Iànua non valido") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 35
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type") }
        if let data { request.httpBody = data; request.setValue(
            mime ?? "application/octet-stream",
            forHTTPHeaderField: "Content-Type") }
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WADAPIError.unreachable }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
            throw http.statusCode == 401 ? WADAPIError.unauthorized : WADAPIError
                .server(message ?? "Errore Iànua \(http.statusCode)")
        }
        return body
    }

    func authenticated() async -> Bool {
        await (try? self.call("/api/me")) != nil
    }

    func login(email: String, password: String) async throws {
        _ = try await self.call(
            "/api/login",
            method: "POST",
            json: ["email": email, "password": password])
    }

    func logout() {
        HTTPCookieStorage.shared.cookies?.filter { $0.domain.contains("ianua.differen.it") }
            .forEach(HTTPCookieStorage.shared.deleteCookie)
    }

    func channels() async throws -> IanuaChannelPayload {
        try await self.decoder.decode(IanuaChannelPayload.self, from: self.call("/api/op/channels"))
    }

    func snapshot(channel: String) async throws -> IanuaChatSnapshot {
        let value = channel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channel
        struct Phase: Decodable { let step: String? }
        struct Payload: Decodable {
            let messages: [IanuaMessage]; let typing: Bool?; let typingPhase: Phase?
            enum CodingKeys: String, CodingKey { case messages, typing; case typingPhase = "typing_phase" }
        }
        let payload = try await self.decoder.decode(
            Payload.self,
            from: self.call("/api/op/chat?channel=\(value)&after=0"))
        return IanuaChatSnapshot(
            messages: payload.messages,
            typing: payload.typing ?? false,
            typingStep: payload.typingPhase?.step)
    }

    func send(channel: String, body: String, reply: Int?, attachments: [String] = []) async throws {
        var json: [String: Any] = ["channel": channel, "body": body, "client_req_id": UUID().uuidString.lowercased()]
        if let reply { json["reply_to"] = reply }
        if !attachments.isEmpty { json["attachments"] = attachments }
        _ = try await self.call("/api/op/chat", method: "POST", json: json)
    }

    func markRead(channel: String, id: Int) async throws {
        _ = try await self.call(
            "/api/op/chat/read",
            method: "POST",
            json: ["channel": channel, "last_id": id])
    }

    func react(message: Int, emoji: String) async throws {
        _ = try await self.call(
            "/api/op/chat/react",
            method: "POST",
            json: ["message_id": message, "emoji": emoji])
    }

    func pin(message: Int, value: Bool) async throws {
        _ = try await self.call(
            "/api/op/chat/pin",
            method: "POST",
            json: ["message_id": message, "pinned": value])
    }

    func upload(name: String, data: Data, mime: String? = nil) async throws -> String {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "file.bin"
        struct Payload: Decodable { let attachment: IanuaAttachment }
        return try await self.decoder.decode(
            Payload.self,
            from: self.call("/api/op/chat/upload?name=\(safe)", method: "PUT", data: data, mime: mime)).attachment.id
    }

    func sendSecret(channel: String, label: String, value: String) async throws {
        _ = try await self.call(
            "/api/op/chat/secret",
            method: "POST",
            json: ["channel": channel, "label": label, "value": value])
    }

    func revealSecret(id: String) async throws -> IanuaSecret {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await self.decoder.decode(
            IanuaSecret.self,
            from: self.call("/api/op/chat/secrets/\(encoded)/reveal", method: "POST", json: [:]))
    }

    nonisolated func attachmentURL(_ id: String) -> URL? {
        URL(string: self.baseURL + "/api/op/chat/att/\(id)")
    }
}

@MainActor private final class IanuaChatModel: ObservableObject {
    enum Phase: Equatable { case loading, loggedOut, loggedIn }

    @Published var phase: Phase = .loading
    @Published var payload: IanuaChannelPayload?
    @Published var error: String?
    @Published var busy = false

    var myUserId: Int? {
        self.payload?.me?.userId
    }

    func bootstrap() async {
        if await IanuaChatAPI.shared.authenticated() {
            self.phase = .loggedIn
            await self.reload()
            // PushKit può consegnare il token VoIP prima che la sessione sia
            // valida: dopo il bootstrap autenticato serve un retry esplicito.
            WADCallCenter.shared.refreshVoipTokenRegistration()
        } else {
            self.phase = .loggedOut
        }
    }

    func login(email: String, password: String) async {
        self.busy = true
        self.error = nil
        defer { self.busy = false }
        do {
            try await IanuaChatAPI.shared.login(email: email, password: password)
            self.phase = .loggedIn
            await self.reload()
            WADCallCenter.shared.refreshVoipTokenRegistration()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Login fallito"
        }
    }

    func logout() async {
        await IanuaChatAPI.shared.logout()
        self.payload = nil
        self.phase = .loggedOut
    }

    func reload() async {
        do {
            self.payload = try await IanuaChatAPI.shared.channels()
            self.error = nil
        } catch {
            if case WADAPIError.unauthorized = error {
                self.phase = .loggedOut
                return
            }
            if self.payload == nil {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Errore di caricamento"
            }
        }
    }
}

struct IanuaNativeChatSheet: View {
    @StateObject private var model = IanuaChatModel()

    var body: some View {
        NavigationStack {
            switch self.model.phase {
            case .loading:
                ProgressView("Carico Iànua...")
                    .task { await self.model.bootstrap() }
            case .loggedOut:
                IanuaLoginView()
                    .environmentObject(self.model)
            case .loggedIn:
                IanuaChannelListView()
                    .environmentObject(self.model)
            }
        }
    }
}

private struct IanuaLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: IanuaChatModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("IanuaMark")
                .resizable()
                .scaledToFit()
                .frame(height: 64)
                .accessibilityLabel("Iànua")
            Text("Iànua Chat")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Assistente, agenti, gruppi e colleghi del tuo tenant")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                TextField("Email", text: self.$email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: self.$password)
                    .textContentType(.password)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 32)

            if let error = model.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                Task { await self.model.login(email: self.email, password: self.password) }
            } label: {
                if self.model.busy {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Entra").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .disabled(self.email.isEmpty || self.password.isEmpty || self.model.busy)

            Spacer()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { self.dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Chiudi chat")
            }
        }
    }
}

private struct IanuaChannelListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: IanuaChatModel

    var body: some View {
        Group {
            if let payload = model.payload {
                self.channelList(payload)
            } else if let error = model.error {
                self.errorView(error)
            } else {
                ProgressView("Canali...")
            }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image("IanuaMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 20)
                    Text("Chat").font(.headline)
                }
                .accessibilityLabel("Chat Iànua")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { self.dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Chiudi chat")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await self.model.reload() } } label: {
                        Label("Aggiorna", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { Task { await self.model.logout() } } label: {
                        Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Opzioni")
            }
        }
        .navigationDestination(for: IanuaChannel.self) { channel in
            IanuaThreadView(channel: channel)
                .environmentObject(self.model)
        }
        .task {
            // Aggiorna i badge non letti mentre la lista resta a schermo.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { break }
                await self.model.reload()
            }
        }
    }

    private func channelList(_ payload: IanuaChannelPayload) -> some View {
        let channels = payload.agentChannels.filter { $0.archived != true }
        return List {
            Section("Assistente") {
                self.row(payload.agent, icon: "sparkles")
            }
            if !payload.agents.isEmpty {
                Section("Agenti") {
                    ForEach(payload.agents) { self.row($0, icon: "person.crop.square.badge.camera") }
                }
            }
            if !channels.isEmpty {
                Section("Canali") {
                    ForEach(channels) { self.row($0, icon: "number") }
                }
            }
            if !payload.groups.isEmpty {
                Section("Gruppi") {
                    ForEach(payload.groups) { self.row($0, icon: "person.3.fill") }
                }
            }
            if !payload.colleagues.isEmpty {
                Section("Colleghi") {
                    ForEach(payload.colleagues) { self.row($0, icon: "person.fill") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await self.model.reload() }
    }

    private func row(_ channel: IanuaChannel, icon: String) -> some View {
        NavigationLink(value: channel) {
            IanuaChannelRow(channel: channel, icon: icon)
        }
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
            Button("Riprova") { Task { await self.model.reload() } }
                .buttonStyle(.bordered)
        }
    }
}

private struct IanuaChannelRow: View {
    let channel: IanuaChannel
    let icon: String

    private var unread: Int {
        self.channel.unread ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            if let emoji = channel.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.title3)
                    .frame(width: 24)
            } else {
                Image(systemName: self.icon)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(self.channel.name)
                    .font(.body.weight(self.unread > 0 ? .bold : .semibold))
                if let subtitle = channel.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if self.channel.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Risposta in corso")
            }
            if self.unread > 0 {
                Text("\(self.unread)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                    .accessibilityLabel("\(self.unread) messaggi non letti")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct IanuaThreadView: View {
    let channel: IanuaChannel
    @EnvironmentObject private var model: IanuaChatModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var messages: [IanuaMessage] = []
    @State private var typing = false
    @State private var typingStep = ""
    @State private var draft = ""
    @State private var error: String?
    @State private var sending = false
    @State private var replyTarget: IanuaMessage?
    @State private var pollTask: Task<Void, Never>?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pendingAttachments: [WADPendingAttachment] = []
    @State private var showDocumentPicker = false
    @State private var showSecretSheet = false
    @State private var showPinned = false
    @State private var scrollTarget: Int?
    @State private var seenIds: Set<Int> = []
    @State private var notifiedIds: Set<Int> = []
    @State private var lastReadId = 0
    @StateObject private var voiceRecorder = WADVoiceRecorder()

    private var isAgentChannel: Bool {
        self.channel.id == "agent" || self.channel.id.hasPrefix("agent:")
    }

    private var pinnedMessages: [IanuaMessage] {
        self.messages.filter { $0.pinned == true }
    }

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
        .navigationTitle(self.channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { self.showPinned = true } label: {
                    Image(systemName: "pin")
                }
                .accessibilityLabel("Messaggi fissati")
                .disabled(self.pinnedMessages.isEmpty)
            }
        }
        .sheet(isPresented: self.$showPinned) {
            IanuaPinnedMessagesView(messages: self.pinnedMessages) { message in
                self.showPinned = false
                self.scrollTarget = message.id
            }
        }
        .sheet(isPresented: self.$showSecretSheet) {
            IanuaSendSecretView(channelId: self.channel.id) { await self.load(initial: false) }
        }
        .task {
            await self.load(initial: true)
            self.startPolling()
        }
        .onDisappear {
            self.pollTask?.cancel()
            self.pollTask = nil
            self.voiceRecorder.cancel()
            Task { await self.model.reload() }
        }
        .onChange(of: self.photoItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            Task { await self.importPhotos(newValue) }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(self.messages) { message in
                        IanuaMessageBubbleView(message: message, isMine: self.isMine(message))
                            .id(message.id)
                            .contextMenu { self.messageMenu(message) }
                    }
                    if self.typing, self.isAgentChannel {
                        WADTypingIndicatorView(agentName: self.channel.name, status: self.typingStep)
                            .id(-1)
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
            .onChange(of: self.typing) { _, isTyping in
                if isTyping { withAnimation { proxy.scrollTo(-1, anchor: .bottom) } }
            }
            .onChange(of: self.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                self.scrollTarget = nil
            }
        }
    }

    @ViewBuilder
    private func messageMenu(_ message: IanuaMessage) -> some View {
        Section {
            ForEach(["👍", "❤️", "😂", "✅", "👀", "🚀"], id: \.self) { emoji in
                Button(emoji) {
                    Task { await self.react(message, emoji: emoji) }
                }
            }
        }
        Button {
            self.replyTarget = message
        } label: {
            Label("Rispondi", systemImage: "arrowshape.turn.up.left")
        }
        Button {
            Task { await self.setPinned(message, pinned: message.pinned != true) }
        } label: {
            Label(
                message.pinned == true ? "Sblocca" : "Fissa",
                systemImage: message.pinned == true ? "pin.slash" : "pin")
        }
        if !message.bodyWithoutSecret.isEmpty {
            Button {
                UIPasteboard.general.string = message.bodyWithoutSecret
            } label: {
                Label("Copia testo", systemImage: "doc.on.doc")
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let reply = replyTarget {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption2)
                    Text("Rispondi a \(reply.autore): \(reply.bodyWithoutSecret.prefix(48))")
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
            if !self.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(self.pendingAttachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                if let preview = attachment.preview {
                                    Image(uiImage: preview)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    VStack(spacing: 3) {
                                        Image(systemName: "doc.fill")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                        Text(attachment.name)
                                            .font(.system(size: 8))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .padding(4)
                                    .frame(width: 56, height: 56)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button {
                                    self.pendingAttachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
            }
            if self.voiceRecorder.state == .recording {
                self.recordingBar
            } else {
                HStack(spacing: 8) {
                    PhotosPicker(
                        selection: self.$photoItems,
                        maxSelectionCount: 4,
                        matching: .images)
                    {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title3)
                    }
                    .disabled(self.sending)
                    Button { self.showDocumentPicker = true } label: {
                        Image(systemName: "paperclip")
                            .font(.title3)
                    }
                    .disabled(self.sending)
                    .accessibilityLabel("Allega documento")
                    .fileImporter(
                        isPresented: self.$showDocumentPicker,
                        allowedContentTypes: [.item],
                        allowsMultipleSelection: true)
                    { result in
                        if case let .success(urls) = result {
                            self.importDocuments(urls)
                        }
                    }
                    Button { self.showSecretSheet = true } label: {
                        Image(systemName: "lock")
                            .font(.title3)
                    }
                    .disabled(self.sending)
                    .accessibilityLabel("Invia password sicura")
                    TextField("Messaggio...", text: self.$draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    if self.canSend {
                        Button { Task { await self.sendDraft() } } label: {
                            if self.sending {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title2)
                            }
                        }
                        .disabled(self.sending)
                    } else {
                        Button { Task { await self.voiceRecorder.start() } } label: {
                            if self.sending {
                                ProgressView()
                            } else {
                                Image(systemName: "mic.circle.fill")
                                    .font(.title2)
                            }
                        }
                        .disabled(self.sending)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if self.voiceRecorder.state == .denied {
                    Text("Microfono negato: abilitalo in Impostazioni")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.bottom, 4)
                }
            }
        }
        .background(.bar)
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button {
                self.voiceRecorder.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Annulla registrazione")
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(Int(self.voiceRecorder.elapsed * 2) % 2 == 0 ? 1 : 0.35)
            Text(self.recordingTime)
                .font(.body.monospacedDigit().weight(.semibold))
            Text("Sto registrando...")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await self.sendVoiceNote() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .accessibilityLabel("Invia messaggio vocale")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var recordingTime: String {
        let total = Int(self.voiceRecorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var canSend: Bool {
        !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !self.pendingAttachments.isEmpty
    }

    private func isMine(_ message: IanuaMessage) -> Bool {
        guard let mine = self.model.myUserId, let userId = message.userId else { return false }
        return userId == mine
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else { continue }
            let jpeg = image.jpegData(compressionQuality: 0.82) ?? data
            let name = "foto-\(self.pendingAttachments.count + 1).jpg"
            self.pendingAttachments.append(
                WADPendingAttachment(data: jpeg, name: name, mime: "image/jpeg", preview: image))
        }
        self.photoItems = []
    }

    /// Il server accetta fino a 6 allegati per messaggio e 20 MB per file.
    private func importDocuments(_ urls: [URL]) {
        let maxBytes = 20 * 1024 * 1024
        for url in urls.prefix(max(0, 6 - self.pendingAttachments.count)) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                self.error = "Impossibile leggere \(url.lastPathComponent)"
                continue
            }
            guard data.count <= maxBytes else {
                self.error = "\(url.lastPathComponent) supera i 20 MB"
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            let preview = mime.hasPrefix("image/") ? UIImage(data: data) : nil
            self.pendingAttachments.append(
                WADPendingAttachment(data: data, name: url.lastPathComponent, mime: mime, preview: preview))
        }
    }

    private func load(initial: Bool) async {
        do {
            let snapshot = try await IanuaChatAPI.shared.snapshot(channel: self.channel.id)
            if initial {
                self.seenIds = Set(snapshot.messages.map(\.id))
            } else {
                await self.notifyIfNeeded(for: snapshot.messages)
                self.seenIds.formUnion(snapshot.messages.map(\.id))
            }
            self.messages = snapshot.messages
            self.typing = snapshot.typing
            self.typingStep = snapshot.typingStep ?? ""
            if self.scenePhase == .active, let last = snapshot.messages.last?.id, last > self.lastReadId {
                self.lastReadId = last
                try? await IanuaChatAPI.shared.markRead(channel: self.channel.id, id: last)
            }
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
        let attachments = self.pendingAttachments
        guard !body.isEmpty || !attachments.isEmpty else { return }
        self.sending = true
        defer { self.sending = false }
        do {
            var ids: [String] = []
            for attachment in attachments {
                try await ids.append(IanuaChatAPI.shared.upload(
                    name: attachment.name,
                    data: attachment.data,
                    mime: attachment.mime))
            }
            try await IanuaChatAPI.shared.send(
                channel: self.channel.id,
                body: body,
                reply: self.replyTarget?.id,
                attachments: ids)
            self.draft = ""
            self.replyTarget = nil
            self.pendingAttachments = []
            await self.load(initial: false)
            self.error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Invio fallito"
        }
    }

    private func sendVoiceNote() async {
        guard let audio = self.voiceRecorder.stop() else { return }
        self.sending = true
        defer { self.sending = false }
        do {
            let name = "vocale-\(Int(Date().timeIntervalSince1970)).m4a"
            let id = try await IanuaChatAPI.shared.upload(name: name, data: audio, mime: "audio/mp4")
            try await IanuaChatAPI.shared.send(
                channel: self.channel.id,
                body: self.draft.trimmingCharacters(in: .whitespacesAndNewlines),
                reply: self.replyTarget?.id,
                attachments: [id])
            self.draft = ""
            self.replyTarget = nil
            await self.load(initial: false)
            self.error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Invio vocale fallito"
        }
    }

    private func react(_ message: IanuaMessage, emoji: String) async {
        do {
            try await IanuaChatAPI.shared.react(message: message.id, emoji: emoji)
            await self.load(initial: false)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Reazione fallita"
        }
    }

    private func setPinned(_ message: IanuaMessage, pinned: Bool) async {
        do {
            try await IanuaChatAPI.shared.pin(message: message.id, value: pinned)
            await self.load(initial: false)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Operazione fallita"
        }
    }

    private func notifyIfNeeded(for messages: [IanuaMessage]) async {
        guard self.scenePhase != .active else { return }
        let mine = self.model.myUserId
        let newMessages = messages.filter { message in
            !self.seenIds.contains(message.id)
                && !self.notifiedIds.contains(message.id)
                && (mine == nil || message.userId != mine)
        }
        guard !newMessages.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
        else { return }

        for message in newMessages.suffix(3) {
            let preview: String = {
                if let secret = message.secret { return "🔒 \(secret.label)" }
                if !message.bodyWithoutSecret.isEmpty { return String(message.bodyWithoutSecret.prefix(180)) }
                if !(message.attachments ?? []).isEmpty { return "📎 Allegato" }
                return ""
            }()
            guard !preview.isEmpty else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(self.channel.name) · \(message.autore)"
            content.body = preview
            content.sound = .default
            content.userInfo = [
                "ianuaChannelId": self.channel.id,
                "ianuaMessageId": message.id,
            ]
            let request = UNNotificationRequest(
                identifier: "ianua-chat-\(message.id)",
                content: content,
                trigger: nil)
            try? await center.add(request)
            self.notifiedIds.insert(message.id)
        }
    }
}

private struct IanuaMessageBubbleView: View {
    let message: IanuaMessage
    let isMine: Bool

    var body: some View {
        HStack {
            if self.isMine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(self.message.autore)
                        .font(.caption.bold())
                        .foregroundStyle(self.message.role == "agente" ? Color.accentColor : .primary)
                    if self.message.role == "agente" {
                        Image(systemName: "cpu")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if self.message.pinned == true {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                if let replyAuthor = message.replyAutore {
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(.secondary)
                            .frame(width: 2)
                        Text("\(replyAuthor): \(self.message.replyBody ?? "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if !self.message.bodyWithoutSecret.isEmpty {
                    Text(self.message.bodyWithoutSecret)
                        .font(.body)
                        .textSelection(.enabled)
                }
                if let secret = message.secret {
                    IanuaSecretCardView(secret: secret)
                }
                self.attachmentsView
                if let reactions = message.reactions, !reactions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(reactions, id: \.emoji) { reaction in
                            Text("\(reaction.emoji) \(reaction.n)")
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
        if self.message.role == "agente" { return Color(.secondarySystemBackground) }
        return Color(.tertiarySystemBackground)
    }

    @ViewBuilder
    private var attachmentsView: some View {
        if let attachments = message.attachments, !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(attachments) { attachment in
                    if let url = IanuaChatAPI.shared.attachmentURL(attachment.id) {
                        if attachment.isImage {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case let .success(image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                case .failure:
                                    self.attachmentChip(attachment, url: url)
                                default:
                                    ProgressView().frame(height: 80)
                                }
                            }
                        } else if attachment.isAudio {
                            WADVoiceAttachmentView(url: url, name: attachment.name)
                        } else {
                            self.attachmentChip(attachment, url: url)
                        }
                    }
                }
            }
        }
    }

    private func attachmentChip(_ attachment: IanuaAttachment, url: URL) -> some View {
        Link(destination: url) {
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
}

/// 🔒 Card di una password consegnata in chat Iànua: il valore si vede solo con
/// «Rivela», resta in memoria e non viene mai copiato su disco o in log.
private struct IanuaSecretCardView: View {
    let secret: WADSecretMarker

    @State private var revealed: IanuaSecret?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(self.secret.label.isEmpty ? "Password" : self.secret.label)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            if let revealed {
                Text(revealed.value)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button {
                    UIPasteboard.general.string = revealed.value
                } label: {
                    Label("Copia", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
            } else {
                Button {
                    Task { await self.reveal() }
                } label: {
                    if self.busy {
                        ProgressView()
                    } else {
                        Text("Rivela")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.busy)
            }
            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.accentColor.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func reveal() async {
        self.busy = true
        self.error = nil
        defer { self.busy = false }
        do {
            self.revealed = try await IanuaChatAPI.shared.revealSecret(id: self.secret.id)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Impossibile rivelare"
        }
    }
}

/// Invio di una password 🔒 in un canale Iànua: il valore viaggia cifrato e non
/// compare mai nel testo del messaggio.
private struct IanuaSendSecretView: View {
    let channelId: String
    let onSent: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var value = ""
    @State private var busy = false
    @State private var error: String?

    private var canSend: Bool {
        !self.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !self.value.isEmpty && !self.busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Cosa è la password") {
                    TextField("es. admin firewall Rossi", text: self.$label)
                        .autocorrectionDisabled()
                }
                Section("Valore") {
                    SecureField("Password", text: self.$value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Section {
                    Text(
                        "Il valore viene cifrato dal server: nel messaggio appare solo un 🔒 e si legge con «Rivela». Scade da solo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Password sicura 🔒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annulla") { self.dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await self.send() }
                    } label: {
                        if self.busy { ProgressView() } else { Text("Invia") }
                    }
                    .disabled(!self.canSend)
                }
            }
        }
    }

    private func send() async {
        self.busy = true
        self.error = nil
        do {
            try await IanuaChatAPI.shared.sendSecret(
                channel: self.channelId,
                label: self.label.trimmingCharacters(in: .whitespacesAndNewlines),
                value: self.value)
            await self.onSent()
            self.dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Invio fallito"
        }
        self.busy = false
    }
}

/// Elenco dei messaggi fissati del canale Iànua, con salto al messaggio.
private struct IanuaPinnedMessagesView: View {
    let messages: [IanuaMessage]
    let onSelect: (IanuaMessage) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if self.messages.isEmpty {
                    ContentUnavailableView("Nessun messaggio fissato", systemImage: "pin.slash")
                } else {
                    List(self.messages) { message in
                        Button { self.onSelect(message) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.autore)
                                    .font(.caption.bold())
                                    .foregroundStyle(.tint)
                                Text(message.secret != nil ? "🔒 \(message.secret?.label ?? "Password")" : message
                                    .bodyWithoutSecret)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                Text(wadShortTime(message.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fissati")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { self.dismiss() }
                }
            }
        }
    }
}

private func wadShortTime(_ value: String?) -> String {
    guard let date = wadParseTimestamp(value) else { return "" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "it_IT")
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm"
    return formatter.string(from: date)
}

private struct WADPendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let name: String
    let mime: String
    let preview: UIImage? // nil = documento generico (chip con icona)
}

private struct WADTypingIndicatorView: View {
    let agentName: String
    let status: String

    @State private var phase = 0

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(self.agentName)
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                                .opacity(self.phase == index ? 1 : 0.35)
                        }
                    }
                }
                if !self.status.isEmpty {
                    Text(self.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Spacer(minLength: 40)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.phase = (self.phase + 1) % 3
            }
        }
    }
}
