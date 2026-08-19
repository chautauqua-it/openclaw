import CryptoKit
import Foundation

enum TOTPAlgorithm: String, Codable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

struct TOTPAccount: Codable, Identifiable, Equatable {
    var id: UUID
    var issuer: String
    var name: String
    var secret: String
    var algorithm: TOTPAlgorithm
    var digits: Int
    var period: Int

    var displayIssuer: String {
        self.issuer.isEmpty ? "Account" : self.issuer
    }
}

enum TOTPError: LocalizedError, Equatable {
    case invalidURI
    case invalidSecret
    case unsupportedType
    case invalidParameters

    var errorDescription: String? {
        switch self {
        case .invalidURI: "QR Authenticator non valido."
        case .invalidSecret: "Secret Base32 non valido."
        case .unsupportedType: "Sono supportati solo account TOTP."
        case .invalidParameters: "Parametri TOTP non supportati."
        }
    }
}

enum TOTP {
    static func parse(uri: URL) throws -> TOTPAccount {
        guard uri.absoluteString.utf8.count <= 4096 else { throw TOTPError.invalidURI }
        guard uri.scheme?.lowercased() == "otpauth", uri.host?.lowercased() == "totp" else {
            throw TOTPError.unsupportedType
        }
        guard let components = URLComponents(url: uri, resolvingAgainstBaseURL: false) else {
            throw TOTPError.invalidURI
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let key = item.name.lowercased()
            guard query[key] == nil, let value = item.value else { throw TOTPError.invalidURI }
            query[key] = value
        }
        guard let rawSecret = query["secret"] else { throw TOTPError.invalidSecret }
        let secret = self.normalizeSecret(rawSecret)
        guard !secret.isEmpty, secret.count <= 256, (try? self.decodeBase32(secret)) != nil else {
            throw TOTPError.invalidSecret
        }

        let label = uri.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let labelParts = label.split(separator: ":", maxSplits: 1).map(String.init)
        let issuer = (query["issuer"] ?? (labelParts.count == 2 ? labelParts[0] : ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (labelParts.count == 2 ? labelParts[1] : (labelParts.first ?? ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128, issuer.count <= 128 else { throw TOTPError.invalidURI }

        let algorithm = TOTPAlgorithm(rawValue: (query["algorithm"] ?? "SHA1").uppercased())
        let digits = Int(query["digits"] ?? "6")
        let period = Int(query["period"] ?? "30")
        guard let algorithm, let digits, [6, 8].contains(digits), let period, (15...120).contains(period) else {
            throw TOTPError.invalidParameters
        }
        return TOTPAccount(
            id: UUID(), issuer: issuer, name: name, secret: secret,
            algorithm: algorithm, digits: digits, period: period)
    }

    static func code(for account: TOTPAccount, at date: Date = Date()) throws -> String {
        let key = try SymmetricKey(data: decodeBase32(account.secret))
        var counter = UInt64(floor(date.timeIntervalSince1970 / Double(account.period))).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let digest = switch account.algorithm {
        case .sha1: Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(digest.last! & 0x0F)
        let value = digest[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7FFF_FFFF
        let modulus = UInt32(pow(10.0, Double(account.digits)))
        return String(format: "%0*u", account.digits, value % modulus)
    }

    static func secondsRemaining(for account: TOTPAccount, at date: Date = Date()) -> Int {
        let elapsed = Int(floor(date.timeIntervalSince1970)) % account.period
        return account.period - elapsed
    }

    private static func normalizeSecret(_ value: String) -> String {
        value.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "=" }
    }

    private static func decodeBase32(_ value: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer = 0
        var bits = 0
        var output = Data()
        for character in self.normalizeSecret(value) {
            guard let index = alphabet.firstIndex(of: character) else { throw TOTPError.invalidSecret }
            buffer = (buffer << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        guard !output.isEmpty else { throw TOTPError.invalidSecret }
        return output
    }
}
