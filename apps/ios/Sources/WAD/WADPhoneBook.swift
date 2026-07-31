import Contacts
import Foundation
import SwiftUI

/// Rubrica unificata del telefono WAD: preferiti personali (persistiti in WAD,
/// Mercurio non li gestisce), interni RESTART e contatti del telefono.
/// Condivisa tra sheet iOS e CarPlay così le due UI restano allineate.
@MainActor
final class WADPhoneBook: ObservableObject {
    static let shared = WADPhoneBook()

    struct DeviceContact: Identifiable, Equatable {
        struct Number: Identifiable, Equatable {
            let label: String
            let value: String
            var id: String { self.label + self.value }
        }

        let id: String
        let name: String
        let numbers: [Number]
    }

    @Published var favorites: [WADSipFavorite] = []
    @Published var interni: [WADSipContact] = []
    @Published var deviceContacts: [DeviceContact] = []
    @Published var contactsDenied = false

    private var favoritesLoaded = false
    private var interniLoadedAt: Date?
    private var deviceLoaded = false

    /// Oltre questa età la lista interni viene ricaricata: porta con sé lo
    /// stato Non disturbare, che cambia durante la giornata.
    private static let interniTTL: TimeInterval = 60

    func loadAll() async {
        async let favs: Void = self.loadFavorites()
        async let ints: Void = self.loadInterni()
        _ = await (favs, ints)
    }

    func loadFavorites(force: Bool = false) async {
        guard force || !self.favoritesLoaded else { return }
        if let favorites = try? await WADAPIClient.shared.sipFavorites() {
            self.favorites = favorites
            self.favoritesLoaded = true
        }
    }

    func loadInterni(force: Bool = false) async {
        if !force, let at = self.interniLoadedAt, Date().timeIntervalSince(at) < Self.interniTTL { return }
        if let contacts = try? await WADAPIClient.shared.sipDirectory() {
            self.interni = contacts
            self.interniLoadedAt = Date()
        }
    }

    func isFavorite(number: String) -> Bool {
        self.favorites.contains { $0.number == number }
    }

    func addFavorite(name: String, number: String, kind: String) async {
        guard (try? await WADAPIClient.shared.addSipFavorite(name: name, number: number, kind: kind)) != nil
        else { return }
        await self.loadFavorites(force: true)
    }

    func removeFavorite(number: String) async {
        guard let favorite = self.favorites.first(where: { $0.number == number }) else { return }
        if (try? await WADAPIClient.shared.deleteSipFavorite(id: favorite.id)) != nil {
            self.favorites.removeAll { $0.id == favorite.id }
        }
    }

    /// Contatti del telefono (CNContactStore), ordinati per nome, solo quelli
    /// con almeno un numero. Chiede il permesso alla prima apertura della rubrica.
    func loadDeviceContacts(force: Bool = false) async {
        guard force || !self.deviceLoaded else { return }
        let granted: Bool
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            granted = true
        case .notDetermined:
            granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        default:
            granted = false
        }
        guard granted else {
            self.contactsDenied = true
            self.deviceLoaded = true
            return
        }
        self.contactsDenied = false
        let contacts = await Task.detached(priority: .userInitiated) { Self.fetchDeviceContacts() }.value
        self.deviceContacts = contacts
        self.deviceLoaded = true
    }

    private nonisolated static func fetchDeviceContacts() -> [DeviceContact] {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var result: [DeviceContact] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let display = name.isEmpty ? contact.organizationName : name
            guard !display.isEmpty, !contact.phoneNumbers.isEmpty else { return }
            let numbers = contact.phoneNumbers.map { entry in
                DeviceContact.Number(
                    label: CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: entry.label ?? ""),
                    value: entry.value.stringValue)
            }
            result.append(DeviceContact(id: contact.identifier, name: display, numbers: numbers))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Normalizza un numero della rubrica per la composizione SIP:
    /// toglie spazi/separatori e mantiene solo cifre, +, * e #.
    nonisolated static func dialable(_ number: String) -> String {
        String(number.unicodeScalars.filter { CharacterSet(charactersIn: "0123456789+*#").contains($0) })
    }
}
