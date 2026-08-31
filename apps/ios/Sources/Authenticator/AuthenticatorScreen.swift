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
    @Environment(NodeAppModel.self) private var appModel: NodeAppModel

    @State private var identity: AuthenticatorStore.Identity?
    @State private var identityErrorText: String?
    @State private var isSearching = false
    @State private var searchOutcomeText: String?

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
        .task { await self.loadIdentity() }
    }

    private var pendingState: AuthenticatorScreenPendingState {
        .resolve(
            challenge: self.appModel.pendingExecApprovalPrompt?.authenticator,
            hasPrompt: self.appModel.pendingExecApprovalPrompt != nil,
            operatorConnected: self.appModel.isOperatorConnected)
    }

    @ViewBuilder
    private var pendingSection: some View {
        switch self.pendingState {
        case let .challenge(challenge):
            AuthenticatorApprovalView(
                challenge: challenge,
                isResolving: self.appModel.pendingExecApprovalPromptResolving,
                errorText: self.appModel.pendingExecApprovalPromptErrorText,
                onApprove: { code in
                    Task {
                        await self.appModel.resolvePendingAuthenticatorPrompt(
                            decision: "approve",
                            enteredCode: code)
                    }
                },
                onDeny: { code in
                    Task {
                        await self.appModel.resolvePendingAuthenticatorPrompt(
                            decision: "deny",
                            enteredCode: code)
                    }
                },
                onCancel: { self.appModel.dismissPendingExecApprovalPrompt() })
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
        if let identity {
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
        } else if let identityErrorText {
            Text(identityErrorText)
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

    private func loadIdentity() async {
        do {
            self.identity = try await AuthenticatorStore.shared.identity()
            self.identityErrorText = nil
        } catch {
            self.identityErrorText = error.localizedDescription
        }
    }

    private func searchPending() async {
        self.isSearching = true
        self.searchOutcomeText = nil
        await self.appModel.recoverPendingExecApprovalPromptsOnConnect()
        self.isSearching = false
        if self.appModel.pendingExecApprovalPrompt == nil {
            self.searchOutcomeText = "Nessuna richiesta in sospeso trovata sul gateway."
        }
    }
}
