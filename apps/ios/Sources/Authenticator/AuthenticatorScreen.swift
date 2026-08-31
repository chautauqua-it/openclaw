import SwiftUI

enum AuthenticatorScreenPendingState: Equatable {
    case challenge(AuthenticatorChallenge)
    case foreignPrompt
    case idle(canSearch: Bool)

    static func resolve(
        challenge: AuthenticatorChallenge?,
        hasPrompt: Bool,
        operatorConnected: Bool) -> Self
    {
        if let challenge { return .challenge(challenge) }
        if hasPrompt { return .foreignPrompt }
        return .idle(canSearch: operatorConnected)
    }
}

/// Schermata Authenticator dedicata, fuori dalla chat: mostra l'identità di
/// firma di questo dispositivo e permette di ritrovare una richiesta di
/// number matching pendente anche se la card automatica è stata chiusa o
/// non è mai apparsa (app riaperta, push perso, reconnect).
struct AuthenticatorScreen: View {
    @State private var model = IanuaAuthenticatorModel.shared
    @State private var isSearching = false
    @State private var searchOutcomeText: String?
    @State private var enrollmentCode = ""

    var body: some View {
        List {
            Section("Richiesta in attesa") {
                self.pendingSection
            }
            Section("Identità di questo dispositivo") {
                self.identitySection
            }
        }
        .navigationTitle("Authenticator")
        .task { await self.model.bootstrap() }
    }

    private var pendingState: AuthenticatorScreenPendingState {
        .resolve(
            challenge: self.model.pendingChallenge,
            hasPrompt: false,
            operatorConnected: self.model.identity != nil)
    }

    @ViewBuilder
    private var pendingSection: some View {
        switch self.pendingState {
        case let .challenge(challenge):
            AuthenticatorApprovalView(
                challenge: challenge,
                isResolving: self.model.isResolving,
                errorText: self.model.errorText,
                onApprove: { code in
                    Task {
                        await self.model.resolve(decision: "approve", enteredCode: code)
                    }
                },
                onDeny: { code in
                    Task {
                        await self.model.resolve(decision: "deny", enteredCode: code)
                    }
                },
                onCancel: { self.model.pendingChallenge = nil })
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        case .foreignPrompt:
            Text("C'è una richiesta exec in attesa senza number matching: usa la card sulla schermata principale.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .idle(canSearch):
            Text("Nessuna richiesta Authenticator in attesa su questo dispositivo.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let searchOutcomeText = self.searchOutcomeText {
                Text(searchOutcomeText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await self.searchPending() }
            } label: {
                if self.isSearching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Ricerca in corso…")
                    }
                } else {
                    Text("Cerca richieste in sospeso")
                }
            }
            .disabled(!canSearch || self.isSearching)
            if !canSearch {
                Text("Sessione operatore non connessa: riconnetti il gateway per cercare richieste.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        if let identity = self.model.identity {
            VStack(alignment: .leading, spacing: 2) {
                Text("Person ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(identity.personId)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            #if targetEnvironment(simulator)
            Text("Chiave software di simulatore: non valida per approvazioni di produzione.")
                .font(.footnote)
                .foregroundStyle(.orange)
            #else
            Text("Chiave privata protetta da Secure Enclave: non lascia mai questo dispositivo.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
            if self.model.enrollmentRequired {
                SecureField("Codice TOTP a 6 cifre", text: self.$enrollmentCode)
                    .keyboardType(.numberPad)
                Button {
                    Task {
                        await self.model.enroll(totpCode: self.enrollmentCode)
                        if !self.model.enrollmentRequired { self.enrollmentCode = "" }
                    }
                } label: {
                    if self.model.isEnrolling {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Attivazione…")
                        }
                    } else {
                        Text("Attiva questo iPhone")
                    }
                }
                .disabled(
                    self.model.isEnrolling ||
                        self.enrollmentCode.count != 6 ||
                        !self.enrollmentCode.allSatisfy(\.isNumber))
                Text("Il primo enrollment richiede un TOTP fresco; la chiave privata resta nella Secure Enclave.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let errorText = self.model.errorText {
            Text(errorText)
                .font(.footnote)
                .foregroundStyle(.red)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Caricamento identità…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func searchPending() async {
        self.isSearching = true
        self.searchOutcomeText = nil
        do {
            try await self.model.refreshPending()
        } catch {
            self.model.errorText = error.localizedDescription
        }
        self.isSearching = false
        if self.model.pendingChallenge == nil {
            self.searchOutcomeText = "Nessuna richiesta in sospeso trovata su Iànua."
        }
    }
}
