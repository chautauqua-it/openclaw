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
    private var spockMeterTimer: Timer?
    private var spockMeterFrame = 0

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

        let rubrica = CPListTemplate(
            title: "Rubrica",
            sections: [CPListSection(items: [CPListItem(text: "Carico la rubrica…", detailText: nil)])])
        rubrica.tabTitle = "Rubrica"
        rubrica.tabImage = UIImage(systemName: "person.crop.circle.fill")

        let spock = CPListTemplate(title: "Spock", sections: [self.spockSection()])
        spock.tabTitle = "Spock"
        spock.tabImage = UIImage(systemName: "waveform")
        self.spockTemplate = spock

        let tabBar = CPTabBarTemplate(templates: [phone, rubrica, spock])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
        self.observeSpockState()
        self.startSpockMeterTimer()
        Task { @MainActor [weak self] in
            await self?.showPhoneBook(in: phone, rubrica: rubrica)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController)
    {
        self.interfaceController = nil
        self.spockTemplate = nil
        self.stopSpockMeterTimer()
        WADDeviceLog.shared.log("carplay", "scena disconnessa")
    }

    // MARK: - Tab Telefono (preferiti + interni) e Rubrica (contatti iPhone)

    @MainActor
    private func showPhoneBook(in template: CPListTemplate, rubrica: CPListTemplate) async {
        let book = WADPhoneBook.shared
        await book.loadAll()
        await book.loadDeviceContacts()
        guard self.interfaceController != nil else { return }

        var sections: [CPListSection] = []
        if !book.favorites.isEmpty {
            let items = book.favorites.map { favorite in
                self.callItem(
                    text: favorite.name,
                    detail: favorite.number,
                    number: WADPhoneBook.dialable(favorite.number))
            }
            sections.append(CPListSection(items: items, header: "Preferiti", sectionIndexTitle: nil))
        }
        if book.interni.isEmpty {
            sections.append(CPListSection(items: [
                CPListItem(text: "Interni non disponibili", detailText: "Apri WAD sull'iPhone e riprova"),
            ]))
        } else {
            let items = book.interni.map { contact in
                self.callItem(text: contact.name, detail: "Interno \(contact.ext)", number: contact.ext)
            }
            sections.append(CPListSection(items: items, header: "Interni", sectionIndexTitle: nil))
        }
        template.updateSections(sections)

        let rubricaItems: [CPListItem]
        if book.contactsDenied {
            rubricaItems = [CPListItem(
                text: "Accesso alla rubrica negato",
                detailText: "Autorizza i contatti in Impostazioni > OpenClaw")]
        } else if book.deviceContacts.isEmpty {
            rubricaItems = [CPListItem(text: "Rubrica vuota", detailText: nil)]
        } else {
            // Un item per numero, entro il limite CarPlay del template.
            var items: [CPListItem] = []
            let cap = CPListTemplate.maximumItemCount
            outer: for contact in book.deviceContacts {
                for number in contact.numbers {
                    if items.count >= cap { break outer }
                    let detail = contact.numbers.count > 1
                        ? "\(number.label) \(number.value)"
                        : number.value
                    items.append(self.callItem(
                        text: contact.name,
                        detail: detail,
                        number: WADPhoneBook.dialable(number.value)))
                }
            }
            rubricaItems = items
        }
        rubrica.updateSections([CPListSection(items: rubricaItems)])
    }

    private func callItem(text: String, detail: String, number: String) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail)
        item.handler = { _, completion in
            completion()
            Task { @MainActor in
                WADDeviceLog.shared.log("carplay", "chiamo \(number)")
                if await WADSipManager.shared.ensureRegistered() {
                    WADCallCenter.shared.reportOutgoing(to: number)
                } else {
                    WADDeviceLog.shared.log("carplay", "chiamata \(number) annullata: SIP non registrato")
                }
            }
        }
        return item
    }

    // MARK: - Tab Spock (voce realtime)

    private func spockSection() -> CPListSection {
        let manager = SpockTalkManager.shared
        var items: [CPListItem] = []

        let meter = CPListItem(
            text: manager.isActive ? "KITT VU meter" : "Spock spento",
            detailText: manager.isActive
                ? self.spockStatusText(manager)
                : "Tocca il meter per avviare la conversazione")
        meter.setImage(self.kittCarPlayImage(for: manager))
        meter.handler = { _, completion in
            completion()
            Task { @MainActor in
                if SpockTalkManager.shared.isActive {
                    WADDeviceLog.shared.log("carplay", "spock: meter stop")
                    SpockTalkManager.shared.stop()
                    NodeAppModel.current?.endSpockTalkCapture()
                } else {
                    WADDeviceLog.shared.log("carplay", "spock: meter start")
                    NodeAppModel.current?.beginSpockTalkCapture()
                    SpockTalkManager.shared.start()
                }
            }
        }
        items.append(meter)

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

    private func startSpockMeterTimer() {
        self.stopSpockMeterTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSpockMeterFrame()
            }
        }
        self.spockMeterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSpockMeterTimer() {
        self.spockMeterTimer?.invalidate()
        self.spockMeterTimer = nil
    }

    private func refreshSpockMeterFrame() {
        guard self.interfaceController != nil, let template = self.spockTemplate else { return }
        let manager = SpockTalkManager.shared
        guard manager.isActive else { return }
        self.spockMeterFrame += 1
        template.updateSections([self.spockSection()])
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

    private func kittCarPlayImage(for manager: SpockTalkManager) -> UIImage {
        let active = manager.isActive
        let level = self.carPlayMeterLevel(for: manager)
        let size = CGSize(width: 96, height: 96)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            cg.clear(CGRect(origin: .zero, size: size))

            let columns = [
                (x: CGFloat(16), segments: 7, width: CGFloat(17), scale: 0.72),
                (x: CGFloat(39), segments: 11, width: CGFloat(18), scale: 1.00),
                (x: CGFloat(63), segments: 7, width: CGFloat(17), scale: 0.72),
            ]
            let segmentHeight: CGFloat = 5.0
            let segmentGap: CGFloat = 3.0
            let centerY = size.height / 2.0

            for (columnIndex, column) in columns.enumerated() {
                let center = column.segments / 2
                let wave = sin((Double(self.spockMeterFrame) * 0.85) + (Double(columnIndex) * 1.45))
                let jitter = 0.84 + (wave * 0.16)
                let litLevel = min(1.0, max(0.0, level * column.scale * jitter))
                let litFromCenter = Int((Double(column.segments) / 2.0 * litLevel).rounded())

                for index in 0..<column.segments {
                    let distance = abs(index - center)
                    let lit = active && distance <= litFromCenter && litLevel > 0.02
                    let color: UIColor
                    if !active {
                        color = UIColor(white: 0.30, alpha: 1.0)
                    } else if lit {
                        color = UIColor(red: 0.98, green: 0.06, blue: 0.02, alpha: 1.0)
                    } else {
                        color = UIColor(red: 0.27, green: 0.02, blue: 0.01, alpha: 1.0)
                    }
                    color.setFill()

                    let offset = CGFloat(index - center) * (segmentHeight + segmentGap)
                    let rect = CGRect(
                        x: column.x,
                        y: centerY + offset - (segmentHeight / 2.0),
                        width: column.width,
                        height: segmentHeight)
                    UIBezierPath(roundedRect: rect, cornerRadius: 1.5).fill()
                }
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    private func carPlayMeterLevel(for manager: SpockTalkManager) -> Double {
        guard manager.isActive else { return 0 }
        switch manager.phase {
        case .connecting:
            return 0.12
        case .listening:
            return 0.16
        case .speaking:
            return max(0.18, min(1.0, manager.speechLevel))
        case .idle, .error:
            return 0
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
