import CarPlay
import Foundation
import Intents
import UIKit

// MARK: - Scena CarPlay del telefono WAD.
// Con l'entitlement carplay-communication le chiamate CallKit compaiono già
// native sullo schermo dell'auto; questa scena aggiunge due tab: la rubrica
// degli interni RESTART e "Parla con Spock" (voce realtime con muto).

final class WADCarPlaySceneDelegate: UIResponder, @preconcurrency CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var spockTemplate: CPListTemplate?
    private var observingSpock = false

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController)
    {
        self.interfaceController = interfaceController
        WADDeviceLog.shared.log("carplay", "scena connessa")

        let phone = CPListTemplate(
            title: "Telefono",
            sections: [CPListSection(items: [CPListItem(text: "Carico la rubrica…", detailText: nil)])],
            assistantCellConfiguration: CPAssistantCellConfiguration(
                position: .top,
                visibility: .always,
                assistantAction: .startCall))
        phone.tabTitle = "Telefono"
        phone.tabImage = UIImage(systemName: "phone.fill")

        let spock = CPListTemplate(title: "Spock", sections: [self.spockSection()])
        spock.tabTitle = "Spock"
        spock.tabImage = UIImage(systemName: "waveform")
        self.spockTemplate = spock

        let tabBar = CPTabBarTemplate(templates: [phone, spock])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
        self.observeSpockState()
        Task { @MainActor [weak self] in
            await self?.showDirectory(in: phone)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController)
    {
        self.interfaceController = nil
        self.spockTemplate = nil
        WADDeviceLog.shared.log("carplay", "scena disconnessa")
    }

    // MARK: - Tab Telefono (rubrica interni)

    private func showDirectory(in template: CPListTemplate) async {
        let contacts = (try? await WADAPIClient.shared.sipDirectory()) ?? []
        guard self.interfaceController != nil else { return }
        let items: [CPListItem]
        if contacts.isEmpty {
            items = [CPListItem(text: "Rubrica non disponibile", detailText: "Apri WAD sull'iPhone e riprova")]
        } else {
            items = contacts.map { contact in
                let item = CPListItem(text: contact.name, detailText: "Interno \(contact.ext)")
                item.handler = { _, completion in
                    completion()
                    let ext = contact.ext
                    Task { @MainActor in
                        WADDeviceLog.shared.log("carplay", "chiamo \(ext)")
                        if await WADSipManager.shared.ensureRegistered() {
                            WADCallCenter.shared.reportOutgoing(to: ext)
                        } else {
                            WADDeviceLog.shared.log("carplay", "chiamata \(ext) annullata: SIP non registrato")
                        }
                    }
                }
                return item
            }
        }
        template.updateSections([CPListSection(items: items)])
    }

    // MARK: - Tab Spock (voce realtime)

    private func spockSection() -> CPListSection {
        let manager = SpockTalkManager.shared
        var items: [CPListItem] = []

        let main: CPListItem
        if manager.isActive {
            main = CPListItem(text: "Termina conversazione", detailText: self.spockStatusText(manager))
            main.setImage(UIImage(systemName: "stop.circle.fill"))
            main.handler = { _, completion in
                completion()
                Task { @MainActor in
                    WADDeviceLog.shared.log("carplay", "spock: termino conversazione")
                    SpockTalkManager.shared.stop()
                    NodeAppModel.current?.endSpockTalkCapture()
                }
            }
        } else {
            let detail: String = if case .error(let message) = manager.phase {
                "Errore: \(message)"
            } else {
                "Avvia la conversazione vocale"
            }
            main = CPListItem(text: "Parla con Spock", detailText: detail)
            main.setImage(UIImage(systemName: "mic.circle.fill"))
            main.handler = { _, completion in
                completion()
                Task { @MainActor in
                    WADDeviceLog.shared.log("carplay", "spock: avvio conversazione")
                    NodeAppModel.current?.beginSpockTalkCapture()
                    SpockTalkManager.shared.start()
                }
            }
        }
        items.append(main)

        if manager.isActive {
            let mute = CPListItem(
                text: manager.isMuted ? "Riattiva microfono" : "Spegni microfono",
                detailText: manager.isMuted
                    ? "Il microfono è in muto: Spock non ti sente"
                    : "Spock ti ascolta: tocca per il muto")
            mute.setImage(UIImage(systemName: manager.isMuted ? "mic.slash.fill" : "mic.fill"))
            mute.handler = { _, completion in
                completion()
                Task { @MainActor in
                    SpockTalkManager.shared.toggleMute()
                }
            }
            items.append(mute)
        }

        return CPListSection(items: items)
    }

    private func spockStatusText(_ manager: SpockTalkManager) -> String {
        if manager.holdMusicActive { return "Musica d'attesa — microfono in muto" }
        if manager.isMuted { return "Microfono in muto" }
        return switch manager.phase {
        case .connecting: "Connessione al Mac mini…"
        case .listening: "Ti ascolto"
        case .speaking: "Spock sta parlando"
        default: "In corso"
        }
    }

    /// Osserva lo stato del manager (@Observable) e ridisegna la tab Spock a
    /// ogni cambiamento: withObservationTracking scatta una volta sola, quindi
    /// il callback si ri-registra da solo finché la scena è connessa.
    private func observeSpockState() {
        guard !self.observingSpock else { return }
        self.observingSpock = true
        self.registerSpockObservation()
    }

    private func registerSpockObservation() {
        withObservationTracking {
            let manager = SpockTalkManager.shared
            _ = manager.phase
            _ = manager.isMuted
            _ = manager.holdMusicActive
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.spockTemplate?.updateSections([self.spockSection()])
                guard self.interfaceController != nil else {
                    self.observingSpock = false
                    return
                }
                self.registerSpockObservation()
            }
        }
    }
}
