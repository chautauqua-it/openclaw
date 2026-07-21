import Foundation
import PhotosUI
import SwiftUI
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
            WADCallCenter.shared.refreshVoipTokenRegistration()
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
            WADCallCenter.shared.refreshVoipTokenRegistration()
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
    }
}

private struct WADLoginView: View {
    @Environment(\.dismiss) private var dismiss
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { self.dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Chiudi chat WAD")
                }
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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: WADChatState
    @State private var channels: [WADChatChannel] = []
    @State private var dmChannels: [WADChatChannel] = []
    @State private var error: String?
    @State private var loading = true
    @State private var showSettings = false
    @State private var showPhone = false

    private let api = WADAPIClient.shared

    var body: some View {
        NavigationStack {
            Group {
                if self.loading, self.channels.isEmpty {
                    ProgressView("Canali...")
                } else if let error, self.channels.isEmpty {
                    self.errorView(error)
                } else {
                    List {
                        if !self.dmChannels.isEmpty {
                            Section("Agenti") {
                                ForEach(self.dmChannels) { channel in
                                    NavigationLink(value: channel) {
                                        WADAgentDMRow(channel: channel)
                                    }
                                }
                            }
                        }
                        ForEach(self.groupedChannels, id: \.group) { group in
                            Section(group.group) {
                                ForEach(group.channels) { channel in
                                    NavigationLink(value: channel) {
                                        WADChannelRow(channel: channel)
                                    }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { self.dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Chiudi chat WAD")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { self.showPhone = true } label: {
                        Image(systemName: "phone")
                    }
                    .accessibilityLabel("Telefono Mercurio")
                }
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
            .sheet(isPresented: self.$showPhone) {
                WADPhoneSheet()
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
        await self.loadAgentDMs()
    }

    private func loadAgentDMs() async {
        let agents = Set(self.channels.compactMap { channel -> String? in
            guard let agent = channel.agent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !agent.isEmpty else { return nil }
            return agent
        })
        var dms: [WADChatChannel] = []
        for agent in agents.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            guard let dm = try? await self.api.agentDM(agent.lowercased()) else { continue }
            // name = nome agente: usato solo per la UI (titolo/righe), le API usano l'id.
            dms.append(WADChatChannel(
                id: dm.channel.id,
                name: agent,
                topic: dm.channel.topic,
                agent: dm.channel.agent,
                model: dm.channel.model,
                grp: dm.channel.grp,
                lastAt: nil))
        }
        self.dmChannels = dms
    }
}

private struct WADAgentDMRow: View {
    let channel: WADChatChannel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.channel.name)
                    .font(.body.weight(.semibold))
                Text("Messaggi diretti · anche via Siri")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
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

private struct WADPendingImage: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let preview: UIImage
}

private struct WADChatThreadView: View {
    let channel: WADChatChannel
    @EnvironmentObject private var state: WADChatState
    @Environment(\.scenePhase) private var scenePhase

    @State private var messages: [WADChatMessage] = []
    @State private var busy: WADChatBusy?
    @State private var draft = ""
    @State private var error: String?
    @State private var sending = false
    @State private var replyTarget: WADChatMessage?
    @State private var pollTask: Task<Void, Never>?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pendingImages: [WADPendingImage] = []
    @State private var seenMessageIds: Set<String> = []
    @State private var notifiedMessageIds: Set<String> = []
    @StateObject private var voiceRecorder = WADVoiceRecorder()

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
            WADSiriDefaults.rememberLastChannel(id: self.channel.id, name: self.channel.name)
            await self.load(initial: true)
            self.startPolling()
        }
        .onDisappear {
            self.pollTask?.cancel()
            self.pollTask = nil
            self.voiceRecorder.cancel()
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
                        WADMessageBubbleView(message: message, isMine: self.isMine(message))
                            .id(message.id)
                            .contextMenu { self.messageMenu(message) }
                    }
                    if let busy {
                        WADTypingIndicatorView(agentName: self.channel.agent ?? "Agente", status: busy.status ?? "")
                            .id("wad-typing")
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
            .onChange(of: self.busy != nil) { _, isBusy in
                if isBusy {
                    withAnimation { proxy.scrollTo("wad-typing", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageMenu(_ message: WADChatMessage) -> some View {
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
            Task { await self.setPinned(message, pinned: !message.isPinned) }
        } label: {
            Label(message.isPinned ? "Sblocca" : "Fissa", systemImage: message.isPinned ? "pin.slash" : "pin")
        }
        if !message.body.isEmpty {
            Button {
                UIPasteboard.general.string = message.body
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
            if !self.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(self.pendingImages) { image in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: image.preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Button {
                                    self.pendingImages.removeAll { $0.id == image.id }
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
                    Text("Microfono negato: abilitalo in Impostazioni → WAD")
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
        !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !self.pendingImages.isEmpty
    }

    private func isMine(_ message: WADChatMessage) -> Bool {
        guard let userId = self.state.user?.id else { return false }
        return message.userId == userId
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else { continue }
            let jpeg = image.jpegData(compressionQuality: 0.82) ?? data
            self.pendingImages.append(WADPendingImage(data: jpeg, preview: image))
        }
        self.photoItems = []
    }

    private func load(initial: Bool) async {
        do {
            let snapshot = try await self.api.messages(channelId: self.channel.id)
            if initial {
                self.seenMessageIds = Set(snapshot.messages.map(\.id))
            } else {
                await self.notifyIfNeeded(for: snapshot.messages)
                self.seenMessageIds.formUnion(snapshot.messages.map(\.id))
            }
            self.messages = snapshot.messages
            self.busy = snapshot.busy
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

    private func sendVoiceNote() async {
        guard let audio = self.voiceRecorder.stop() else { return }
        self.sending = true
        defer { self.sending = false }
        do {
            _ = try await self.api.sendVoice(
                channelId: self.channel.id,
                audio: audio,
                replyTo: self.replyTarget?.id)
            self.replyTarget = nil
            await self.load(initial: false)
            self.error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Invio vocale fallito"
        }
    }

    private func sendDraft() async {
        let body = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = self.pendingImages
        guard !body.isEmpty || !images.isEmpty else { return }
        self.sending = true
        defer { self.sending = false }
        do {
            let message = try await self.api.send(
                channelId: self.channel.id,
                body: body,
                replyTo: self.replyTarget?.id,
                withAttachments: !images.isEmpty)
            if !images.isEmpty {
                for (index, image) in images.enumerated() {
                    try await self.api.uploadAttachment(
                        messageId: message.id,
                        name: "foto-\(index + 1).jpg",
                        mime: "image/jpeg",
                        data: image.data)
                }
                try await self.api.markReady(messageId: message.id)
            }
            self.draft = ""
            self.replyTarget = nil
            self.pendingImages = []
            await self.load(initial: false)
            self.error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Invio fallito"
        }
    }

    private func react(_ message: WADChatMessage, emoji: String) async {
        do {
            try await self.api.toggleReaction(messageId: message.id, emoji: emoji)
            await self.load(initial: false)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Reazione fallita"
        }
    }

    private func setPinned(_ message: WADChatMessage, pinned: Bool) async {
        do {
            try await self.api.setPinned(messageId: message.id, pinned: pinned)
            await self.load(initial: false)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Operazione fallita"
        }
    }

    private func notifyIfNeeded(for messages: [WADChatMessage]) async {
        guard self.scenePhase != .active else { return }
        guard let myUserId = self.state.user?.id else { return }
        let newMessages = messages.filter { message in
            !self.seenMessageIds.contains(message.id)
                && !self.notifiedMessageIds.contains(message.id)
                && message.userId != myUserId
                && !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !newMessages.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
        else { return }

        for message in newMessages.suffix(3) {
            let content = UNMutableNotificationContent()
            content.title = "#\(self.channel.name) · \(message.userName)"
            content.body = String(message.body.prefix(180))
            content.sound = .default
            content.userInfo = [
                "wadChannelId": self.channel.id,
                "wadMessageId": message.id,
            ]
            let request = UNNotificationRequest(
                identifier: "wad-chat-\(message.id)",
                content: content,
                trigger: nil)
            try? await center.add(request)
            self.notifiedMessageIds.insert(message.id)
        }
    }
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
                    } else if attachment.isAudio, let url = api.attachmentURL(attachment.id) {
                        WADVoiceAttachmentView(url: url, name: attachment.name)
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
