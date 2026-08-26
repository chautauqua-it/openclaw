import Foundation

// Mirror in Keychain della sessione Iànua (cookie firmati ianua_session +
// ianua_members). Perché: iOS può scartare i cookie dal cookie-store (cold
// start senza Max-Age lato server pre-fix, reset dello store, ecc.). Tenendone
// una copia nel Keychain — che sopravvive a chiusure e riavvii — l'app può
// ripristinarli e restare connessa senza chiedere di nuovo il login.
//
// Il cookie resta firmato HMAC lato server e revocabile ("I miei dispositivi"):
// qui non conserviamo credenziali, solo il token di sessione a scadenza. Alla
// revoca lato server il token diventa inerte e l'app torna al login.
enum IanuaSessionStore {
    private static let service = "it.differen.ianua.session"
    private static let account = "cookies-v1"
    private static let cookieDomain = "ianua.differen.it"
    private static let cookieNames = ["ianua_session", "ianua_members"]

    private struct StoredCookie: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expiresEpoch: Double?
        var isSecure: Bool
    }

    /// Cattura i cookie di sessione correnti dallo store condiviso e li salva nel
    /// Keychain. Da chiamare dopo un login riuscito.
    @discardableResult
    static func persistCurrent() -> Bool {
        let jar = HTTPCookieStorage.shared
        let stored: [StoredCookie] = (jar.cookies ?? [])
            .filter { self.cookieNames.contains($0.name) && $0.domain.contains(self.cookieDomain) }
            .map {
                StoredCookie(
                    name: $0.name,
                    value: $0.value,
                    domain: $0.domain,
                    path: $0.path.isEmpty ? "/" : $0.path,
                    expiresEpoch: $0.expiresDate?.timeIntervalSince1970,
                    isSecure: $0.isSecure)
            }
        guard !stored.isEmpty,
              let data = try? JSONEncoder().encode(stored),
              let raw = String(data: data, encoding: .utf8)
        else { return false }
        return KeychainStore.saveString(raw, service: self.service, account: self.account)
    }

    /// Se i cookie di sessione mancano dallo store condiviso ma esiste una copia
    /// valida nel Keychain, li ripristina. Idempotente e best-effort.
    static func restoreIfNeeded() {
        let jar = HTTPCookieStorage.shared
        let present = (jar.cookies ?? [])
            .contains { $0.name == "ianua_session" && $0.domain.contains(self.cookieDomain) }
        if present { return }
        for cookie in self.loadValidCookies() { jar.setCookie(cookie) }
    }

    /// True se nel Keychain c'è una sessione non scaduta da ripristinare.
    static func hasPersistedSession() -> Bool {
        self.loadValidCookies().contains { $0.name == "ianua_session" }
    }

    /// Rimuove la copia Keychain. Da chiamare al logout o su 401 definitivo.
    static func clear() {
        KeychainStore.delete(service: self.service, account: self.account)
    }

    private static func loadValidCookies() -> [HTTPCookie] {
        guard let raw = KeychainStore.loadString(service: self.service, account: self.account),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([StoredCookie].self, from: data)
        else { return [] }
        let now = Date()
        var cookies: [HTTPCookie] = []
        for item in decoded {
            if let epoch = item.expiresEpoch, Date(timeIntervalSince1970: epoch) <= now { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: item.name,
                .value: item.value,
                .domain: item.domain,
                .path: item.path,
            ]
            if let epoch = item.expiresEpoch { props[.expires] = Date(timeIntervalSince1970: epoch) }
            if item.isSecure { props[.secure] = "TRUE" }
            if let cookie = HTTPCookie(properties: props) { cookies.append(cookie) }
        }
        return cookies
    }
}
