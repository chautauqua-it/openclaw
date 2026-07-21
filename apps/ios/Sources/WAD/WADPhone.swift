import AVFoundation
@preconcurrency import linphonesw
import SwiftUI

// MARK: - Telefono SIP nativo (linphone-sdk) verso il centralino Mercurio.
// Niente WebRTC: registrazione SIP/TCP diretta con l'interno personale
// dell'utente, credenziali servite da WAD (/api/sip/config).

@MainActor
final class WADSipManager: ObservableObject {
    static let shared = WADSipManager()

    enum CallState: Equatable {
        case idle
        case ringingIn
        case ringingOut
        case inCall
    }

    @Published var configured = false
    @Published var registered = false
    @Published var callState: CallState = .idle
    @Published var remote = ""
    @Published var callStartedAt: Date?
    @Published var muted = false
    @Published var error: String?
    @Published var ext = ""

    /// CallKit: aggiornato dai cambi di stato SIP e usato per la UI di sistema.
    weak var callCenter: WADCallCenter?

    private var core: Core?
    private var coreDelegate: CoreDelegate?
    private var currentCall: Call?
    private var domain = ""
    private var starting = false

    /// Scarica le credenziali da WAD e registra l'interno. Riusabile: se le
    /// credenziali cambiano nel profilo, basta richiamarla.
    func start() async {
        guard !self.starting else { return }
        self.starting = true
        defer { self.starting = false }
        let config: WADSipConfig
        do {
            config = try await WADAPIClient.shared.sipConfig()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Config SIP non raggiungibile"
            return
        }
        guard !config.ext.isEmpty, !config.password.isEmpty else {
            self.configured = false
            self.error = "Nessun interno configurato: impostalo in WAD → Profilo → Telefono."
            return
        }
        if self.configured, self.ext == config.ext, self.registered { return }
        self.ext = config.ext
        self.domain = config.domain
        self.configured = true
        self.error = nil
        do {
            try self.setUpCore(config: config)
        } catch {
            self.error = "Telefono non inizializzabile: \(error.localizedDescription)"
            self.configured = false
        }
    }

