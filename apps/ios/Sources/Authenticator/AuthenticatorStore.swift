import Foundation
import Observation
import OpenClawKit
import Security

@MainActor
@Observable
final class AuthenticatorStore {
    private static let service = "it.differen.ianua.authenticator"
    private static let account = "totp-accounts-v1"

    private(set) var accounts: [TOTPAccount] = []
    private(set) var persistenceError: String?

    init() {
        self.load()
    }

    func add(uri: URL) throws {
        let candidate = try TOTP.parse(uri: uri)
        guard !self.accounts.contains(where: {
            $0.issuer.caseInsensitiveCompare(candidate.issuer) == .orderedSame
                && $0.name.caseInsensitiveCompare(candidate.name) == .orderedSame
        }) else { throw TOTPError.invalidParameters }
        self.accounts.append(candidate)
        self.accounts.sort { ($0.displayIssuer, $0.name) < ($1.displayIssuer, $1.name) }
        try self.persist()
    }

    func remove(at offsets: IndexSet) {
        let previous = self.accounts
        for index in offsets.sorted(by: >) {
            self.accounts.remove(at: index)
        }
        do { try self.persist() } catch {
            self.accounts = previous
            self.persistenceError = error.localizedDescription
        }
    }

    private func load() {
        guard let raw = GenericPasswordKeychainStore.loadString(service: Self.service, account: Self.account),
              let data = raw.data(using: .utf8)
        else { return }
        do { self.accounts = try JSONDecoder().decode([TOTPAccount].self, from: data) }
        catch { self.persistenceError = "Archivio Authenticator non leggibile." }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(self.accounts)
        guard let raw = String(data: data, encoding: .utf8),
              GenericPasswordKeychainStore.saveString(
                  raw,
                  service: Self.service,
                  account: Self.account,
                  accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        else { throw CocoaError(.fileWriteUnknown) }
        self.persistenceError = nil
    }
}
