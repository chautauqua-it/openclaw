import Foundation

/// Contenuto del QR coniato dall'operatore: `ianua://provision?s=<slug>&t=<token>`.
///
/// Il QR NON trasporta l'host di nessun server: l'app parla solo con il proprio
/// endpoint pubblico canonico. È la ragione per cui un QR fotografato o inoltrato
/// non può dirottare l'attivazione su un server di qualcun altro.
///
/// Il token è la credenziale: monouso, a vita breve, e vale solo nello schema
/// del tenant indicato da `s`.
struct IanuaProvisionLink: Equatable {
    let slug: String
    let token: String

    static let scheme = "ianua"
    static let route = "provision"

    static func parse(_ raw: String) -> IanuaProvisionLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return self.parse(url)
    }

    static func parse(_ url: URL) -> IanuaProvisionLink? {
        guard url.scheme?.lowercased() == self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // `ianua://provision?…` mette la rotta nell'host, `ianua:provision?…` nel path.
        let host = components.host ?? ""
        let route = (host.isEmpty ? components.path : host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard route == self.route else { return nil }
        let items = components.queryItems ?? []
        let slug = items.first { $0.name == "s" }?.value ?? ""
        let token = items.first { $0.name == "t" }?.value ?? ""
        guard self.isValidSlug(slug), self.isValidToken(token) else { return nil }
        return IanuaProvisionLink(slug: slug, token: token)
    }

    /// Stessi vincoli del server: uno slug o un token malformato non vale una
    /// chiamata di rete, e riconoscerlo qui distingue "QR di un'altra app" da
    /// "codice Iànua rifiutato" nel messaggio mostrato alla persona.
    static func isValidSlug(_ value: String) -> Bool {
        value.range(of: "^[a-z][a-z0-9-]{1,29}$", options: .regularExpression) != nil
    }

    static func isValidToken(_ value: String) -> Bool {
        value.range(of: "^ibs_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }
}

/// Link di attivazione arrivato dal custom scheme, in attesa di essere mostrato.
///
/// Il custom scheme è una comodità, non il percorso principale: qualunque app
/// può registrare `ianua://`, quindi un link non attiva mai niente da solo —
/// apre la schermata di attivazione e aspetta che sia la persona a confermare.
@MainActor
final class IanuaProvisioningInbox: ObservableObject {
    static let shared = IanuaProvisioningInbox()

    @Published private(set) var pending: IanuaProvisionLink?

    func submit(_ link: IanuaProvisionLink) {
        self.pending = link
    }

    func take() -> IanuaProvisionLink? {
        defer { self.pending = nil }
        return self.pending
    }
}