    private func setUpCore(config: WADSipConfig) throws {
        self.tearDownCore()
        let factory = Factory.Instance
        let core = try factory.createCore(configPath: "", factoryConfigPath: "", systemContext: nil)
        core.autoIterateEnabled = true
        core.pushNotificationEnabled = false
        // CallKit possiede la sessione audio: linphone la attiva solo quando
        // CXProvider chiama didActivate (vedi WADCallCenter).
        core.callkitEnabled = true

        let delegate = CoreDelegateStub(
            onCallStateChanged: { [weak self] _, call, state, message in
                Task { @MainActor [weak self] in self?.handleCallState(call: call, state: state, message: message) }
            },
            onAccountRegistrationStateChanged: { [weak self] _, _, state, message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .Ok:
                        self.registered = true
                        self.error = nil
                    case .Failed:
                        self.registered = false
                        self.error = "Registrazione fallita: \(message)"
                    case .Cleared, .None:
                        self.registered = false
                    default:
                        break
                    }
                }
            })
        core.addDelegate(delegate: delegate)
        try core.start()

        let params = try core.createAccountParams()
        let identity = try factory.createAddress(addr: "sip:\(config.ext)@\(config.domain)")
        try params.setIdentityaddress(newValue: identity)
        // Mercurio espone SIP su TCP 5060 (il TLS 5061 è chiuso): transport esplicito.
        let server = try factory.createAddress(addr: "sip:\(config.domain);transport=tcp")
        try params.setServeraddress(newValue: server)
        params.registerEnabled = true
        let account = try core.createAccount(params: params)
        let auth = try factory.createAuthInfo(
            username: config.ext, userid: "", passwd: config.password,
            ha1: "", realm: "", domain: config.domain)
        core.addAuthInfo(info: auth)
        try core.addAccount(account: account)
        core.defaultAccount = account
        self.core = core
        self.coreDelegate = delegate
    }

    private func tearDownCore() {
        if let core = self.core {
            if let delegate = self.coreDelegate { core.removeDelegate(delegate: delegate) }
            core.stop()
        }
        self.core = nil
        self.coreDelegate = nil
        self.currentCall = nil
        self.registered = false
        self.callState = .idle
        self.callStartedAt = nil
        self.muted = false
    }

    private func handleCallState(call: Call, state: Call.State, message: String) {
        switch state {
        case .IncomingReceived, .PushIncomingReceived:
            guard self.currentCall == nil else {
                try? call.decline(reason: .Busy)
                return
            }
            self.currentCall = call
            let display = call.remoteAddress?.displayName ?? ""
            self.remote = display.isEmpty ? (call.remoteAddress?.username ?? "sconosciuto") : display
            self.callState = .ringingIn
            self.callCenter?.sipReportedIncoming(from: self.remote)
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging:
            self.callState = .ringingOut
        case .Connected, .StreamsRunning:
            if self.callState != .inCall {
                self.callState = .inCall
                self.callStartedAt = Date()
                self.callCenter?.sipCallConnected()
            }
        case .End, .Released:
            self.finishCall()
            self.callCenter?.sipCallEnded()
        case .Error:
            self.finishCall()
            self.callCenter?.sipCallEnded()
            self.error = "Chiamata fallita: \(message)"
        default:
            break
        }
    }

    private func finishCall() {
        self.currentCall = nil
        self.callState = .idle
        self.remote = ""
        self.callStartedAt = nil
        self.muted = false
    }

    func call(_ number: String) {
        let num = number.filter { !$0.isWhitespace }
        guard let core = self.core, self.registered, !num.isEmpty, self.currentCall == nil else { return }
        self.error = nil
        do {
            let address = try Factory.Instance.createAddress(addr: "sip:\(num)@\(self.domain)")
            let params = try core.createCallParams(call: nil)
            self.currentCall = core.inviteAddressWithParams(addr: address, params: params)
            self.remote = num
            self.callState = .ringingOut
        } catch {
            self.error = "Chiamata non avviabile: \(error.localizedDescription)"
            self.finishCall()
        }
    }

    func answer() {
        guard let call = self.currentCall, self.callState == .ringingIn else { return }
        try? call.accept()
    }

    func hangup() {
        guard let call = self.currentCall else { return }
        if self.callState == .ringingIn {
            try? call.decline(reason: .Declined)
        } else {
            try? call.terminate()
        }
        self.finishCall()
    }

    func toggleMute() {
        guard let core = self.core, self.callState == .inCall else { return }
        core.micEnabled = !core.micEnabled
        self.muted = !core.micEnabled
    }

    func setMuted(_ muted: Bool) {
        guard let core = self.core else { return }
        core.micEnabled = !muted
        self.muted = muted
    }

    /// Push VoIP ricevuto: assicura il core avviato e recupera l'INVITE pendente.
    func wakeForPush(callId: String?) async {
        if self.core == nil { await self.start() }
        self.core?.processPushNotification(callId: callId)
    }

    /// Attiva/disattiva la sessione audio linphone su richiesta di CallKit.
    func activateAudioSession(_ activated: Bool) {
        self.core?.activateAudioSession(activated: activated)
    }

    func sendDTMF(_ digit: String) {
        guard let call = self.currentCall, self.callState == .inCall,
              let scalar = digit.unicodeScalars.first else { return }
        try? call.sendDtmf(dtmf: CChar(scalar.value))
    }
}

// MARK: - UI telefono

