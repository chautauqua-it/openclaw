import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct AuthenticatorActionContext: Codable, Equatable {
    let environment: String
    let tenant: String
    let audience: String
    let actionId: String
    let requestHash: String

    var isComplete: Bool {
        [self.environment, self.tenant, self.audience, self.actionId, self.requestHash]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            Self.isHex64(self.requestHash)
    }

    private static func isHex64(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    func canonicalData() -> Data {
        var output = Data()
        for value in [self.environment, self.tenant, self.audience, self.actionId, self.requestHash] {
            let bytes = Data(value.utf8)
            var size = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
            output.append(bytes)
        }
        return output
    }
}

struct AuthenticatorChallenge: Codable, Equatable {
    let personId: String
    let initiatorDeviceId: String
    let nonce: String
    let action: AuthenticatorActionContext
    let target: String
    let parameterSummary: String
    let matchCodeDigits: Int
    let expiresAtUnix: Int64

    func validationError(now: Date = Date()) -> String? {
        let strings = [self.personId, self.initiatorDeviceId, self.target, self.parameterSummary]
        guard strings.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              self.personId.count == 64,
              self.personId.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              self.initiatorDeviceId.count == 64,
              self.initiatorDeviceId.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              self.action.isComplete,
              self.matchCodeDigits >= 2,
              self.matchCodeDigits <= 8,
              self.personId != self.initiatorDeviceId,
              let nonceData = Data(base64Encoded: self.nonce),
              nonceData.count == 32,
              self.expiresAtUnix > Int64(now.timeIntervalSince1970)
        else {
            if self.personId == self
                .initiatorDeviceId { return "L'approvatore non può essere il dispositivo iniziatore." }
            if self.expiresAtUnix <= Int64(now.timeIntervalSince1970) { return "La richiesta è scaduta." }
            return "La richiesta di approvazione è incompleta o non valida."
        }
        return nil
    }

    func signingMessage(enteredCode: String, decision: String) throws -> Data {
        guard self.validationError() == nil,
              enteredCode.count == self.matchCodeDigits,
              enteredCode.allSatisfy(\.isNumber),
              decision == "approve" || decision == "deny",
              let nonceData = Data(base64Encoded: self.nonce)
        else { throw AuthenticatorError.invalidChallenge }

        var input = Data([0x02])
        input.append(Data(self.personId.utf8))
        input.append(Data(self.initiatorDeviceId.utf8))
        input.append(nonceData)
        input.append(Data(enteredCode.utf8))
        input.append(Data(decision.utf8))
        input.append(self.action.canonicalData())
        return input
    }

    func digest(enteredCode: String, decision: String) throws -> Data {
        try Data(SHA256.hash(data: self.signingMessage(enteredCode: enteredCode, decision: decision)))
    }
}

struct AuthenticatorResolutionPayload: Encodable, Equatable {
    let enteredCode: String
    let personId: String
    let signatureDER: String
    let publicKeyDER: String
    let decision: String

    enum CodingKeys: String, CodingKey {
        case enteredCode, personId, decision
        case signatureDER = "signatureDer"
        case publicKeyDER = "publicKeyDer"
    }
}

enum AuthenticatorUIState: Equatable {
    case invalid(String)
    case ready
    case resolving

    static func resolve(challenge: AuthenticatorChallenge, code: String, resolving: Bool, now: Date = Date()) -> Self {
        if let error = challenge.validationError(now: now) { return .invalid(error) }
        if resolving { return .resolving }
        guard code.count == challenge.matchCodeDigits, code.allSatisfy(\.isNumber) else {
            return .invalid("Inserisci il codice numerico di \(challenge.matchCodeDigits) cifre.")
        }
        return .ready
    }
}

enum AuthenticatorError: LocalizedError {
    case invalidChallenge
    case authenticationFailed
    case keyUnavailable
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidChallenge: "Richiesta Authenticator non valida o scaduta."
        case .authenticationFailed: "Identità locale non verificata."
        case .keyUnavailable: "Chiave Authenticator non disponibile."
        case .identityMismatch: "La chiave locale non corrisponde all'identità richiesta."
        }
    }
}

