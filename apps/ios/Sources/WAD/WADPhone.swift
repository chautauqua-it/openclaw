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

    nonisolated enum CallState: Equatable {
        case idle
        case ringingIn
        case ringingOut
        case inCall
    }

    nonisolated enum ConsultState: Equatable {
        case none
        case ringing
        case connected
    }

    nonisolated enum ConfState: Equatable {
        case none
        case ringing
        case active
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
    @Published var confState: ConfState = .none
    @Published var confRemote = ""
    /// Non disturbare CENTRALIZZATO: lo stato vive sul PBX Mercurio (il server
    /// WAD compone *78/*79), identico per web, mobile e telefoni SIP fisici.
    /// UserDefaults è solo l'ultimo stato noto (per il rifiuto locale offline).
    @Published var dnd = UserDefaults.standard.bool(forKey: "wad_sip_dnd")
    @Published var dndBusy = false

    /// CallKit: aggiornato dai cambi di stato SIP e usato per la UI di sistema.
    weak var callCenter: WADCallCenter?

    // MARK: Stato confinato sulla coda SIP
    // Il core linphone vive su `sipQueue` (seriale): iterate, registrazioni,
    // DNS e messaggistica SIP non passano MAI dal main thread — erano loro i
    // micro-hang della UI segnalati dal watchdog nella b55 (autoIterate girava
    // sul main run loop). Le proprietà `nonisolated(unsafe)` sono sicure per
    // convenzione: si leggono/scrivono SOLO dentro sipQueue.
    nonisolated private let sipQueue = DispatchQueue(label: "wad.sip.core", qos: .userInitiated)
    nonisolated(unsafe) private var core: Core?
    nonisolated(unsafe) private var coreDelegate: CoreDelegate?
    nonisolated(unsafe) private var currentCall: Call?
    nonisolated(unsafe) private var consultCall: Call?
    nonisolated(unsafe) private var confCall: Call?
    nonisolated(unsafe) private var qConfRemote = ""
    nonisolated(unsafe) private var qConfMerged = false
    nonisolated(unsafe) private var iterateTimer: DispatchSourceTimer?
    nonisolated(unsafe) private var qCallState: CallState = .idle
    nonisolated(unsafe) private var qRegistered = false
    nonisolated(unsafe) private var qDomain = ""
    nonisolated(unsafe) private var qPickupCode = ""
    nonisolated(unsafe) private var qConsultRemote = ""
    nonisolated(unsafe) private var audioSessionActive = false
    nonisolated(unsafe) private var audioSessionForced = false

    /// Specchio MainActor di "core creato e avviato" (il core vero è sulla coda).
    private var coreReady = false
    private var starting = false

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
        Task { await self.refreshDnd() }
        if self.configured, self.ext == config.ext, self.registered { return }
        self.ext = config.ext
        self.configured = true
        self.error = nil
        do {
            try await self.setUpCore(config: config)
            self.coreReady = true
        } catch {
            self.error = "Telefono non inizializzabile: \(error.localizedDescription)"
            self.configured = false
            self.coreReady = false
        }
    }

    /// Esegue il setup del core sulla coda SIP: createCore/start possono
    /// impiegare secondi (rete, DNS) e non devono bloccare il main thread.
    private func setUpCore(config: WADSipConfig) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.sipQueue.async {
                do {
                    try self.setUpCoreOnQueue(config: config)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private func setUpCoreOnQueue(config: WADSipConfig) throws {
        let startedAt = Date()
        WADDeviceLog.shared.log("sip.perf", "setUpCore begin")
        self.tearDownCoreOnQueue()
        let factory = Factory.Instance
        WADDeviceLog.shared.log("sip.perf", "createCore begin")
        let core = try factory.createCore(configPath: "", factoryConfigPath: "", systemContext: nil)
        WADDeviceLog.shared.log("sip.perf", String(format: "createCore end %.2fs", Date().timeIntervalSince(startedAt)))
        // Iterate manuale sulla coda SIP (vedi startIterateOnQueue): con
        // autoIterate il core si aggancia al main run loop e ogni iterate
        // pesante congela la UI.
        core.autoIterateEnabled = false
        core.pushNotificationEnabled = false
        // CallKit possiede la sessione audio: linphone la attiva solo quando
        // CXProvider chiama didActivate (vedi WADCallCenter).
        core.callkitEnabled = true
        // Su rete cellulare i CDR mostravano pacchetti uplink ogni ~40ms con burst
        // di jitter (audio "a tratti" per chi ascolta): forza ptime 20ms e rate
        // control adattivo.
        core.uploadPtime = 20
        core.adaptiveRateControlEnabled = true

        let ext = config.ext
        // I callback del delegate arrivano dentro core.iterate(), quindi già
        // sulla coda SIP: le azioni linphone restano inline, la UI fa hop.
        let delegate = CoreDelegateStub(
            onCallStateChanged: { [weak self] _, call, state, message in
                self?.handleCallStateOnQueue(call: call, state: state, message: message)
            },
            onAccountRegistrationStateChanged: { [weak self] _, _, state, message in
                guard let self else { return }
                switch state {
                case .Ok:
                    self.qRegistered = true
                    WADDeviceLog.shared.log("sip", "registrato interno \(ext)")
                    Task { @MainActor in
                        self.registered = true
                        self.error = nil
                    }
                case .Failed:
                    self.qRegistered = false
                    WADDeviceLog.shared.log("sip.error", "registrazione fallita \(ext): \(message)")
                    Task { @MainActor in
                        self.registered = false
                        self.error = "Registrazione fallita: \(message)"
                    }
                case .Cleared, .None:
                    self.qRegistered = false
                    Task { @MainActor in self.registered = false }
                default:
                    break
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
        self.qDomain = config.domain
        self.qPickupCode = config.pickupCode ?? ""
        self.startIterateOnQueue()
        WADDeviceLog.shared.log("sip.perf", String(format: "setUpCore end %.2fs", Date().timeIntervalSince(startedAt)))
    }

    /// Pompa linphone: iterate ogni 20ms sulla coda SIP (raccomandazione SDK
    /// per l'audio in chiamata; a riposo il lavoro per tick è trascurabile).
    nonisolated private func startIterateOnQueue() {
        self.iterateTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: self.sipQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.core?.iterate()
        }
        timer.resume()
        self.iterateTimer = timer
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

    nonisolated private func tearDownCoreOnQueue() {
        self.iterateTimer?.cancel()
        self.iterateTimer = nil
        if let core = self.core {
            if let delegate = self.coreDelegate { core.removeDelegate(delegate: delegate) }
            core.stop()
        }
        self.core = nil
        self.coreDelegate = nil
        self.currentCall = nil
        self.consultCall = nil
        self.confCall = nil
        self.qCallState = .idle
        self.qRegistered = false
        self.qConsultRemote = ""
        self.qConfRemote = ""
        self.qConfMerged = false
        self.audioSessionActive = false
        self.audioSessionForced = false
        Task { @MainActor in
            self.registered = false
            self.consultState = .none
            self.consultRemote = ""
            self.confState = .none
            self.confRemote = ""
            self.finishCallPublished()
        }
    }

    nonisolated private func handleCallStateOnQueue(call: Call, state: Call.State, message: String) {
        if call === self.consultCall {
            self.handleConsultStateOnQueue(state: state, message: message)
            return
        }
        if call === self.confCall {
            self.handleConfStateOnQueue(state: state, message: message)
            return
        }
        switch state {
        case .IncomingReceived, .PushIncomingReceived:
            // Specchio thread-safe del DND centralizzato (aggiornato da
            // toggleDnd/refreshDnd): il flag @Published vive sul MainActor.
            if UserDefaults.standard.bool(forKey: "wad_sip_dnd") {
                WADDeviceLog.shared.log("sip", "INVITE rifiutato per Non disturbare")
                try? call.decline(reason: .Busy)
                return
            }
            guard self.currentCall == nil else {
                try? call.decline(reason: .Busy)
                return
            }
            self.currentCall = call
            self.qCallState = .ringingIn
            let display = call.remoteAddress?.displayName ?? ""
            let remote = display.isEmpty ? (call.remoteAddress?.username ?? "sconosciuto") : display
            WADDeviceLog.shared.log("sip.callkit", "INVITE ricevuto stato=\(state) remote=\(remote)")
            Task { @MainActor in
                self.remote = remote
                self.callState = .ringingIn
                self.callCenter?.sipReportedIncoming(from: remote)
            }
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging:
            self.qCallState = .ringingOut
            Task { @MainActor in self.callState = .ringingOut }
        case .Connected, .StreamsRunning:
            if self.qCallState != .inCall {
                self.qCallState = .inCall
                WADDeviceLog.shared.log("sip.callkit", "chiamata connessa")
                self.scheduleAudioSessionSafetyNetOnQueue()
                self.refreshAudioOutputsOnQueue()
                Task { @MainActor in
                    self.callState = .inCall
                    self.callStartedAt = Date()
                    self.callCenter?.sipCallConnected()
                }
            }
        case .End, .Released:
            WADDeviceLog.shared.log("sip.callkit", "chiamata terminata stato=\(state)")
            if let consult = self.consultCall {
                try? consult.terminate()
                self.consultCall = nil
                self.qConsultRemote = ""
            }
            if let conf = self.confCall {
                // chiusa la principale, la conferenza locale non ha più senso:
                // scioglila e termina anche la gamba del terzo partecipante.
                try? self.core?.terminateConference()
                try? conf.terminate()
                self.confCall = nil
                self.qConfRemote = ""
                self.qConfMerged = false
            }
            if self.audioSessionForced {
                // L'attivazione l'abbiamo forzata noi, quindi CallKit non manderà
                // il didDeactivate: chiudiamo noi la sessione audio.
                self.core?.activateAudioSession(activated: false)
                self.audioSessionForced = false
                self.audioSessionActive = false
            }
            self.currentCall = nil
            self.qCallState = .idle
            Task { @MainActor in
                self.consultState = .none
                self.consultRemote = ""
                self.confState = .none
                self.confRemote = ""
                self.finishCallPublished()
                self.callCenter?.sipCallEnded()
            }
        case .Error:
            self.currentCall = nil
            self.qCallState = .idle
            WADDeviceLog.shared.log("sip.error", "chiamata fallita: \(message)")
            Task { @MainActor in
                self.finishCallPublished()
                self.callCenter?.sipCallEnded()
                self.error = "Chiamata fallita: \(message)"
            }
        default:
            break
        }
    }

    private func finishCallPublished() {
        self.callState = .idle
        self.remote = ""
        self.callStartedAt = nil
        self.muted = false
    }

    func call(_ number: String) {
        let num = WADPhoneBook.dialable(number)
        guard !num.isEmpty else { return }
        self.error = nil
        self.sipQueue.async { self.callOnQueue(num) }
    }

    nonisolated private func callOnQueue(_ num: String) {
        guard let core = self.core, self.qRegistered, self.currentCall == nil else { return }
        do {
            let address = try Factory.Instance.createAddress(addr: "sip:\(num)@\(self.qDomain)")
            let params = try core.createCallParams(call: nil)
            self.currentCall = core.inviteAddressWithParams(addr: address, params: params)
            self.qCallState = .ringingOut
            Task { @MainActor in
                self.remote = num
                self.callState = .ringingOut
            }
        } catch {
            self.currentCall = nil
            self.qCallState = .idle
            Task { @MainActor in
                self.finishCallPublished()
                self.error = "Chiamata non avviabile: \(error.localizedDescription)"
            }
        }
    }

    func answer() {
        self.sipQueue.async {
            guard let call = self.currentCall, self.qCallState == .ringingIn else { return }
            try? call.accept()
        }
    }

    /// Risposta da CallKit. Se il push ha svegliato l'app ma Mercurio non ha
    /// ancora consegnato l'INVITE al core, prova il pickup dell'interno.
    func answerFromCallKit() {
        self.sipQueue.async {
            if let call = self.currentCall, self.qCallState == .ringingIn {
                WADDeviceLog.shared.log("sip.callkit", "answer: accetto currentCall")
                try? call.accept()
                return
            }
            let code = self.qPickupCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else {
                WADDeviceLog.shared.log("sip.callkit", "answer: nessuna currentCall e pickup assente")
                return
            }
            WADDeviceLog.shared.log("sip.callkit", "answer: fallback pickup \(code)")
            self.callOnQueue(code)
        }
    }

    func hangup() {
        self.sipQueue.async {
            guard let call = self.currentCall else { return }
            if self.qCallState == .ringingIn {
                try? call.decline(reason: .Declined)
            } else {
                try? call.terminate()
            }
            self.currentCall = nil
            self.qCallState = .idle
            Task { @MainActor in self.finishCallPublished() }
        }
    }

    func toggleMute() {
        self.sipQueue.async {
            guard let core = self.core, self.qCallState == .inCall else { return }
            core.micEnabled = !core.micEnabled
            let muted = !core.micEnabled
            Task { @MainActor in self.muted = muted }
        }
    }

    func toggleDnd() {
        guard !self.dndBusy else { return }
        self.dndBusy = true
        let want = !self.dnd
        Task { @MainActor in
            defer { self.dndBusy = false }
            do {
                let dnd = try await WADAPIClient.shared.setSipDnd(want)
                self.dnd = dnd
                UserDefaults.standard.set(dnd, forKey: "wad_sip_dnd")
                WADDeviceLog.shared.log("sip", "Non disturbare \(dnd ? "attivo" : "disattivato") sul centralino")
            } catch {
                WADDeviceLog.shared.log("sip.error", "toggle DND su Mercurio fallito: \(error.localizedDescription)")
                self.error = "Cambio Non disturbare fallito (centralino non raggiungibile)"
            }
        }
    }

    /// Rilegge lo stato DND dal centralino (può cambiare da web o telefono fisico).
    func refreshDnd() async {
        do {
            let dnd = try await WADAPIClient.shared.sipDnd()
            if dnd != self.dnd {
                WADDeviceLog.shared.log("sip", "stato Non disturbare dal centralino: \(dnd ? "attivo" : "spento")")
            }
            self.dnd = dnd
            UserDefaults.standard.set(dnd, forKey: "wad_sip_dnd")
        } catch {
            // centralino non raggiungibile: tengo l'ultimo stato noto
        }
    }

    func setMuted(_ muted: Bool) {
        self.sipQueue.async {
            guard let core = self.core else { return }
            core.micEnabled = !muted
            Task { @MainActor in self.muted = muted }
        }
    }

    /// Push VoIP ricevuto: assicura il core avviato e recupera l'INVITE pendente.
    func wakeForPush(callId: String?) async {
        WADDeviceLog.shared.log("sip.callkit", "wakeForPush callId=\(callId ?? "-")")
        if !self.coreReady { await self.start() }
        self.sipQueue.async {
            guard let core = self.core else {
                WADDeviceLog.shared.log("sip.error", "wakeForPush senza core pronto")
                return
            }
            core.processPushNotification(callId: callId)
        }
    }

    /// Avvia il core se serve e attende la registrazione SIP: per le chiamate
    /// partite da CarPlay ad app fredda, dove il telefono WAD non è mai stato aperto.
    func ensureRegistered(timeout: TimeInterval = 8) async -> Bool {
        if !self.coreReady { await self.start() }
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
    /// prima di accept/invite (requisito linphone con callkitEnabled). La coda
    /// seriale garantisce che venga eseguita prima dell'accept/invite accodato
    /// subito dopo.
    func configureAudioSession() {
        self.sipQueue.async { self.core?.configureAudioSession() }
    }

    /// Caso Laura 2026-07-21: cold-launch da push + pickup **201, CallKit non ha
    /// mai chiamato didActivate → audio unit mai partita, chiamata muta nei due
    /// sensi. Se entro 1.5s dalla connessione l'audio non è attivo, lo forziamo.
    nonisolated private func scheduleAudioSessionSafetyNetOnQueue() {
        self.sipQueue.asyncAfter(deadline: .now() + 1.5) {
            guard self.qCallState == .inCall, !self.audioSessionActive else { return }
            WADDeviceLog.shared.log("sip.callkit", "audio activate mancante, forzo attivazione")
            self.audioSessionForced = true
            self.audioSessionActive = true
            self.core?.activateAudioSession(activated: true)
        }
    }

    /// Attiva/disattiva la sessione audio linphone su richiesta di CallKit.
    func activateAudioSession(_ activated: Bool) {
        self.sipQueue.async {
            self.audioSessionActive = activated
            if activated { self.audioSessionForced = false }
            self.core?.activateAudioSession(activated: activated)
        }
    }

    // MARK: Uscita audio (vivavoce / auricolare / cuffie / Bluetooth)

    nonisolated struct AudioOutput: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let icon: String
        let isSpeaker: Bool
    }

    /// Uscite audio disponibili durante la chiamata (aggiornate live).
    @Published var audioOutputs: [AudioOutput] = []
    /// Id dell'uscita attualmente selezionata (device linphone).
    @Published var currentAudioOutputId = ""

    /// True se l'uscita corrente è l'altoparlante (vivavoce).
    var isSpeakerOn: Bool {
        self.audioOutputs.first(where: { $0.id == self.currentAudioOutputId })?.isSpeaker == true
    }

    nonisolated private static func audioLabel(_ device: AudioDevice) -> String {
        switch device.type {
        case .Speaker: return "Vivavoce"
        case .Earpiece: return "Auricolare"
        case .Bluetooth, .BluetoothA2DP: return device.deviceName.isEmpty ? "Bluetooth" : device.deviceName
        case .Headphones, .Headset: return "Cuffie"
        default: return device.deviceName.isEmpty ? "Audio" : device.deviceName
        }
    }

    nonisolated private static func audioIcon(_ device: AudioDevice) -> String {
        switch device.type {
        case .Speaker: return "speaker.wave.3.fill"
        case .Bluetooth, .BluetoothA2DP: return "airpodspro"
        case .Headphones, .Headset: return "headphones"
        default: return "phone.fill"
        }
    }

    /// Rilegge dalle linphone `audioDevices` le uscite riproducibili. Pubblica
    /// solo se cambia qualcosa: chiamabile a ogni tick del timer senza churn.
    func refreshAudioOutputs() {
        self.sipQueue.async { self.refreshAudioOutputsOnQueue() }
    }

    nonisolated private func refreshAudioOutputsOnQueue() {
        guard let core = self.core else {
            Task { @MainActor in
                if !self.audioOutputs.isEmpty { self.audioOutputs = [] }
                if !self.currentAudioOutputId.isEmpty { self.currentAudioOutputId = "" }
            }
            return
        }
        let outs = core.audioDevices
            .filter { $0.hasCapability(capability: .CapabilityPlay) }
            .map {
                AudioOutput(id: $0.id, name: Self.audioLabel($0),
                            icon: Self.audioIcon($0), isSpeaker: $0.type == .Speaker)
            }
        let curId = (self.currentCall?.outputAudioDevice ?? core.outputAudioDevice)?.id ?? ""
        Task { @MainActor in
            if outs != self.audioOutputs { self.audioOutputs = outs }
            if curId != self.currentAudioOutputId { self.currentAudioOutputId = curId }
        }
    }

    /// Instrada l'audio verso il device scelto (sia sulla call che sul core, così
    /// resta valido anche per la prossima chiamata).
    func setAudioOutput(id: String) {
        self.sipQueue.async {
            guard let core = self.core,
                  let device = core.audioDevices.first(where: { $0.id == id }) else { return }
            self.setAudioOutputOnQueue(device: device)
        }
    }

    nonisolated private func setAudioOutputOnQueue(device: AudioDevice) {
        guard let core = self.core else { return }
        if let call = self.currentCall { call.outputAudioDevice = device }
        core.outputAudioDevice = device
        WADDeviceLog.shared.log("sip", "uscita audio -> \(device.deviceName)")
        let id = device.id
        Task { @MainActor in self.currentAudioOutputId = id }
    }

    /// Alterna vivavoce / uscita precedente (per il caso semplice a 2 device).
    /// La scelta avviene sulla coda SIP sui device reali, non sullo snapshot UI.
    func toggleSpeaker() {
        self.sipQueue.async {
            guard let core = self.core else { return }
            let playable = core.audioDevices.filter { $0.hasCapability(capability: .CapabilityPlay) }
            let current = self.currentCall?.outputAudioDevice ?? core.outputAudioDevice
            let target = current?.type == .Speaker
                ? playable.first { $0.type != .Speaker }
                : playable.first { $0.type == .Speaker }
            guard let device = target else { return }
            self.setAudioOutputOnQueue(device: device)
        }
    }

    func sendDTMF(_ digit: String) {
        guard let scalar = digit.unicodeScalars.first else { return }
        let dtmf = CChar(scalar.value)
        self.sipQueue.async {
            guard let call = self.currentCall, self.qCallState == .inCall else { return }
            try? call.sendDtmf(dtmf: dtmf)
        }
    }

    /// Trasferimento cieco: REFER verso il numero/interno indicato.
    func transfer(to number: String) {
        let num = WADPhoneBook.dialable(number)
        guard !num.isEmpty else { return }
        self.sipQueue.async {
            guard let call = self.currentCall, self.qCallState == .inCall, self.confCall == nil else { return }
            do {
                let address = try Factory.Instance.createAddress(addr: "sip:\(num)@\(self.qDomain)")
                try call.transferTo(referTo: address)
                WADDeviceLog.shared.log("sip", "trasferimento verso \(num) inviato")
            } catch {
                WADDeviceLog.shared.log("sip.error", "trasferimento verso \(num) fallito: \(error.localizedDescription)")
                Task { @MainActor in
                    self.error = "Trasferimento non riuscito: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Trasferimento assistito

    /// Mette in attesa la chiamata principale e apre una consultazione verso
    /// il destinatario del trasferimento.
    func startAttendedTransfer(to number: String) {
        let num = WADPhoneBook.dialable(number)
        guard !num.isEmpty else { return }
        self.error = nil
        self.sipQueue.async {
            guard let core = self.core, let call = self.currentCall, self.qCallState == .inCall,
                  self.consultCall == nil, self.confCall == nil else { return }
            do {
                try call.pause()
                let address = try Factory.Instance.createAddress(addr: "sip:\(num)@\(self.qDomain)")
                let params = try core.createCallParams(call: nil)
                self.consultCall = core.inviteAddressWithParams(addr: address, params: params)
                self.qConsultRemote = num
                WADDeviceLog.shared.log("sip", "trasferimento assistito: consulto \(num)")
                Task { @MainActor in
                    self.consultRemote = num
                    self.consultState = .ringing
                }
            } catch {
                self.consultCall = nil
                self.qConsultRemote = ""
                try? call.resume()
                Task { @MainActor in
                    self.error = "Consultazione non avviabile: \(error.localizedDescription)"
                    self.consultState = .none
                    self.consultRemote = ""
                }
            }
        }
    }

    /// Congiunge le due gambe: la chiamata principale (in attesa) viene
    /// trasferita al destinatario della consultazione.
    func completeAttendedTransfer() {
        self.sipQueue.async {
            guard let main = self.currentCall, let consult = self.consultCall else { return }
            do {
                try main.transferToAnother(dest: consult)
                WADDeviceLog.shared.log("sip", "trasferimento assistito completato verso \(self.qConsultRemote)")
            } catch {
                WADDeviceLog.shared.log("sip.error", "trasferimento assistito fallito: \(error.localizedDescription)")
                Task { @MainActor in
                    self.error = "Trasferimento non riuscito: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Annulla la consultazione e riprende la chiamata principale.
    func cancelAttendedTransfer() {
        self.sipQueue.async {
            guard let consult = self.consultCall else { return }
            try? consult.terminate()
            // il resume della principale avviene alla chiusura della consult
        }
    }

    nonisolated private func handleConsultStateOnQueue(state: Call.State, message: String) {
        switch state {
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging:
            Task { @MainActor in self.consultState = .ringing }
        case .Connected, .StreamsRunning:
            Task { @MainActor in self.consultState = .connected }
        case .End, .Released, .Error:
            let failed = (state == .Error)
            self.consultCall = nil
            self.qConsultRemote = ""
            // Se la principale è ancora viva (annullo o destinatario non
            // raggiungibile) la riprendiamo; se il trasferimento è andato a
            // buon fine sta terminando e il resume fallisce senza danni.
            if let main = self.currentCall { try? main.resume() }
            Task { @MainActor in
                self.consultState = .none
                self.consultRemote = ""
                if failed { self.error = "Consultazione fallita: \(message)" }
            }
        default:
            break
        }
    }

    // MARK: Conferenza a tre (mixer locale linphone)

    /// Aggiunge un partecipante alla chiamata: chiama il numero (la principale
    /// va in pausa mentre squilla) e quando risponde unisce le due gambe nella
    /// conferenza locale linphone (l'audio dei tre viene mixato sul telefono).
    func startConference(with number: String) {
        let num = WADPhoneBook.dialable(number)
        guard !num.isEmpty else { return }
        self.error = nil
        self.sipQueue.async {
            guard let core = self.core, let call = self.currentCall, self.qCallState == .inCall,
                  self.consultCall == nil, self.confCall == nil else { return }
            do {
                try call.pause()
                let address = try Factory.Instance.createAddress(addr: "sip:\(num)@\(self.qDomain)")
                let params = try core.createCallParams(call: nil)
                self.confCall = core.inviteAddressWithParams(addr: address, params: params)
                self.qConfRemote = num
                self.qConfMerged = false
                WADDeviceLog.shared.log("sip", "conferenza: chiamo \(num)")
                Task { @MainActor in
                    self.confRemote = num
                    self.confState = .ringing
                }
            } catch {
                self.confCall = nil
                self.qConfRemote = ""
                try? call.resume()
                Task { @MainActor in
                    self.error = "Aggiunta partecipante non riuscita: \(error.localizedDescription)"
                    self.confState = .none
                    self.confRemote = ""
                }
            }
        }
    }

    /// Toglie il terzo partecipante dalla conferenza (o annulla mentre squilla)
    /// e torna alla chiamata 1:1 con l'interlocutore originale.
    func removeConfParticipant() {
        self.sipQueue.async {
            guard let conf = self.confCall else { return }
            try? conf.terminate()
            // il ripristino della principale avviene alla chiusura della gamba
        }
    }

    nonisolated private func handleConfStateOnQueue(state: Call.State, message: String) {
        switch state {
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging:
            Task { @MainActor in self.confState = .ringing }
        case .Connected:
            // 200 OK ricevuto ma i media del terzo non sono ancora attivi: la
            // fusione nel mixer va fatta solo a StreamsRunning. Farla qui (troppo
            // presto) univa una gamba senza stream audio → conferenza muta.
            break
        case .StreamsRunning:
            if !self.qConfMerged {
                self.qConfMerged = true
                do {
                    try self.core?.addAllToConference()
                    WADDeviceLog.shared.log("sip", "conferenza attiva con \(self.qConfRemote)")
                } catch {
                    WADDeviceLog.shared.log("sip.error", "merge conferenza fallito: \(error.localizedDescription)")
                    try? self.confCall?.terminate()
                    Task { @MainActor in
                        self.error = "Unione in conferenza fallita: \(error.localizedDescription)"
                    }
                    return
                }
                // Creando la conferenza linphone può reimpostare l'uscita audio
                // sul default: ripubblichiamo le uscite così la UI e la rotta
                // (vivavoce/Bluetooth) restano coerenti col mixer.
                self.refreshAudioOutputsOnQueue()
            }
            Task { @MainActor in self.confState = .active }
        case .End, .Released, .Error:
            let failed = (state == .Error)
            let wasMerged = self.qConfMerged
            self.confCall = nil
            self.qConfRemote = ""
            self.qConfMerged = false
            // Il terzo è uscito (o non ha risposto): sciogli la conferenza
            // rimasta e riprendi la 1:1 con l'interlocutore originale.
            if let main = self.currentCall {
                if wasMerged { try? self.core?.terminateConference() }
                try? main.resume()
            }
            Task { @MainActor in
                self.confState = .none
                self.confRemote = ""
                if failed { self.error = "Partecipante non raggiungibile: \(message)" }
            }
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
    @State private var confMode = false
    @State private var confNumber = ""

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { self.phone.toggleDnd() } label: {
                        if self.phone.dndBusy {
                            ProgressView()
                        } else {
                            Image(systemName: self.phone.dnd ? "bell.slash.fill" : "bell")
                                .foregroundStyle(self.phone.dnd ? Color.orange : Color.secondary)
                        }
                    }
                    .disabled(self.phone.dndBusy)
                    .accessibilityLabel(self.phone.dnd ? "Disattiva Non disturbare" : "Attiva Non disturbare")
                }
            }
            .task {
                await AVAudioApplication.requestRecordPermission()
                await self.phone.start()
                await self.phone.refreshDnd()
            }
            .onReceive(self.timer) { date in
                self.now = date
                if self.phone.callState == .inCall { self.phone.refreshAudioOutputs() }
            }
            .onChange(of: self.phone.callState) { _, state in
                if state != .inCall {
                    self.transferMode = false
                    self.transferNumber = ""
                    self.confMode = false
                    self.confNumber = ""
                }
            }
        }
    }

    /// Controllo uscita audio: toggle Vivavoce nel caso semplice (auricolare +
    /// altoparlante), menu di scelta quando ci sono anche cuffie/Bluetooth.
    @ViewBuilder private var audioOutputControl: some View {
        if self.phone.audioOutputs.count > 2 {
            let current = self.phone.audioOutputs.first { $0.id == self.phone.currentAudioOutputId }
            Menu {
                ForEach(self.phone.audioOutputs) { out in
                    Button { self.phone.setAudioOutput(id: out.id) } label: {
                        Label(out.name,
                              systemImage: out.id == self.phone.currentAudioOutputId ? "checkmark" : out.icon)
                    }
                }
            } label: {
                Label(current?.name ?? "Audio", systemImage: current?.icon ?? "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 28)
        } else {
            Button { self.phone.toggleSpeaker() } label: {
                Label("Vivavoce",
                      systemImage: self.phone.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.1.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(self.phone.isSpeakerOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 28)
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(self.phone.dnd ? Color.orange : (self.phone.registered ? Color.green : Color.red))
                .frame(width: 9, height: 9)
            Text(self.phone.dnd
                ? "Non disturbare attivo sul centralino"
                : (self.phone.registered
                    ? "Interno \(self.phone.ext) registrato"
                    : (self.phone.configured ? "Registrazione in corso..." : "Telefono non configurato")))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(self.phone.dnd ? Color.orange : Color.secondary)
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
                : self.phone.consultState != .none || self.phone.confState == .ringing ? "In attesa"
                : self.phone.confState == .active ? "Conferenza · \(self.elapsed)" : self.elapsed)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if self.phone.callState == .inCall {
                if self.phone.confState != .none {
                    self.confActiveView
                } else if self.confMode {
                    self.confAddView
                } else if self.phone.consultState != .none {
                    self.consultView
                } else if self.transferMode {
                    self.transferView
                } else {
                    self.keypad { self.phone.sendDTMF($0) }
                        .padding(.horizontal, 46)
                }
            }
            if self.phone.callState == .inCall
                && !self.transferMode && !self.confMode
                && self.phone.consultState == .none && self.phone.confState != .ringing {
                self.audioOutputControl
            }
            if !((self.transferMode || self.confMode
                    || self.phone.consultState != .none || self.phone.confState != .none)
                && self.phone.callState == .inCall) {
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
                        Button { self.confMode = true } label: {
                            Label("Conf.", systemImage: "person.badge.plus")
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
                                    if contact.dnd == true {
                                        Text("🔕")
                                            .font(.caption2)
                                    }
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

    /// Scelta del partecipante da aggiungere alla conferenza.
    private var confAddView: some View {
        VStack(spacing: 10) {
            Text("Aggiungi partecipante")
                .font(.subheadline.weight(.semibold))
            TextField("Nome o numero", text: self.$confNumber)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .padding(.horizontal, 40)
            if !self.book.interni.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(self.matchInterni(self.confNumber)) { contact in
                            Button { self.confNumber = contact.ext } label: {
                                HStack {
                                    Text(contact.name)
                                        .font(.subheadline.weight(.semibold))
                                    if contact.dnd == true {
                                        Text("🔕")
                                            .font(.caption2)
                                    }
                                    Spacer()
                                    Text(contact.ext)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                            }
                            .buttonStyle(.bordered)
                            .tint(self.confNumber == contact.ext ? Color.accentColor : Color.secondary)
                        }
                    }
                    .padding(.horizontal, 40)
                }
                .frame(maxHeight: 190)
            }
            HStack(spacing: 12) {
                Button("Annulla") {
                    self.confMode = false
                    self.confNumber = ""
                }
                .buttonStyle(.bordered)
                Button("Chiama e unisci") { self.doConference(self.confNumber) }
                    .buttonStyle(.borderedProminent)
                    .disabled(WADPhoneBook.dialable(self.confNumber).isEmpty)
            }
        }
        .task { await self.book.loadInterni() }
    }

    private func doConference(_ target: String) {
        self.phone.startConference(with: target)
        self.confMode = false
        self.confNumber = ""
    }

    /// Conferenza in corso (o terzo partecipante che squilla).
    private var confActiveView: some View {
        VStack(spacing: 12) {
            Text("👥 \(self.phone.confRemote)")
                .font(.subheadline.weight(.semibold))
            Text(self.phone.confState == .active
                ? "In conferenza: vi sentite tutti e tre"
                : "Squilla...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(self.phone.confState == .active ? "Rimuovi" : "Annulla") {
                    self.phone.removeConfParticipant()
                }
                .buttonStyle(.bordered)
                Button { self.phone.toggleMute() } label: {
                    Label(self.phone.muted ? "Riattiva" : "Muta",
                          systemImage: self.phone.muted ? "mic.slash.fill" : "mic.fill")
                }
                .buttonStyle(.bordered)
                Button { self.phone.hangup() } label: {
                    Label("Chiudi", systemImage: "phone.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            Text("«Chiudi» termina la chiamata per tutti")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 12)
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
                                subtitle: contact.dnd == true
                                    ? "interno \(contact.ext) · 🔕 non disturbare"
                                    : "interno \(contact.ext)",
                                number: contact.ext,
                                dnd: contact.dnd == true)
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

    private func contactRow(name: String, subtitle: String, number: String?, dnd: Bool = false) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Self.avatarColor(for: name))
                Text(Self.initials(of: name))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .overlay(alignment: .bottomTrailing) {
                if dnd {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(dnd ? Color.orange : Color.secondary)
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
                            subtitle: contact.dnd == true
                                ? "interno \(contact.ext) · 🔕 non disturbare"
                                : "interno \(contact.ext)",
                            number: contact.ext,
                            dnd: contact.dnd == true)
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