struct WADPhoneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var phone = WADSipManager.shared
    @State private var number = ""
    @State private var now = Date()
    @State private var idleTab: IdleTab = .dialer
    @State private var contacts: [WADSipContact] = []
    @State private var contactsLoaded = false

    private enum IdleTab: Hashable {
        case dialer
        case directory
    }

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
    private static let avatarColors: [Color] = [
        Color(red: 0.49, green: 0.43, blue: 0.95), Color(red: 0.07, green: 0.63, blue: 0.48),
        Color(red: 0.90, green: 0.54, blue: 0.18), Color(red: 0.23, green: 0.51, blue: 0.84),
        Color(red: 0.84, green: 0.36, blue: 0.69), Color(red: 0.35, green: 0.65, blue: 0.65),
        Color(red: 0.75, green: 0.34, blue: 0.31), Color(red: 0.54, green: 0.56, blue: 0.24),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                self.statusHeader
                if let error = self.phone.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                switch self.phone.callState {
                case .ringingIn:
                    self.incomingView
                case .ringingOut, .inCall:
                    self.activeCallView
                case .idle:
                    self.idleView
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 18)
            .navigationTitle("Telefono")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { self.dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Chiudi telefono")
                }
            }
            .task {
                await AVAudioApplication.requestRecordPermission()
                await self.phone.start()
            }
            .onReceive(self.timer) { self.now = $0 }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(self.phone.registered ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            Text(self.phone.registered
                ? "Interno \(self.phone.ext) registrato"
                : (self.phone.configured ? "Registrazione in corso..." : "Telefono non configurato"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var incomingView: some View {
        VStack(spacing: 14) {
            Text("📞 \(self.phone.remote)")
                .font(.title2.bold())
            Text("Chiamata in arrivo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button { self.phone.answer() } label: {
                    Label("Rispondi", systemImage: "phone.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                Button { self.phone.hangup() } label: {
                    Label("Rifiuta", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 30)
    }

    private var activeCallView: some View {
        VStack(spacing: 14) {
            Text(self.phone.remote)
                .font(.title2.bold())
            Text(self.phone.callState == .ringingOut ? "Sto chiamando..." : self.elapsed)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if self.phone.callState == .inCall {
                self.keypad { self.phone.sendDTMF($0) }
                    .padding(.horizontal, 46)
            }
            HStack(spacing: 16) {
                if self.phone.callState == .inCall {
                    Button { self.phone.toggleMute() } label: {
                        Label(self.phone.muted ? "Riattiva" : "Muta",
                              systemImage: self.phone.muted ? "mic.slash.fill" : "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button { self.phone.hangup() } label: {
                    Label("Chiudi", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 20)
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Picker("Vista", selection: self.$idleTab) {
                Text("Tastierino").tag(IdleTab.dialer)
                Text("Rubrica").tag(IdleTab.directory)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)
            if self.idleTab == .dialer {
                self.dialerView
            } else {
                self.directoryView
            }
        }
        .task { await self.loadContacts() }
    }

    private var directoryView: some View {
        Group {
            if self.contacts.isEmpty {
                Text(self.contactsLoaded ? "Rubrica non disponibile" : "Carico la rubrica...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 26)
            } else {
                List(self.contacts) { contact in
                    Button {
                        WADCallCenter.shared.reportOutgoing(to: contact.ext)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Self.avatarColor(for: contact.name))
                                Text(Self.initials(of: contact.name))
                                    .font(.caption.weight(.heavy))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(contact.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("interno \(contact.ext)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "phone.fill")
                                .font(.footnote)
                                .foregroundStyle(self.phone.registered ? Color.green : Color.secondary)
                        }
                    }
                    .disabled(!self.phone.registered)
                }
                .listStyle(.plain)
            }
        }
    }

    private func loadContacts() async {
        guard !self.contactsLoaded else { return }
        do {
            self.contacts = try await WADAPIClient.shared.sipDirectory()
        } catch {
            self.contacts = []
        }
        self.contactsLoaded = true
    }

    private static func initials(of name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(parts).uppercased()
    }

    private static func avatarColor(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return self.avatarColors[sum % self.avatarColors.count]
    }

    private var dialerView: some View {
        VStack(spacing: 16) {
            Text(self.number.isEmpty ? "Numero o interno" : self.number)
                .font(.title.monospacedDigit().weight(.semibold))
                .foregroundStyle(self.number.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 30)
            self.keypad { self.number += $0 }
                .padding(.horizontal, 40)
            HStack(spacing: 16) {
                Button {
                    self.number = String(self.number.dropLast())
                } label: {
                    Image(systemName: "delete.left")
                        .frame(width: 54, height: 54)
                }
                .buttonStyle(.bordered)
                .disabled(self.number.isEmpty)
                Button {
                    WADCallCenter.shared.reportOutgoing(to: self.number)
                    self.number = ""
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!self.phone.registered || self.number.isEmpty)
            }
            .padding(.horizontal, 40)
        }
    }

    private func keypad(action: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(Self.keys, id: \.self) { key in
                Button { action(key) } label: {
                    Text(key)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var elapsed: String {
        guard let start = self.phone.callStartedAt else { return "00:00" }
        let seconds = max(0, Int(self.now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
