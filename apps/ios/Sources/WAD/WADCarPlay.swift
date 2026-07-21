import CarPlay
import Foundation

// MARK: - Scena CarPlay del telefono WAD.
// Con l'entitlement carplay-communication le chiamate CallKit compaiono già
// native sullo schermo dell'auto; questa scena aggiunge la rubrica degli
// interni RESTART per avviare una chiamata direttamente dal display.

final class WADCarPlaySceneDelegate: UIResponder, @preconcurrency CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController)
    {
        self.interfaceController = interfaceController
        WADDeviceLog.shared.log("carplay", "scena connessa")
        let loading = CPListTemplate(title: "WAD", sections: [
            CPListSection(items: [CPListItem(text: "Carico la rubrica…", detailText: nil)]),
        ])
        interfaceController.setRootTemplate(loading, animated: false, completion: nil)
        Task { @MainActor [weak self] in
            await self?.showDirectory()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController)
    {
        self.interfaceController = nil
        WADDeviceLog.shared.log("carplay", "scena disconnessa")
    }

    private func showDirectory() async {
        let contacts = (try? await WADAPIClient.shared.sipDirectory()) ?? []
        guard let interfaceController = self.interfaceController else { return }
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
        let template = CPListTemplate(title: "WAD", sections: [CPListSection(items: items)])
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
    }
}
