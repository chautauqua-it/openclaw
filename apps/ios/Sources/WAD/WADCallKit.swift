import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit

// MARK: - CallKit + PushKit per il telefono SIP Mercurio.
// PushKit riceve il push VoIP (inviato dal ponte Mercurio→APNs) e sveglia l'app
// anche a schermo spento; CallKit mostra la schermata di chiamata di sistema con
// suoneria, Rispondi/Rifiuta. L'audio e il SIP restano gestiti da WADSipManager
// (linphone), che con callkitEnabled=true delega a CallKit la sessione audio.
//
// Nota: il ring end-to-end richiede il ponte lato server che invii il push VoIP
// quando arriva una chiamata all'interno dell'utente. Senza quel ponte questo
// modulo resta inerte (nessun push = nessun risveglio), senza effetti collaterali.

@MainActor
final class WADCallCenter: NSObject, ObservableObject {
    static let shared = WADCallCenter()

    private var voipRegistry: PKPushRegistry?
    private let provider: CXProvider
    private let callController = CXCallController()

    /// UUID della chiamata corrente lato CallKit. Una sola linea per volta.
    private var activeCallUUID: UUID?
    /// True quando linphone ha davvero la chiamata SIP dietro lo squillo CallKit.
    private var sipCallArrived = false
    /// Ultimo token VoIP ricevuto da PushKit; se arriva prima del login WAD lo
    /// ritentiamo appena la sessione diventa valida.
    private var currentToken: String?
    /// Token VoIP esadecimale registrato su WAD (per de-dup e re-invio).
    private var lastSentToken: String?

    private static func providerConfiguration() -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        // 2 gruppi: il push VoIP duplicato (chiamata già mostrata da linphone in
        // foreground) deve poter fare un report "fantasma" che riesca — se il
        // report fallisce iOS termina l'app (riavvio + "errore di chiamata").
        config.maximumCallGroups = 2
        config.supportedHandleTypes = [.generic, .phoneNumber]
        config.includesCallsInRecents = true
        return config
    }

    override private init() {
        self.provider = CXProvider(configuration: Self.providerConfiguration())
        super.init()
        self.provider.setDelegate(self, queue: nil)
    }

    // MARK: Ciclo di vita

    /// Registra PushKit VoIP. Chiamare una sola volta all'avvio dell'app.
    func registerForVoipPushes() {
        guard self.voipRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.voipRegistry = registry
        WADDeviceLog.shared.log("sip.callkit", "PushKit registrato")
        // Aggancia il manager SIP così i cambi di stato aggiornano CallKit.
        WADSipManager.shared.callCenter = self
    }

    /// Da chiamare dopo login/bootstrap WAD: PushKit può consegnare il token
    /// prima che il cookie sessione sia valido, quindi serve un retry esplicito.
    func refreshVoipTokenRegistration() {
        guard let token = self.currentToken else { return }
        WADDeviceLog.shared.log("sip.callkit", "retry token VoIP dopo login")
        Task { await self.sendTokenIfNeeded(token) }
    }

    // MARK: Chiamata in arrivo (da push)

    /// Segnala a CallKit una chiamata in arrivo. DEVE essere invocata dentro il
    /// handler del push VoIP prima che ritorni, altrimenti iOS termina l'app.
    /// fromPush=false ⇒ la segnalazione parte da linphone (chiamata SIP già
    /// presente in foreground); da push invece la chiamata vera deve ancora arrivare.
    func reportIncoming(callId: String?, from: String, displayName: String, fromPush: Bool = true, completion: @escaping () -> Void) {
        let title = displayName.isEmpty ? from : displayName
        if fromPush, self.activeCallUUID != nil {
            // Push duplicato: linphone (app in foreground, interno registrato) ha
            // già segnalato questa chiamata a CallKit prima che il push arrivasse.
            // Non toccare la chiamata vera; iOS esige comunque un report riuscito
            // per ogni push VoIP, quindi segnaliamo una chiamata fantasma e la
            // chiudiamo subito. Senza questo iOS termina l'app.
            WADDeviceLog.shared.log("sip.callkit", "push duplicato (chiamata già attiva), report fantasma")
            let ghost = UUID()
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: title.isEmpty ? "Sconosciuto" : title)
            update.hasVideo = false
            self.provider.reportNewIncomingCall(with: ghost, update: update) { error in
                if let error {
                    WADDeviceLog.shared.log("sip.callkit", "report fantasma fallito: \(error.localizedDescription)")
                }
                self.provider.reportCall(with: ghost, endedAt: Date(), reason: .answeredElsewhere)
                completion()
            }
            return
        }
        let uuid = UUID()
        self.activeCallUUID = uuid
        self.sipCallArrived = !fromPush
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: title.isEmpty ? "Sconosciuto" : title)
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        self.provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if error != nil {
                WADDeviceLog.shared.log("sip.callkit", "report incoming fallito: \(error?.localizedDescription ?? "errore")")
                self.activeCallUUID = nil
            } else {
                WADDeviceLog.shared.log("sip.callkit", "report incoming ok callId=\(callId ?? "-") from=\(title)")
                if fromPush {
                    // Sveglia il SIP e recupera l'INVITE per questo call-id. Solo
                    // da push: se la segnalazione viene da linphone il SIP è già
                    // sveglio e processPushNotification confonderebbe il core.
                    Task { @MainActor in await WADSipManager.shared.wakeForPush(callId: callId) }
                    self.scheduleGhostRingWatchdog(for: uuid)
                }
            }
            completion()
        }
    }

    /// Se entro il timeout la chiamata SIP vera non è arrivata (Mercurio non
    /// ripropone l'INVITE a chi si registra in ritardo, o il chiamante ha già
    /// riattaccato), chiudi lo squillo come "senza risposta" invece di lasciare
    /// una suoneria fantasma a cui rispondere è impossibile.
    private func scheduleGhostRingWatchdog(for uuid: UUID, timeout: UInt64 = 25) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard self.activeCallUUID == uuid, !self.sipCallArrived else { return }
            self.activeCallUUID = nil
            WADDeviceLog.shared.log("sip.callkit", "watchdog: nessun INVITE dopo push, chiudo squillo")
            self.provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
        }
    }

    // MARK: Ponti da WADSipManager (linphone → CallKit)

    /// linphone ha rilevato una chiamata in arrivo in foreground (senza push):
    /// se non l'abbiamo già segnalata via push, mostriamo comunque la UI di sistema.
    func sipReportedIncoming(from: String) {
        self.sipCallArrived = true
        WADDeviceLog.shared.log("sip.callkit", "linphone ha INVITE remote=\(from)")
        guard self.activeCallUUID == nil else { return }
        self.reportIncoming(callId: nil, from: from, displayName: from, fromPush: false) {}
    }

    /// La chiamata è entrata in conversazione: informa CallKit (timer, stato).
    func sipCallConnected() {
        self.sipCallArrived = true
        guard let uuid = self.activeCallUUID else { return }
        WADDeviceLog.shared.log("sip.callkit", "CallKit connected")
        self.provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// La chiamata è terminata lato SIP: chiudi la sessione CallKit.
    func sipCallEnded() {
        guard let uuid = self.activeCallUUID else { return }
        self.activeCallUUID = nil
        WADDeviceLog.shared.log("sip.callkit", "CallKit ended")
        self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
    }

    /// Chiamata uscente avviata dall'app: registrala in CallKit per audio/Recents.
    func reportOutgoing(to number: String) {
        let uuid = UUID()
        self.activeCallUUID = uuid
        let handle = CXHandle(type: .generic, value: number)
        let action = CXStartCallAction(call: uuid, handle: handle)
        self.callController.request(CXTransaction(action: action)) { error in
            if error != nil {
                WADDeviceLog.shared.log("sip.callkit", "start outgoing fallito: \(error?.localizedDescription ?? "errore")")
                self.activeCallUUID = nil
                return
            }
            WADDeviceLog.shared.log("sip.callkit", "start outgoing ok \(number)")
            Task { @MainActor in
                self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            }
        }
    }
}

