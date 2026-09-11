import SwiftUI

@MainActor
final class IanuaProvisioningModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case working
        case done(tenant: String, user: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    func startScanning() {
        self.phase = .scanning
    }

    func cancelScanning() {
        self.phase = .idle
    }

    func scannerFailed(_ message: String) {
        self.phase = .failed(message)
    }

    /// Un QR letto o un link `ianua://` arrivato dall'esterno: stesso percorso,
    /// perché la decisione di attivare è comunque della persona che ha aperto
    /// questa schermata.
    func submit(_ raw: String) async {
        guard let link = IanuaProvisionLink.parse(raw) else {
            self.phase = .failed(IanuaProvisionError.notAnIanuaCode.localizedDescription)
            return
        }
        await self.submit(link)
    }

    func submit(_ link: IanuaProvisionLink) async {
        self.phase = .working
        do {
            let claim = try await IanuaProvisioningClient.shared.claim(link)
            self.phase = .done(tenant: claim.tenant.nome, user: claim.user.nome)
        } catch let error as IanuaProvisionError {
            self.phase = .failed(error.localizedDescription)
        } catch {
            self.phase = .failed(error.localizedDescription)
        }
    }
}

/// Attivazione del dispositivo con il QR coniato dall'operatore.
///
/// Il token del QR vale dieci minuti ed è monouso: la schermata non lo conserva
/// e non lo riprova da sola. Se qualcosa va storto la persona torna
/// dall'operatore per un codice nuovo, che è esattamente la garanzia che rende
/// innocuo un QR fotografato.
struct IanuaProvisioningView: View {
    /// Chiamata quando la sessione è aperta: chi presenta la schermata decide
    /// cosa mostrare dopo.
    var onActivated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = IanuaProvisioningModel()
    @ObservedObject private var inbox = IanuaProvisioningInbox.shared

    var body: some View {
        Group {
            switch self.model.phase {
            case .idle:
                self.intro
            case .scanning:
                self.scanner
            case .working:
                ProgressView("Attivo questo iPhone...")
            case let .done(tenant, user):
                self.success(tenant: tenant, user: user)
            case let .failed(message):
                self.failure(message)
            }
        }
        .navigationTitle("Attiva dispositivo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Annulla") { self.dismiss() }
            }
        }
        .task {
            // Un link `ianua://` aperto mentre l'app era chiusa aspetta qui:
            // si consuma solo ora che la schermata è davanti alla persona.
            if let pending = self.inbox.take() {
                await self.model.submit(pending)
            }
        }
        .onChange(of: self.inbox.pending) { _, pending in
            guard let pending else { return }
            _ = self.inbox.take()
            Task { await self.model.submit(pending) }
        }
    }

    private var intro: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Inquadra il QR di attivazione")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
            Text(
                "Chiedi all'operatore Iànua il codice di attivazione per il tuo account. "
                    + "Vale dieci minuti e si può usare una volta sola.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                self.model.startScanning()
            } label: {
                Text("Inquadra il QR").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            IanuaQRScannerView(
                onCode: { payload in
                    Task { await self.model.submit(payload) }
                },
                onFailure: { message in
                    self.model.scannerFailed(message)
                })
                .ignoresSafeArea()
            Text("Inquadra il QR mostrato dall'operatore")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(.bottom, 40)
        }
    }

    private func success(tenant: String, user: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Dispositivo attivato")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("\(user) — \(tenant)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                self.onActivated()
                self.dismiss()
            } label: {
                Text("Entra in Iànua").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Attivazione non riuscita")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                self.model.startScanning()
            } label: {
                Text("Riprova con un altro codice").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 32)
            Spacer()
        }
    }
}
