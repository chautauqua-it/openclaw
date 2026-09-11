import CryptoKit
import Foundation

enum IanuaDeviceKeyError: LocalizedError {
    case keychainUnavailable
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable:
            "Impossibile salvare la chiave del dispositivo nel portachiavi."
        case let .generationFailed(detail):
            "Impossibile creare la chiave del dispositivo: \(detail)"
        }
    }
}

/// Chiave P-256 del dispositivo usata per la prova di possesso nel provisioning.
///
/// La privata non lascia mai il telefono. Nel Secure Enclave non è nemmeno
/// estraibile: quello che finisce nel portachiavi è un blob opaco che solo
/// quell'Enclave sa riaprire. Dove l'Enclave non c'è (simulatore, hardware senza
/// SEP) la chiave è una P-256 software nel portachiavi, e il server lo viene a
/// sapere con `enclave: false`. Un device che si dichiara hardware-protetto
/// senza esserlo è peggio di uno dichiaratamente software: qui non si mente.
struct IanuaDeviceKey {
    enum Storage: Equatable {
        case secureEnclave
        case software
    }

    let storage: Storage
    /// Pubblica in forma X||Y (64 byte) codificata base64url: è quella che il
    /// server ricostruisce come JWK P-256.
    let publicKeyBase64URL: String

    private let signer: (Data) throws -> Data

    var isEnclaveBacked: Bool {
        self.storage == .secureEnclave
    }

    /// Firma ECDSA P-256/SHA-256 in forma grezza r||s (64 byte), l'unica che il
    /// server accetta (`dsaEncoding: "ieee-p1363"`).
    func signature(over payload: Data) throws -> Data {
        try self.signer(payload)
    }

    init(storage: Storage, publicKeyBase64URL: String, signer: @escaping (Data) throws -> Data) {
        self.storage = storage
        self.publicKeyBase64URL = publicKeyBase64URL
        self.signer = signer
    }
}

enum IanuaDeviceKeyStore {
    private static let service = "it.differen.ianua.device-key"
    private static let enclaveAccount = "p256-enclave-v1"
    private static let softwareAccount = "p256-software-v1"

    /// Carica la chiave del device, creandola al primo uso.
    ///
    /// La stessa chiave viene riusata nelle attivazioni successive: il server
    /// ha un indice unico su (utente, chiave pubblica) e riusa la riga invece di
    /// moltiplicare dispositivi fantasma per la stessa persona.
    static func loadOrCreate() throws -> IanuaDeviceKey {
        if SecureEnclave.isAvailable {
            return try self.enclaveKey()
        }
        return try self.softwareKey()
    }

    private static func enclaveKey() throws -> IanuaDeviceKey {
        if let stored = KeychainStore.loadString(service: self.service, account: self.enclaveAccount),
           let blob = Data(base64Encoded: stored),
           let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        {
            return self.wrap(key)
        }
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey()
        } catch {
            throw IanuaDeviceKeyError.generationFailed(error.localizedDescription)
        }
        guard KeychainStore.saveString(
            key.dataRepresentation.base64EncodedString(),
            service: self.service,
            account: self.enclaveAccount)
        else { throw IanuaDeviceKeyError.keychainUnavailable }
        return self.wrap(key)
    }

    private static func softwareKey() throws -> IanuaDeviceKey {
        if let stored = KeychainStore.loadString(service: self.service, account: self.softwareAccount),
           let raw = Data(base64Encoded: stored),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw)
        {
            return self.wrap(key)
        }
        let key = P256.Signing.PrivateKey()
        guard KeychainStore.saveString(
            key.rawRepresentation.base64EncodedString(),
            service: self.service,
            account: self.softwareAccount)
        else { throw IanuaDeviceKeyError.keychainUnavailable }
        return self.wrap(key)
    }

    private static func wrap(_ key: SecureEnclave.P256.Signing.PrivateKey) -> IanuaDeviceKey {
        IanuaDeviceKey(
            storage: .secureEnclave,
            publicKeyBase64URL: key.publicKey.rawRepresentation.ianuaBase64URLEncodedString())
        { payload in
            try key.signature(for: payload).rawRepresentation
        }
    }

    private static func wrap(_ key: P256.Signing.PrivateKey) -> IanuaDeviceKey {
        IanuaDeviceKey(
            storage: .software,
            publicKeyBase64URL: key.publicKey.rawRepresentation.ianuaBase64URLEncodedString())
        { payload in
            try key.signature(for: payload).rawRepresentation
        }
    }
}

extension Data {
    /// base64url senza padding: la forma che `Buffer.from(x, "base64url")`
    /// rilegge senza conversioni lato server.
    func ianuaBase64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
