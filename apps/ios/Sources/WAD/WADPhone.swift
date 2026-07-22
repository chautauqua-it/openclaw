import AVFoundation
import Contacts
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

    enum ConsultState: Equatable {
        case none
        case ringing
        case connected
    }

    @Published var configured = false
    @Published var registered = false
    @Published var callState: CallState = .idle
    @Published var remote = ""
    @Published var callStartedAt: Date?
    @Published var muted = false
    @Published var error: String?
    @Published var ext = ""
    @Published var consultState: ConsultState = .none
    @Published var consultRemote = ""

    /// CallKit: aggiornato dai cambi di stato SIP e usato per la UI di sistema.
    weak var callCenter: WADCallCenter?

    private var core: Core?
    private var coreDelegate: CoreDelegate?
    private var currentCall: Call?
    private var domain = ""
    private var pickupCode = ""
    private var starting = false
    private var audioSessionActive = false
    private var audioSessionForced = false
    private var consultCall: Call?

    /// Scarica le credenziali da WAD e registra l'interno. Riusabile: se le
    /// credenziali cambiano nel profilo, basta richiamarla.
    func start() async {
        if self.starting {
            WADDeviceLog.shared.log("sip.perf", "start richiesto mentre già in corso: attendo")
            await self.waitForStartToFinish()
            return
        }
        let startedAt = Date()
        WADDeviceLog.shared.log("sip.perf", "start begin")
        self.starting = true
        defer {
            self.starting = false
            let elapsed = Date().timeIntervalSince(startedAt)
            WADDeviceLog.shared.log("sip.perf", String(format: "start end %.2fs registered=%@", elapsed, self.registered ? "true" : "false"))
        }
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
        self.pickupCode = config.pickupCode ?? ""
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
        let startedAt = Date()
        WADDeviceLog.shared.log("sip.perf", "setUpCore begin")
        self.tearDownCore()
        let factory = Factory.Instance
        WADDeviceLog.shared.log("sip.perf", "createCore begin")
        let core = try factory.createCore(configPath: "", factoryConfigPath: "", systemContext: nil)
        WADDeviceLog.shared.log("sip.perf", String(format: "createCore end %.2fs", Date().timeIntervalSince(startedAt)))
        core.autoIterateEnabled = true
        core.pushNotificationEnabled = false
        // CallKit possiede la sessione audio: linphone la attiva solo quando
        // CXProvider chiama didActivate (vedi WADCallCenter).
        core.callkitEnabled = true
        // Su rete cellulare i CDR mostravano pacchetti uplink ogni ~40ms con burst
        // di jitter (audio "a tratti" per chi ascolta): forza ptime 20ms e rate
        // control adattivo.
        core.uploadPtime = 20
        core.adaptiveRateControlEnabled = true

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
                        WADDeviceLog.shared.log("sip", "registrato interno \(self.ext)")
                    case .Failed:
                        self.registered = false
                        self.error = "Registrazione fallita: \(message)"
                        WADDeviceLog.shared.log("sip.error", "registrazione fallita \(self.ext): \(message)")
                    case .Cleared, .None:
                        self.registered = false
                    default:
                        break
                    }
                }
            })
        core.addDelegate(delegate: delegate)
        WADDeviceLog.shared.log("sip.perf", "core.start begin")
        try core.start()
        WADDeviceLog.shared.log("sip.perf", String(format: "core.start end %.2fs", Date().timeIntervalSince(startedAt)))

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
        WADDeviceLog.shared.log("sip.perf", String(format: "setUpCore end %.2fs", Date().timeIntervalSince(startedAt)))
    }

    private func waitForStartToFinish(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while self.starting, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if self.starting {
            WADDeviceLog.shared.log("sip.perf", "start ancora in corso dopo \(Int(timeout))s")
        }
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
        if call === self.consultCall {
            self.handleConsultState(state: state, message: message)
            return
        }
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
            WADDeviceLog.shared.log("sip.callkit", "INVITE ricevuto stato=\(state) remote=\(self.remote)")
            self.callCenter?.sipReportedIncoming(from: self.remote)
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging:
            self.callState = .ringingOut
        case .Connected, .StreamsRunning:
            if self.callState != .inCall {
                self.callState = .inCall
                self.callStartedAt = Date()
                WADDeviceLog.shared.log("sip.callkit", "chiamata connessa")
                self.callCenter?.sipCallConnected()
                self.scheduleAudioSessionSafetyNet()
            }
        case .End, .Released:
            WADDeviceLog.shared.log("sip.callkit", "chiamata terminata stato=\(state)")
            if let consult = self.consultCall {
                try? consult.terminate()
                self.consultCall = nil
                self.consultState = .none
                self.consultRemote = ""
            }
            if self.audioSessionForced {
                // L'attivazione l'abbiamo forzata noi, quindi CallKit non manderà
                // il didDeactivate: chiudiamo noi la sessione audio.
                self.core?.activateAudioSession(activated: false)
                self.audioSessionForced = false
                self.audioSessionActive = false
            }
            self.finishCall()
            self.callCenter?.sipCallEnded()
        case .Error:
            self.finishCall()
            self.callCenter?.sipCallEnded()
            self.error = "Chiamata fallita: \(message)"
            WADDeviceLog.shared.log("sip.error", "chiamata fallita: \(message)")
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

    /// Risposta da CallKit. Se il push ha svegliato l'app ma Mercurio non ha
    /// ancora consegnato l'INVITE al core, prova il pickup dell'interno.
    @discardableResult
    func answerFromCallKit() -> Bool {
        if let call = self.currentCall, self.callState == .ringingIn {
            WADDeviceLog.shared.log("sip.callkit", "answer: accetto currentCall")
            try? call.accept()
            return true
        }
        let code = self.pickupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            WADDeviceLog.shared.log("sip.callkit", "answer: nessuna currentCall e pickup assente")
            return false
        }
        WADDeviceLog.shared.log("sip.callkit", "answer: fallback pickup \(code)")
        self.call(code)
        return true
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
        WADDeviceLog.shared.log("sip.callkit", "wakeForPush callId=\(callId ?? "-")")
        if self.core == nil { await self.start() }
        guard let core = self.core else {
            WADDeviceLog.shared.log("sip.error", "wakeForPush senza core pronto")
            return
        }
        core.processPushNotification(callId: callId)
    }

    /// Avvia il core se serve e attende la registrazione SIP: per le chiamate
    /// partite da CarPlay ad app fredda, dove il telefono WAD non è mai stato aperto.
    func ensureRegistered(timeout: TimeInterval = 8) async -> Bool {
        if self.core == nil { await self.start() }
        let deadline = Date().addingTimeInterval(timeout)
        while !self.registered, Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if !self.registered {
            WADDeviceLog.shared.log("sip.error", "ensureRegistered timeout ext=\(self.ext)")
        }
        return self.registered
    }

    /// Prepara la AVAudioSession per linphone: da chiamare nei handler CallKit
    /// prima di accept/invite (requisito linphone con callkitEnabled).
    func configureAudioSession() {
        self.core?.configureAudioSession()
    }

    /// Caso Laura 2026-07-21: cold-launch da push + pickup **201, CallKit non ha
    /// mai chiamato didActivate → audio unit mai partita, chiamata muta nei due
    /// sensi. Se entro 1.5s dalla connessione l'audio non è attivo, lo forziamo.
    private func scheduleAudioSessionSafetyNet() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.callState == .inCall, !self.audioSessionActive else { return }
            WADDeviceLog.shared.log("sip.callkit", "audio activate mancante, forzo attivazione")
            self.audioSessionForced = true
            self.audioSessionActive = true
            self.core?.activateAudioSession(activated: true)
        }
    }

    /// Attiva/disattiva la sessione audio linphone su richiesta di CallKit.
    func activateAudioSession(_ activated: Bool) {
        self.audioSessionActive = activated
        if activated { self.audioSessionForced = false }
        self.core?.activateAudioSession(activated: activated)
    }

    func sendDTMF(_ digit: String) {
        guard let call = self.currentCall, self.callState == .inCall,
              let scalar = digit.unicodeScalars.first else { return }
        try? call.sendDtmf(dtmf: CChar(scalar.value))
    }

    /// Trasferimento cieco: REFER verso il numero/interno indicato.
    func transfer(to number: String) {
        let num = number.filter { !$0.isWhitespace }
        guard let call = self.currentCall, self.callState == .inCall, !num.isEmpty else { return }
        do {
            let address = try Factory.Instance.createAddress(addr: "sip:\(num)@\(self.domain)")
            try call.transferTo(referTo: address)
            WADDeviceLog.shared.log("sip", "trasferimento verso \(num) inviato")
        } catch {
            self.error = "Trasferimento non riuscito: \(error.localizedDescription)"
            WADDeviceLog.shared.log("sip.error", "trasferimento verso \(num) fallito: \(error.localizedDescription)")
        }
    }

    // MARK: Trasferimento assistito

    /// Mette in attesa la chiamata principale e apre una consultazione verso
    /// il destinatario del trasferimento.
    func startAttendedTransfer(to number: String) {
        let num = number.filter { !$0.isWhitespace }
        guard let core = self.core, let call = self.currentCall, self.callState == .inCall,
              !num.isEmpty, self.consultCall == nil else { return }
        self.error = nil
        do {
            try call.pause()
            let address = try Factory.Instance.createAddress(addr: "sip:\(num)@\(self.domain)")
            let params = try core.createCallParams(call: nil)
            self.consultCall = core.inviteAddressWithParams(addr: address, params: params)
            self.consultRemote = num
            self.consultState = .ringing
            WADDeviceLog.shared.log("sip", "trasferimento assistito: consulto \(num)")
        } catch {
            self.error = "Consultazione non avviabile: \(error.localizedDescription)"
            self.consultCall = nil
            self.consultState = .none
            self.consultRemote = ""
            try? call.resume()
        }
    }

    /// Congiunge le due gambe: la chiamata principale (in attesa) viene
    /// trasferita al destinatario della consultazione.
    func completeAttendedTransfer() {
        guard let main = self.currentCall, let consult = self.consultCall else { return }
        do {
            try main.transferToAnother(dest: consult)
            WADDeviceLog.shared.log("sip", "trasferimento assistito completato verso \(self.consultRemote)")
        } catch {
            self.error = "Trasferimento non riuscito: \(error.localizedDescription)"
            WADDeviceLog.shared.log("sip.error", "trasferimento assistito fallito: \(error.localizedDescription)")
        }
    }

    /// Annulla la consultazione e riprende la chiamata principale.
    func cancelAttendedTransfer() {
        guard let consult = self.consultCall else { return }
        try? consult.terminate()
        // il resume della principale avviene alla chiusura della consult
    }

    private func handleConsultState(state: Call.State, message: String) {
        switch state {
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging:
            self.consultState = .ringing
        case .Connected, .StreamsRunning:
            self.consultState = .connected
        case .End, .Released, .Error:
            let failed = (state == .Error)
            self.consultCall = nil
            self.consultState = .none
            self.consultRemote = ""
            if failed { self.error = "Consultazione fallita: \(message)" }
            // Se la principale è ancora viva (annullo o destinatario non
            // raggiungibile) la riprendiamo; se il trasferimento è andato a
            // buon fine sta terminando e il resume fallisce senza danni.
            if let main = self.currentCall { try? main.resume() }
        default:
            break
        }
    }
}

