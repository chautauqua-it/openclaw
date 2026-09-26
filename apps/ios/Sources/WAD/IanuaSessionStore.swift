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
    /// Identità del dispositivo, non una credenziale: il server la usa per
    /// chiudere la sessione precedente di QUESTO telefono invece di
    /// affiancarne una nuova. Va rispecchiata nel Keychain come le altre, ma
    /// deve sopravvivere al logout: azzerarla farebbe ripartire da capo il
    /// conteggio dei dispositivi a ogni 401, che è il difetto da evitare.
    private static let deviceCookieName = "ianua_device"
    private static var mirroredCookieNames: [String] { self.cookieNames + [self.deviceCookieName] }

    static let expiredMessage = "Sessione scaduta. Apri Chat ed esegui nuovamente il login."

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
        let stored = (jar.cookies ?? [])
            .filter { self.mirroredCookieNames.contains($0.name) && $0.domain.contains(self.cookieDomain) }
        guard !stored.isEmpty, let raw = self.encode(stored) else { return false }
        return KeychainStore.saveString(raw, service: self.service, account: self.account)
    }

    /// Se i cookie di sessione mancano dallo store condiviso ma esiste una copia
    /// valida nel Keychain, li ripristina. Idempotente e best-effort.
    static func restoreIfNeeded() {
        let jar = HTTPCookieStorage.shared
        let present = (jar.cookies ?? [])
            .contains { $0.name == "ianua_session" && $0.domain.contains(self.cookieDomain) }
        let stored = self.loadValidCookies()
        // L'identità del dispositivo va rimessa anche a sessione presente: dopo
        // un logout resta solo lei nel Keychain, ed è il login successivo a
        // doverla ritrovare per non contare un telefono nuovo.
        if present {
            if !(jar.cookies ?? []).contains(where: { $0.name == self.deviceCookieName }),
               let device = stored.first(where: { $0.name == self.deviceCookieName })
            {
                jar.setCookie(device)
            }
            return
        }
        for cookie in stored { jar.setCookie(cookie) }
    }

    /// True se nel Keychain c'è una sessione non scaduta da ripristinare.
    static func hasPersistedSession() -> Bool {
        self.loadValidCookies().contains { $0.name == "ianua_session" }
    }

    /// Rimuove sia la copia Keychain sia i cookie condivisi. Su un 401 il
    /// server ha già revocato il token: lasciarlo nel cookie jar farebbe
    /// continuare Chat, Telefono e Realtime a inviarlo fino al prossimo login.
    static func clear() {
        let jar = HTTPCookieStorage.shared
        let device = (jar.cookies ?? []).first {
            $0.name == self.deviceCookieName && $0.domain.contains(self.cookieDomain)
        } ?? self.loadValidCookies().first { $0.name == self.deviceCookieName }
        if let device, let raw = self.encode([device]) {
            _ = KeychainStore.saveString(raw, service: self.service, account: self.account)
        } else {
            _ = KeychainStore.delete(service: self.service, account: self.account)
        }
        (jar.cookies ?? [])
            .filter { self.cookieNames.contains($0.name) && $0.domain.contains(self.cookieDomain) }
            .forEach(jar.deleteCookie)
    }

    private static func encode(_ cookies: [HTTPCookie]) -> String? {
        let stored = cookies.map {
            StoredCookie(
                name: $0.name,
                value: $0.value,
                domain: $0.domain,
                path: $0.path.isEmpty ? "/" : $0.path,
                expiresEpoch: $0.expiresDate?.timeIntervalSince1970,
                isSecure: $0.isSecure)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return nil }
        return String(data: data, encoding: .utf8)
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
