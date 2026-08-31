import Foundation
import Observation

private struct IanuaAuthenticatorRequest: Decodable {
    let personId: String
    let initiatorDeviceId: String
    let nonce: String
    let action: AuthenticatorActionContext
    let target: String
    let parameterSummary: String
    let matchCodeDigits: Int
}

private struct IanuaAuthenticatorPendingItem: Decodable {
    let id: String
    let request: IanuaAuthenticatorRequest
    let expiresAt: Date

    var challenge: AuthenticatorChallenge {
        AuthenticatorChallenge(
            id: self.id,
            personId: self.request.personId,
            initiatorDeviceId: self.request.initiatorDeviceId,
            nonce: self.request.nonce,
            action: self.request.action,
            target: self.request.target,
            parameterSummary: self.request.parameterSummary,
            matchCodeDigits: self.request.matchCodeDigits,
            expiresAtUnix: Int64(self.expiresAt.timeIntervalSince1970))
    }
}

private struct IanuaAuthenticatorPendingResponse: Decodable {
    let challenges: [IanuaAuthenticatorPendingItem]
}

private struct IanuaAuthenticatorResolveBody: Encodable {
    let id: String
    let decision: String
    let proof: AuthenticatorResolutionPayload
}

enum IanuaAuthenticatorError: LocalizedError {
    case enrollmentRequired

    var errorDescription: String? {
        switch self {
        case .enrollmentRequired:
            "Inserisci un codice TOTP fresco per attivare questo iPhone."
        }
    }
}

actor IanuaAuthenticatorClient {
    static let shared = IanuaAuthenticatorClient()

    private let baseURL = URL(string: "https://ianua.differen.it")!
    private let decoder = IanuaAuthenticatorClient.makeDecoder()

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Data ISO 8601 non valida")
            }
            return date
        }
        return decoder
    }

    func enroll(identity: AuthenticatorStore.Identity, label: String, totpCode: String? = nil) async throws {
        var body = ["publicKeyDer": identity.publicKeyDer, "label": label]
        if let totpCode { body["totpCode"] = totpCode }
        _ = try await self.request(
            path: "/api/authenticator/enroll",
            method: "POST",
            body: try JSONEncoder().encode(body))
    }

    func pending(personId: String) async throws -> [AuthenticatorChallenge] {
        let data = try await self.request(path: "/api/authenticator/pending")
        return try Self.decodePending(data, decoder: self.decoder)
            .filter { $0.personId == personId }
    }

    nonisolated static func decodePending(
        _ data: Data,
        decoder: JSONDecoder = IanuaAuthenticatorClient.makeDecoder()) throws -> [AuthenticatorChallenge]
    {
        try decoder.decode(IanuaAuthenticatorPendingResponse.self, from: data)
            .challenges
            .map(\.challenge)
    }

    func resolve(challengeId: String, decision: String, proof: AuthenticatorResolutionPayload) async throws {
        _ = try await self.request(
            path: "/api/authenticator/resolve",
            method: "POST",
            body: try JSONEncoder().encode(
                IanuaAuthenticatorResolveBody(id: challengeId, decision: decision, proof: proof)))
    }

    private func request(
        path: String,
        method: String = "GET",
        body: Data? = nil) async throws -> Data
    {
        IanuaSessionStore.restoreIfNeeded()
        var request = URLRequest(url: self.baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WADAPIError.unreachable }
            if http.statusCode == 401 { throw WADAPIError.unauthorized }
            if http.statusCode == 428 { throw IanuaAuthenticatorError.enrollmentRequired }
            guard (200...299).contains(http.statusCode) else {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                throw WADAPIError.server(
                    payload?["error"] as? String ?? "Errore Authenticator \(http.statusCode)")
            }
            return data
        } catch let error as WADAPIError {
            throw error
        } catch let error as IanuaAuthenticatorError {
            throw error
        } catch {
            throw WADAPIError.unreachable
        }
    }
}

@MainActor
@Observable
final class IanuaAuthenticatorModel {
    static let shared = IanuaAuthenticatorModel()

    var identity: AuthenticatorStore.Identity?
    var pendingChallenge: AuthenticatorChallenge?
    var errorText: String?
    var isLoading = false
    var isEnrolling = false
    var isResolving = false
    var enrollmentRequired = false

    func bootstrap() async {
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            let identity = try await AuthenticatorStore.shared.identity()
            try await IanuaAuthenticatorClient.shared.enroll(identity: identity, label: "iPhone Iànua")
            self.identity = identity
            self.enrollmentRequired = false
            try await self.refreshPending()
        } catch IanuaAuthenticatorError.enrollmentRequired {
            self.identity = try? await AuthenticatorStore.shared.identity()
            self.enrollmentRequired = true
            self.errorText = nil
        } catch {
            self.errorText = error.localizedDescription
        }
    }

    func refreshPending() async throws {
        guard let identity else { return }
        let challenges = try await IanuaAuthenticatorClient.shared.pending(personId: identity.personId)
        self.pendingChallenge = challenges.first
        self.errorText = nil
    }

    func enroll(totpCode: String) async {
        guard let identity else { return }
        self.isEnrolling = true
        defer { self.isEnrolling = false }
        do {
            try await IanuaAuthenticatorClient.shared.enroll(
                identity: identity,
                label: "iPhone Iànua",
                totpCode: totpCode)
            self.enrollmentRequired = false
            self.errorText = nil
            try await self.refreshPending()
        } catch {
            self.errorText = error.localizedDescription
        }
    }

    func resolve(decision: String, enteredCode: String) async {
        guard let challenge = self.pendingChallenge, let challengeId = challenge.id else {
            self.errorText = "Richiesta Authenticator non valida o scaduta."
            return
        }
        self.isResolving = true
        defer { self.isResolving = false }
        do {
            let proof = try await AuthenticatorStore.shared.makeResolution(
                challenge: challenge,
                enteredCode: enteredCode,
                decision: decision,
                authenticate: decision == "approve")
            try await IanuaAuthenticatorClient.shared.resolve(
                challengeId: challengeId,
                decision: decision,
                proof: proof)
            self.pendingChallenge = nil
            self.errorText = nil
        } catch {
            self.errorText = error.localizedDescription
        }
    }
}
