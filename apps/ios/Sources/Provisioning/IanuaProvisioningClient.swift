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
    /// `GET /api/provision/gateway` → `{"status":"none"}`: il login è riuscito ma
    /// nessun pairing gateway è in corso per questo dispositivo.
    case gatewayNotPaired
    /// Il polling è rimasto su `"pending"` oltre il tetto di attesa lato app.
    case gatewayPairingTimedOut
    /// `"status":"ready"` ma `setup_code` manca o non è nel formato che
    /// `GatewayConnectDeepLink.fromSetupCode` sa leggere.
    case gatewayCodeUnreadable

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
        case .gatewayNotPaired:
            "Accesso riuscito, ma nessun collegamento gateway è stato avviato per questo dispositivo. "
                + "Genera un nuovo QR dal Mac (\"/pair qr\") oppure riprova dal profilo."
        case .gatewayPairingTimedOut:
            "Accesso riuscito, ma il collegamento al gateway non è arrivato in tempo. "
                + "Riprova, oppure usa il QR generato sul Mac (\"/pair qr\")."
        case .gatewayCodeUnreadable:
            "Accesso riuscito, ma il codice di collegamento ricevuto dal server non è nel formato "
                + "atteso da questa versione dell'app. Aggiorna l'app o chiedi all'operatore un QR \"/pair\"."
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
        }

        let tenant: Tenant
        let user: User
        let device: Device
        /// Stato del pairing gateway al momento della claim. Il collegamento vero e
        /// proprio arriva SOLO da `GET /api/provision/gateway` (polling con la
        /// sessione appena ricevuta, vedi `pollGatewaySetupCode`): per disegno di
        /// sicurezza il server pubblico che risponde a `/api/provision/claim` non
        /// custodisce mai il setup code del gateway self-hosted.
        let gateway: Gateway?
    }

    /// Risposta di `GET /api/provision/gateway`.
    struct GatewayPollResponse: Decodable {
        let status: String
        let retryAfter: Double?
        let setupCode: String?

        enum CodingKeys: String, CodingKey {
            case status
            case retryAfter = "retry_after"
            case setupCode = "setup_code"
        }
    }

    /// Esito di una singola interrogazione di `GET /api/provision/gateway`, prima di
    /// decidere cosa fare (funzione pura, testabile senza rete: vedi
    /// `IanuaProvisioningClaimDecodingTests`).
    enum GatewayPollOutcome: Equatable {
        case ready(GatewayConnectDeepLink)
        case retry(after: TimeInterval)
        case failure(IanuaProvisionError)
    }

    static let defaultGatewayPollInterval: TimeInterval = 3
    static let defaultGatewayPollTimeout: TimeInterval = 120

    static func interpret(_ response: GatewayPollResponse) -> GatewayPollOutcome {
        switch response.status {
        case "ready":
            guard let code = response.setupCode, let link = GatewayConnectDeepLink.fromSetupCode(code) else {
                return .failure(.gatewayCodeUnreadable)
            }
            return .ready(link)
        case "none":
            return .failure(.gatewayNotPaired)
        case "pending":
            return .retry(after: response.retryAfter.map { max($0, 1) } ?? self.defaultGatewayPollInterval)
        default:
            return .failure(.server("Stato gateway sconosciuto: \(response.status)."))
        }
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

    /// Interroga `GET /api/provision/gateway` con la sessione appena ottenuta da
    /// `claim(_:)` (autenticazione via cookie jar condiviso, nessun secondo token)
    /// finché non arriva un setup code o scade il tetto di attesa. Il minter gira
    /// fuori banda accanto al gateway: `"pending"` è lo stato normale nei primi
    /// secondi, non un errore.
    func pollGatewaySetupCode(timeout: TimeInterval = IanuaProvisioningClient.defaultGatewayPollTimeout) async throws
        -> GatewayConnectDeepLink
    {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let response = try await self.fetchGatewayStatus()
            switch Self.interpret(response) {
            case let .ready(link):
                return link
            case let .failure(error):
                throw error
            case let .retry(interval):
                guard Date() < deadline else {
                    throw IanuaProvisionError.gatewayPairingTimedOut
                }
                try await Task.sleep(nanoseconds: UInt64(max(interval, 0) * 1_000_000_000))
            }
        }
    }

    private func fetchGatewayStatus() async throws -> GatewayPollResponse {
        guard let url = URL(string: WADAPIClient.shared.baseURL + "/api/provision/gateway") else {
            throw IanuaProvisionError.server("URL Iànua non valido")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

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

        do {
            return try JSONDecoder().decode(GatewayPollResponse.self, from: data)
        } catch {
            throw IanuaProvisionError.server("Risposta di stato gateway non valida.")
        }
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