// MARK: - UI telefono

struct WADPhoneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var phone = WADSipManager.shared
    @ObservedObject private var book = WADPhoneBook.shared
    @State private var number = ""
    @State private var now = Date()
    @State private var idleTab: IdleTab = .dialer
    @State private var rubricaFilter = ""
    @State private var interniFilter = ""
    @State private var dialerSearch = ""
    @State private var transferMode = false
    @State private var transferNumber = ""

    private enum IdleTab: Hashable {
        case dialer
        case interni
        case rubrica
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
            .onChange(of: self.phone.callState) { _, state in
                if state != .inCall {
                    self.transferMode = false
                    self.transferNumber = ""
                }
            }
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
            Text(self.phone.callState == .ringingOut ? "Sto chiamando..."
                : self.phone.consultState != .none ? "In attesa" : self.elapsed)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if self.phone.callState == .inCall {
                if self.phone.consultState != .none {
                    self.consultView
                } else if self.transferMode {
                    self.transferView
                } else {
                    self.keypad { self.phone.sendDTMF($0) }
                        .padding(.horizontal, 46)
                }
            }
            if !((self.transferMode || self.phone.consultState != .none) && self.phone.callState == .inCall) {
                HStack(spacing: 12) {
                    if self.phone.callState == .inCall {
                        Button { self.phone.toggleMute() } label: {
                            Label(self.phone.muted ? "Riattiva" : "Muta",
                                  systemImage: self.phone.muted ? "mic.slash.fill" : "mic.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button { self.transferMode = true } label: {
                            Label("Trasf.", systemImage: "arrow.uturn.forward")
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
        }
        .padding(.top, 20)
    }

    private var transferView: some View {
        VStack(spacing: 10) {
            Text("Trasferisci la chiamata")
                .font(.subheadline.weight(.semibold))
            TextField("Nome o numero", text: self.$transferNumber)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .padding(.horizontal, 40)
            if !self.book.interni.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(self.matchInterni(self.transferNumber)) { contact in
                            Button { self.transferNumber = contact.ext } label: {
                                HStack {
                                    Text(contact.name)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(contact.ext)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                            }
                            .buttonStyle(.bordered)
                            .tint(self.transferNumber == contact.ext ? Color.accentColor : Color.secondary)
                        }
                    }
                    .padding(.horizontal, 40)
                }
                .frame(maxHeight: 190)
            }
            HStack(spacing: 12) {
                Button("Annulla") {
                    self.transferMode = false
                    self.transferNumber = ""
                }
                .buttonStyle(.bordered)
                Button("Diretto") { self.doTransfer(self.transferNumber) }
                    .buttonStyle(.bordered)
                    .disabled(WADPhoneBook.dialable(self.transferNumber).isEmpty)
                Button("Assistito") { self.doAttendedTransfer(self.transferNumber) }
                    .buttonStyle(.borderedProminent)
                    .disabled(WADPhoneBook.dialable(self.transferNumber).isEmpty)
            }
        }
        .task { await self.book.loadInterni() }
    }

    /// Consultazione in corso durante un trasferimento assistito.
    private var consultView: some View {
        VStack(spacing: 12) {
            Text("Consulto \(self.phone.consultRemote)")
                .font(.subheadline.weight(.semibold))
            Text(self.phone.consultState == .connected ? "In linea con il destinatario" : "Squilla...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Riprendi") { self.phone.cancelAttendedTransfer() }
                    .buttonStyle(.bordered)
                Button("Completa") { self.phone.completeAttendedTransfer() }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.phone.consultState != .connected)
            }
        }
        .padding(.top, 12)
    }

    private func doTransfer(_ target: String) {
        self.phone.transfer(to: target)
        self.transferMode = false
        self.transferNumber = ""
    }

    private func doAttendedTransfer(_ target: String) {
        self.phone.startAttendedTransfer(to: target)
        self.transferMode = false
        self.transferNumber = ""
    }

    private var idleView: some View {
        VStack(spacing: 14) {
            if !self.book.favorites.isEmpty {
                self.favoritesRow
            }
            Picker("Vista", selection: self.$idleTab) {
                Text("Tastierino").tag(IdleTab.dialer)
                Text("Interni").tag(IdleTab.interni)
                Text("Rubrica").tag(IdleTab.rubrica)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            switch self.idleTab {
            case .dialer:
                self.dialerView
            case .interni:
                self.interniView
            case .rubrica:
                self.rubricaView
            }
        }
        .task { await self.book.loadAll() }
        .onChange(of: self.idleTab) { _, tab in
            if tab == .rubrica {
                Task { await self.book.loadDeviceContacts() }
            }
        }
    }

    /// Preferiti in scorrimento orizzontale, stile tavolette del telefono Mac:
    /// tap = chiama, pressione lunga = rimuovi.
    private var favoritesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(self.book.favorites) { favorite in
                    Button {
                        WADCallCenter.shared.reportOutgoing(to: WADPhoneBook.dialable(favorite.number))
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle()
                                    .fill(Self.avatarColor(for: favorite.name))
                                Text(Self.initials(of: favorite.name))
                                    .font(.subheadline.weight(.heavy))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 52, height: 52)
                            Text(favorite.name)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .frame(width: 66)
                    }
                    .buttonStyle(.plain)
                    .disabled(!self.phone.registered)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await self.book.removeFavorite(number: favorite.number) }
                        } label: {
                            Label("Rimuovi dai preferiti", systemImage: "star.slash")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var interniView: some View {
        Group {
            if self.book.interni.isEmpty {
                Text("Carico gli interni...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 26)
            } else {
                VStack(spacing: 8) {
                    TextField("Cerca per nome o numero", text: self.$interniFilter)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 20)
                    List(self.matchInterni(self.interniFilter)) { contact in
                        Button {
                            WADCallCenter.shared.reportOutgoing(to: contact.ext)
                        } label: {
                            self.contactRow(
                                name: contact.name,
                                subtitle: "interno \(contact.ext)",
                                number: contact.ext)
                        }
                        .disabled(!self.phone.registered)
                        .contextMenu {
                            self.favoriteToggle(name: contact.name, number: contact.ext, kind: "interno")
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    /// Filtro condiviso sugli interni: combacia sia il nome sia l'interno.
    private func matchInterni(_ query: String) -> [WADSipContact] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return self.book.interni }
        return self.book.interni.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.ext.localizedCaseInsensitiveContains(q)
        }
    }

    /// Rubrica del telefono (contatti iOS). Un contatto con più numeri mostra
    /// il menu di scelta al tap.
    private var rubricaView: some View {
        Group {
            if self.book.contactsDenied {
                VStack(spacing: 8) {
                    Text("Accesso alla rubrica negato")
                        .font(.subheadline.weight(.semibold))
                    Text("Autorizza i contatti in Impostazioni > OpenClaw.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 26)
            } else if self.book.deviceContacts.isEmpty {
                Text("Carico la rubrica...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 26)
            } else {
                VStack(spacing: 8) {
                    TextField("Cerca in rubrica", text: self.$rubricaFilter)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 20)
                    List(self.filteredDeviceContacts) { contact in
                        if contact.numbers.count == 1, let only = contact.numbers.first {
                            Button {
                                WADCallCenter.shared.reportOutgoing(to: WADPhoneBook.dialable(only.value))
                            } label: {
                                self.contactRow(
                                    name: contact.name,
                                    subtitle: only.value,
                                    number: WADPhoneBook.dialable(only.value))
                            }
                            .disabled(!self.phone.registered)
                            .contextMenu {
                                self.favoriteToggle(
                                    name: contact.name,
                                    number: WADPhoneBook.dialable(only.value),
                                    kind: "rubrica")
                            }
                        } else {
                            Menu {
                                ForEach(contact.numbers) { entry in
                                    Button {
                                        WADCallCenter.shared.reportOutgoing(to: WADPhoneBook.dialable(entry.value))
                                    } label: {
                                        Label("\(entry.label) \(entry.value)", systemImage: "phone.fill")
                                    }
                                    self.favoriteToggle(
                                        name: contact.name,
                                        number: WADPhoneBook.dialable(entry.value),
                                        kind: "rubrica")
                                }
                            } label: {
                                self.contactRow(
                                    name: contact.name,
                                    subtitle: "\(contact.numbers.count) numeri",
                                    number: nil)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    private var filteredDeviceContacts: [WADPhoneBook.DeviceContact] {
        let query = self.rubricaFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self.book.deviceContacts }
        return self.book.deviceContacts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.numbers.contains { $0.value.localizedCaseInsensitiveContains(query) }
        }
    }

    private func contactRow(name: String, subtitle: String, number: String?) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Self.avatarColor(for: name))
                Text(Self.initials(of: name))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let number, self.book.isFavorite(number: number) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            Image(systemName: "phone.fill")
                .font(.footnote)
                .foregroundStyle(self.phone.registered ? Color.green : Color.secondary)
        }
    }

    @ViewBuilder
    private func favoriteToggle(name: String, number: String, kind: String) -> some View {
        if self.book.isFavorite(number: number) {
            Button(role: .destructive) {
                Task { await self.book.removeFavorite(number: number) }
            } label: {
                Label("Rimuovi dai preferiti", systemImage: "star.slash")
            }
        } else {
            Button {
                Task { await self.book.addFavorite(name: name, number: number, kind: kind) }
            } label: {
                Label("Aggiungi ai preferiti", systemImage: "star")
            }
        }
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
        VStack(spacing: 12) {
            TextField("Cerca interno per nome", text: self.$dialerSearch)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .padding(.horizontal, 40)
            if self.dialerSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                self.dialerKeypad
            } else {
                self.dialerSuggestions
            }
        }
    }

    /// Suggerimenti interni quando si cerca per nome nel tastierino.
    private var dialerSuggestions: some View {
        let matches = self.matchInterni(self.dialerSearch)
        return Group {
            if matches.isEmpty {
                Text("Nessun interno trovato")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            } else {
                List(matches) { contact in
                    Button {
                        WADCallCenter.shared.reportOutgoing(to: contact.ext)
                        self.dialerSearch = ""
                    } label: {
                        self.contactRow(
                            name: contact.name,
                            subtitle: "interno \(contact.ext)",
                            number: contact.ext)
                    }
                    .disabled(!self.phone.registered)
                    .contextMenu {
                        self.favoriteToggle(name: contact.name, number: contact.ext, kind: "interno")
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var dialerKeypad: some View {
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
