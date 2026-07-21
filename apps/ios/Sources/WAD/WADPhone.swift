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
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging:
            self.callState = .ringingOut
        case .Connected, .StreamsRunning:
            if self.callState != .inCall {
                self.callState = .inCall
                self.callStartedAt = Date()
            }
        case .End, .Released:
            self.finishCall()
        case .Error:
            self.finishCall()
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

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

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
                    self.dialerView
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
                    self.phone.call(self.number)
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
