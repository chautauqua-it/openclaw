import SwiftUI
import UIKit

struct AuthenticatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AuthenticatorStore()
    @State private var showScanner = false
    @State private var showManual = false
    @State private var manualURI = ""
    @State private var errorText: String?

    var body: some View {
        List {
            if self.store.accounts.isEmpty {
                ContentUnavailableView(
                    "Nessun codice",
                    systemImage: "key.viewfinder",
                    description: Text("Scansiona il QR TOTP del servizio da proteggere."))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ForEach(self.store.accounts) { account in
                        AuthenticatorCodeRow(account: account, now: context.date)
                    }
                    .onDelete(perform: self.store.remove)
                }
            }
        }
        .navigationTitle("Authenticator")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Scansiona QR", systemImage: "qrcode.viewfinder") { self.showScanner = true }
                    Button("Incolla chiave di configurazione", systemImage: "doc.on.clipboard") {
                        self.showManual = true
                    }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: self.$showScanner) {
            NavigationStack {
                AuthenticatorQRScanner { value in
                    self.showScanner = false
                    self.importValue(value)
                }
                .navigationTitle("Scansiona QR")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla") { self.showScanner = false }
                    }
                }
            }
        }
        .alert("Aggiungi account", isPresented: self.$showManual) {
            TextField("otpauth://totp/…", text: self.$manualURI)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Annulla", role: .cancel) { self.manualURI = "" }
            Button("Aggiungi") {
                let value = self.manualURI
                self.manualURI = ""
                self.importValue(value)
            }
        } message: { Text("Incolla l’URI otpauth fornito dal servizio.") }
        .alert("Impossibile aggiungere l’account", isPresented: Binding(
            get: { self.errorText != nil },
            set: { if !$0 { self.errorText = nil } }))
        { Button("OK", role: .cancel) {} } message: { Text(self.errorText ?? "Errore sconosciuto") }
            .privacySensitive()
            .overlay {
                if self.scenePhase != .active {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                }
            }
    }

    private func importValue(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            self.errorText = TOTPError.invalidURI.localizedDescription
            return
        }
        do { try self.store.add(uri: url) } catch { self.errorText = error.localizedDescription }
    }
}

private struct AuthenticatorCodeRow: View {
    let account: TOTPAccount
    let now: Date

    var body: some View {
        let code = (try? TOTP.code(for: self.account, at: self.now)) ?? "------"
        let remaining = TOTP.secondsRemaining(for: self.account, at: self.now)
        Button {
            UIPasteboard.general.string = code
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.account.displayIssuer).font(.headline)
                    Text(self.account.name).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Self.grouped(code))
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                    Text("Scade tra \(remaining)s").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(self.account.displayIssuer), \(self.account.name), codice \(code)")
        .accessibilityHint("Copia il codice")
    }

    private static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