actor AuthenticatorStore {
    static let shared = AuthenticatorStore()
    private let service = "ai.openclaw.ios.authenticator"
    private let account = "p256-signing-key-v1"

    struct Identity: Encodable, Equatable {
        let personId: String
        let publicKeyDer: String
    }

    func identity() throws -> Identity {
        let key = try self.loadOrCreateKey()
        let publicDER = Self.publicKeyDER(key.publicKeyX963)
        let personID = SHA256.hash(data: publicDER).map { String(format: "%02x", $0) }.joined()
        return Identity(personId: personID, publicKeyDer: publicDER.base64EncodedString())
    }

    func makeResolution(
        challenge: AuthenticatorChallenge,
        enteredCode: String,
        decision: String,
        authenticate: Bool) async throws -> AuthenticatorResolutionPayload
    {
        guard challenge.validationError() == nil else { throw AuthenticatorError.invalidChallenge }
        if authenticate {
            try await self.authenticateLocally()
        }
        let key = try self.loadOrCreateKey()
        let publicDER = Self.publicKeyDER(key.publicKeyX963)
        let derivedPersonID = SHA256.hash(data: publicDER).map { String(format: "%02x", $0) }.joined()
        guard derivedPersonID == challenge.personId.lowercased() else { throw AuthenticatorError.identityMismatch }
        let message = try challenge.signingMessage(enteredCode: enteredCode, decision: decision)
        let signatureDER = try key.signatureDER(for: message)
        return AuthenticatorResolutionPayload(
            enteredCode: enteredCode,
            personId: challenge.personId,
            signatureDER: signatureDER.base64EncodedString(),
            publicKeyDER: publicDER.base64EncodedString(),
            decision: decision)
    }

    private func authenticateLocally() async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Annulla"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw AuthenticatorError.authenticationFailed
        }
        do {
            let allowed = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Conferma l'approvazione dell'azione critica")
            guard allowed else { throw AuthenticatorError.authenticationFailed }
        } catch {
            throw AuthenticatorError.authenticationFailed
        }
    }

    private enum StoredSigner {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case keychain(P256.Signing.PrivateKey)

        var publicKeyX963: Data {
            switch self {
            case let .secureEnclave(key): key.publicKey.x963Representation
            case let .keychain(key): key.publicKey.x963Representation
            }
        }

        func signatureDER(for message: Data) throws -> Data {
            switch self {
            case let .secureEnclave(key): try key.signature(for: message).derRepresentation
            case let .keychain(key): try key.signature(for: message).derRepresentation
            }
        }
    }

    private func loadOrCreateKey() throws -> StoredSigner {
        if let stored = try self.readKey() {
            if let secureKey = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored) {
                return .secureEnclave(secureKey)
            }
            if let softwareKey = try? P256.Signing.PrivateKey(rawRepresentation: stored) {
                return .keychain(softwareKey)
            }
            throw AuthenticatorError.keyUnavailable
        }

        #if targetEnvironment(simulator)
        let key = P256.Signing.PrivateKey()
        try self.writeKey(key.rawRepresentation)
        return .keychain(key)
        #else
        if SecureEnclave.isAvailable {
            let secureKey = try SecureEnclave.P256.Signing.PrivateKey()
            try self.writeKey(secureKey.dataRepresentation)
            return .secureEnclave(secureKey)
        }
        throw AuthenticatorError.keyUnavailable
        #endif
    }

    private func readKey() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.service,
            kSecAttrAccount: self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AuthenticatorError.keyUnavailable }
        return data
    }

    private func writeKey(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.service,
            kSecAttrAccount: self.account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data,
        ]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw AuthenticatorError.keyUnavailable
        }
    }

    static func publicKeyDER(_ x963: Data) -> Data {
        Data([
            0x30,
            0x59,
            0x30,
            0x13,
            0x06,
            0x07,
            0x2A,
            0x86,
            0x48,
            0xCE,
            0x3D,
            0x02,
            0x01,
            0x06,
            0x08,
            0x2A,
            0x86,
            0x48,
            0xCE,
            0x3D,
            0x03,
            0x01,
            0x07,
            0x03,
            0x42,
            0x00,
        ]) + x963
    }
}
