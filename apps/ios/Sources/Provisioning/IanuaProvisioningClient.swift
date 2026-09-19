import CryptoKit
import Foundation
import OpenClawKit
#if canImport(UIKit)
import UIKit
#endif

enum IanuaProvisionError: LocalizedError, Equatable {
    /// Il QR non è un codice di attivazione Iànua (o è illeggibile).
    case notAnIanuaCode
    /// 404: token sconosciuto o malformato per il server.
    case notValid
    /// 410: scaduto, già usato o revocato. Il server li collassa di proposito in
    /// una risposta sola, così un chiamante non autenticato non impara nulla sui
    /// token altrui: l'app non può — e non deve — distinguerli.
    case noLongerValid
    /// 400: la prova di possesso non ha convinto il server.
    case proofRejected(String)
    case throttled(Int)
    case unreachable
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notAnIanuaCode:
            "Questo QR non è un codice di attivazione Iànua."
        case .notValid:
            "Codice di attivazione non valido. Chiedi all'operatore di generarne uno nuovo."
        case .noLongerValid:
            "Codice non più valido: è scaduto, è già stato usato o è stato revocato. "
                + "Chiedi all'operatore di generarne uno nuovo."
        case let .proofRejected(detail):
            detail
        case let .throttled(seconds):
            "Troppi tentativi di attivazione. Riprova tra \(max(seconds, 1)) secondi."
        case .unreachable:
            "Iànua non raggiungibile. Controlla la connessione Internet e riprova."
        case let .server(message):
            message
        }
    }
}

/// Scambio del token del QR con una sessione Iànua.
///
/// La rotta `/api/provision/claim` è l'unica del provisioning senza sessione, e
/// ha una semantica di stato che gli helper generici dell'app collassano di
/// proposito (404 e 410 dicono cose diverse alla persona). Per questo la
/// richiesta è scritta qui, ma tutto il resto è riuso: stesso host canonico di
/// `WADAPIClient`, stesso `URLSession.shared` — quindi stesso cookie jar — e
/// stessa persistenza `IanuaSessionStore`.
actor IanuaProvisioningClient {
    static let shared = IanuaProvisioningClient()

    /// Deve restare identico a `PROOF_CONTEXT` del server.
    static let proofContext = "ianua-provision-v1"

    struct Claim: Decodable, Equatable {
        struct Tenant: Decodable, Equatable {
            let slug: String
            let nome: String
        }

        struct User: Decodable, Equatable {
            let id: Int
            let email: String
            let nome: String
        }

        struct Device: Decodable, Equatable {
            let id: String
            let trust: String
        }

        struct Gateway: Decodable, Equatable {
            let status: String
            /// Campi di connessione del gateway, quando il server li allega alla
            /// claim (stessa forma di un setup code `/pair`, ma passati come JSON
            /// semplice invece che base64url). Opzionali per compatibilità con un
            /// server che manda solo `status`: finché non li spedisce, il device
            /// si attiva per la chat ma il nodo non si collega da solo.
            let url: String?
            let bootstrapToken: String?
            let token: String?
            let password: String?

            var connectDeepLink: GatewayConnectDeepLink? {
                guard let url else { return nil }
                return GatewayConnectDeepLink.fromProvisionClaim(
                    url: url, bootstrapToken: self.bootstrapToken, token: self.token, password: self.password)
            }
        }

        let tenant: Tenant
        let user: User
        let device: Device
        /// Stato del setup code del gateway, più i campi di connessione quando il
        /// server li allega (vedi `Gateway.connectDeepLink`). Finché il server manda
        /// solo `status`, `connectDeepLink` è nil e il chiamante lo tratta come "QR
        /// valido ma senza gateway", non come un errore.
        let gateway: Gateway?
    }

    func claim(_ link: IanuaProvisionLink) async throws -> Claim {
        let key = try IanuaDeviceKeyStore.loadOrCreate()
        let timestamp = Int((Date().timeIntervalSince1970 * 1000).rounded())
        let proof = [
            Self.proofContext,
            link.token,
            String(timestamp),
            Self.sha256Hex(key.publicKeyBase64URL),
        ].joined(separator: "\n")
        let signature = try key.signature(over: Data(proof.utf8))

        let body: [String: Any] = await [
            "slug": link.slug,
            "token": link.token,
            "device": Self.deviceDescriptor(),
            "key": [
                "pub": key.publicKeyBase64URL,
                "alg": "ES256",
                "enclave": key.isEnclaveBacked,
            ],
            "proof": [
                "ts": timestamp,
                "sig": signature.ianuaBase64URLEncodedString(),
            ],
        ]

        guard let url = URL(string: WADAPIClient.shared.baseURL + "/api/provision/claim") else {
            throw IanuaProvisionError.server("URL Iànua non valido")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (payload, response) = try await URLSession.shared.data(for: request)
            guard let typed = response as? HTTPURLResponse else {
                throw IanuaProvisionError.server("Risposta Iànua sconosciuta")
            }
            data = payload
            http = typed
        } catch let error as IanuaProvisionError {
            throw error
        } catch {
            throw IanuaProvisionError.unreachable
        }

        guard http.statusCode == 200 else {
            throw Self.failure(status: http.statusCode, data: data, response: http)
        }

        let claim: Claim
        do {
            claim = try JSONDecoder().decode(Claim.self, from: data)
        } catch {
            throw IanuaProvisionError.server("Risposta di attivazione non valida.")
        }

        // La sessione è arrivata come Set-Cookie nel cookie jar condiviso: da qui
        // in poi è identica a quella di un login, e si persiste allo stesso modo.
        guard IanuaSessionStore.persistCurrent() else {
            throw IanuaProvisionError.server(
                "Attivazione riuscita ma la sessione non è stata salvata sul dispositivo. Riprova.")
        }
        return claim
    }

    private static func failure(status: Int, data: Data, response: HTTPURLResponse) -> IanuaProvisionError {
        let code = IanuaRealtimeHTTPPolicy.serverError(from: data)
        switch status {
        case 404:
            return .notValid
        case 410:
            return .noLongerValid
        case 429:
            let retry = Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            return .throttled(retry)
        case 400:
            // Lo skew consentito è di due minuti: un orologio sbagliato è la
            // causa di gran lunga più probabile, e la persona può risolverla.
            if code == "provision_prova_non_valida" {
                return .proofRejected(
                    "Il dispositivo non ha superato la verifica della chiave. "
                        + "Controlla che data e ora del telefono siano automatiche, poi riprova.")
            }
            return .proofRejected("Chiave del dispositivo rifiutata da Iànua. Riprova.")
        default:
            return .server(code ?? "Attivazione non riuscita (errore \(status)).")
        }
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private static func deviceDescriptor() -> [String: String] {
        #if canImport(UIKit)
        return [
            "platform": "ios",
            "model": InstanceIdentity.modelIdentifier ?? UIDevice.current.model,
            "os": UIDevice.current.systemVersion,
            "name": UIDevice.current.name,
        ]
        #else
        return ["platform": "ios", "model": "", "os": "", "name": ""]
        #endif
    }
}
