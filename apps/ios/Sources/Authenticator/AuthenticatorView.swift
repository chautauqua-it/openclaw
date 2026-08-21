import SwiftUI

struct AuthenticatorApprovalView: View {
    let challenge: AuthenticatorChallenge
    let isResolving: Bool
    let errorText: String?
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void
    let onCancel: () -> Void

    @State private var enteredCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Conferma azione critica")
                .font(.headline)
            Text("Il telefono può solo approvare o negare una richiesta già avviata da un altro dispositivo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                self.row("Target", self.challenge.target)
                self.row("Azione", self.challenge.action.actionId)
                self.row("Parametri", self.challenge.parameterSummary)
                self.row("Tenant", self.challenge.action.tenant)
                self.row("Ambiente", self.challenge.action.environment)
                self.row("Audience", self.challenge.action.audience)
                self.row("Dispositivo iniziatore", self.challenge.initiatorDeviceId)
                self.row("Hash richiesta", self.challenge.action.requestHash)
            }

            TextField("Codice di \(self.challenge.matchCodeDigits) cifre", text: self.$enteredCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .onChange(of: self.enteredCode) { _, value in
                    self.enteredCode = String(value.filter(\.isNumber).prefix(self.challenge.matchCodeDigits))
                }

            if let errorText, !errorText.isEmpty {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }

            if self.isResolving {
                HStack { ProgressView(); Text("Verifica in corso…") }
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Button("Approva") { self.onApprove(self.enteredCode) }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!self.canResolve)

            HStack {
                Button("Nega", role: .destructive) { self.onDeny(self.enteredCode) }
                    .buttonStyle(.bordered)
                    .disabled(!self.canResolve)
                Button("Annulla", role: .cancel, action: self.onCancel)
                    .buttonStyle(.bordered)
                    .disabled(self.isResolving)
            }
            .frame(maxWidth: .infinity)
        }
        .statusGlassCard(brighten: false, verticalPadding: 18, horizontalPadding: 18)
    }

    private var canResolve: Bool {
        AuthenticatorUIState.resolve(
            challenge: self.challenge,
            code: self.enteredCode,
            resolving: self.isResolving) == .ready
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.footnote).textSelection(.enabled)
        }
    }
}
