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
    /// Token VoIP esadecimale registrato su WAD (per de-dup e re-invio).
    private var lastSentToken: String?

    private static func providerConfiguration() -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
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
        // Aggancia il manager SIP così i cambi di stato aggiornano CallKit.
        WADSipManager.shared.callCenter = self
    }

    // MARK: Chiamata in arrivo (da push)

    /// Segnala a CallKit una chiamata in arrivo. DEVE essere invocata dentro il
    /// handler del push VoIP prima che ritorni, altrimenti iOS termina l'app.
    func reportIncoming(callId: String?, from: String, displayName: String, completion: @escaping () -> Void) {
        let uuid = UUID()
        self.activeCallUUID = uuid
        let update = CXCallUpdate()
        let title = displayName.isEmpty ? from : displayName
        update.remoteHandle = CXHandle(type: .generic, value: title.isEmpty ? "Sconosciuto" : title)
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        self.provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if error != nil {
                self.activeCallUUID = nil
            } else {
                // Sveglia il SIP e recupera l'INVITE per questo call-id.
                Task { @MainActor in await WADSipManager.shared.wakeForPush(callId: callId) }
            }
            completion()
        }
    }

    // MARK: Ponti da WADSipManager (linphone → CallKit)

    /// linphone ha rilevato una chiamata in arrivo in foreground (senza push):
    /// se non l'abbiamo già segnalata via push, mostriamo comunque la UI di sistema.
    func sipReportedIncoming(from: String) {
        guard self.activeCallUUID == nil else { return }
        self.reportIncoming(callId: nil, from: from, displayName: from) {}
    }

    /// La chiamata è entrata in conversazione: informa CallKit (timer, stato).
    func sipCallConnected() {
        guard let uuid = self.activeCallUUID else { return }
        self.provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// La chiamata è terminata lato SIP: chiudi la sessione CallKit.
    func sipCallEnded() {
        guard let uuid = self.activeCallUUID else { return }
        self.activeCallUUID = nil
        self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
    }

    /// Chiamata uscente avviata dall'app: registrala in CallKit per audio/Recents.
    func reportOutgoing(to number: String) {
        let uuid = UUID()
        self.activeCallUUID = uuid
        let handle = CXHandle(type: .generic, value: number)
        let action = CXStartCallAction(call: uuid, handle: handle)
        self.callController.request(CXTransaction(action: action)) { error in
            if error != nil { self.activeCallUUID = nil; return }
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
        Task { await self.sendTokenIfNeeded(token) }
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType)
    {
        self.lastSentToken = nil
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
        self.reportIncoming(callId: callId, from: from, displayName: displayName, completion: completion)
    }

    @MainActor
    private func sendTokenIfNeeded(_ token: String) async {
        guard token != self.lastSentToken else { return }
        do {
            try await WADAPIClient.shared.registerVoipToken(token)
            self.lastSentToken = token
        } catch {
            // Riproveremo al prossimo update del token o al riavvio.
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
        WADSipManager.shared.hangup()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        WADSipManager.shared.answer()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        self.activeCallUUID = nil
        WADSipManager.shared.hangup()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        WADSipManager.shared.call(action.handle.value)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        WADSipManager.shared.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        WADSipManager.shared.activateAudioSession(true)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        WADSipManager.shared.activateAudioSession(false)
    }
}