// MARK: - PKPushRegistryDelegate

// Conformance @preconcurrency: PushKit invoca la delegate sulla queue passata a
// PKPushRegistry (qui .main), quindi i metodi MainActor-isolati sono sicuri e non
// dobbiamo spedire completion (non-Sendable) attraverso un confine di attore.
extension WADCallCenter: @preconcurrency PKPushRegistryDelegate {
    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType)
    {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        self.currentToken = token
        WADDeviceLog.shared.log("sip.callkit", "token VoIP ricevuto suffix=\(token.suffix(8))")
        Task { await self.sendTokenIfNeeded(token) }
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType)
    {
        self.lastSentToken = nil
        WADDeviceLog.shared.log("sip.callkit", "token VoIP invalidato")
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void)
    {
        let info = payload.dictionaryPayload
        let callId = info["callId"] as? String
        let from = (info["from"] as? String) ?? "Sconosciuto"
        let displayName = (info["displayName"] as? String) ?? from
        WADDeviceLog.shared.log("sip.callkit", "push incoming callId=\(callId ?? "-") from=\(from)")
        self.reportIncoming(callId: callId, from: from, displayName: displayName, completion: completion)
    }

    @MainActor
    private func sendTokenIfNeeded(_ token: String) async {
        guard token != self.lastSentToken else { return }
        do {
            try await WADAPIClient.shared.registerVoipToken(token)
            self.lastSentToken = token
            WADDeviceLog.shared.log("sip.callkit", "token VoIP inviato a WAD suffix=\(token.suffix(8))")
        } catch {
            WADDeviceLog.shared.log("sip.callkit", "token VoIP non inviato: \(error.localizedDescription)")
        }
    }
}

// MARK: - CXProviderDelegate

// Conformance @preconcurrency: CXProvider è creato con queue nil ⇒ i callback
// arrivano sulla main queue, quindi i metodi MainActor-isolati sono corretti e non
// dobbiamo spedire le CXAction (non-Sendable) attraverso un confine di attore.
extension WADCallCenter: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        self.activeCallUUID = nil
        WADDeviceLog.shared.log("sip.callkit", "provider reset")
        WADSipManager.shared.hangup()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        WADDeviceLog.shared.log("sip.callkit", "azione rispondi")
        // linphone richiede la configurazione della AVAudioSession PRIMA di
        // accept/invite quando CallKit gestisce l'audio: senza, su cold-launch
        // da push il didActivate può non arrivare e la chiamata resta muta.
        WADSipManager.shared.configureAudioSession()
        _ = WADSipManager.shared.answerFromCallKit()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        self.activeCallUUID = nil
        WADDeviceLog.shared.log("sip.callkit", "azione termina")
        WADSipManager.shared.hangup()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        WADDeviceLog.shared.log("sip.callkit", "azione start \(action.handle.value)")
        WADSipManager.shared.configureAudioSession()
        WADSipManager.shared.call(action.handle.value)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        WADDeviceLog.shared.log("sip.callkit", "azione mute=\(action.isMuted)")
        WADSipManager.shared.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        WADDeviceLog.shared.log("sip.callkit", "audio activate")
        WADSipManager.shared.activateAudioSession(true)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        WADDeviceLog.shared.log("sip.callkit", "audio deactivate")
        WADSipManager.shared.activateAudioSession(false)
    }
}
