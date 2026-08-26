import SwiftUI
import UIKit
import UserNotifications

/// Pannello di diagnostica per le notifiche push, raggiungibile da
/// Impostazioni → Gateway → Diagnostica notifiche. Mostra lo stato di
/// registrazione APNs, permette una notifica di prova locale e un round-trip
/// reale, ed espone il log push così che i problemi siano diagnosticabili sul
/// campo (build TestFlight) senza Xcode collegato.
struct PushDebugView: View {
    @State private var authStatus: String = "…"
    @State private var logText: String = ""
    @State private var lastResult: String?

    private let deviceTokenKey = "push.apns.deviceTokenHex"
    private let notificationCenter: NotificationCentering = LiveNotificationCenter()

    var body: some View {
        List {
            Section("Stato") {
                self.row("Permesso notifiche", self.authStatus)
                self.row("Transport", PushBuildConfig.current.transport.rawValue)
                self.row("Ambiente APNs", PushBuildConfig.current.apnsEnvironment.rawValue)
                self.row("Distribuzione", PushBuildConfig.current.distribution.rawValue)
                self.row("APNs token", self.tokenState)
                self.row("Relay handle", self.relayHandleState)
            }

            Section("Test") {
                Button {
                    Task { await self.requestAuthorization() }
                } label: {
                    Label("Richiedi permesso notifiche", systemImage: "bell.badge")
                }

                Button {
                    Task { await self.sendLocalTest() }
                } label: {
                    Label("Invia notifica di prova (locale)", systemImage: "paperplane")
                }

                Button {
                    self.reregister()
                } label: {
                    Label("Ri-registra push (APNs)", systemImage: "arrow.clockwise")
                }

                if let result = self.lastResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Log push") {
                if self.pushLines.isEmpty {
                    Text("Nessun evento push registrato finora.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(self.pushLines)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("Diagnostica notifiche")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Aggiorna") { self.refresh() }
                    Button("Copia log completo") {
                        UIPasteboard.general.string = self.logText
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { self.refresh() }
        .task { await self.loadAuthStatus() }
    }

    // MARK: - Derived state

    private var tokenState: String {
        let token = UserDefaults.standard.string(forKey: self.deviceTokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return "assente" }
        let suffix = token.count > 6 ? String(token.suffix(6)) : token
        return "…\(suffix) (\(token.count / 2) byte)"
    }

    private var relayHandleState: String {
        PushRelayRegistrationStore.loadRegistrationState() != nil ? "presente" : "assente"
    }

    private var pushLines: String {
        self.logText
            .split(separator: "\n")
            .filter { $0.contains("push:") }
            .suffix(60)
            .joined(separator: "\n")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Actions

    private func refresh() {
        self.logText = GatewayDiagnostics.recentLogText()
    }

    private func loadAuthStatus() async {
        let status = await self.notificationCenter.authorizationStatus()
        self.authStatus = Self.describe(status)
    }

    private func requestAuthorization() async {
        do {
            let granted = try await self.notificationCenter.requestAuthorization(
                options: [.alert, .sound, .badge])
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            GatewayDiagnostics.log("push: authorization requested granted=\(granted)")
            self.lastResult = granted ? "Permesso concesso." : "Permesso negato."
        } catch {
            GatewayDiagnostics.log("push: authorization request FAILED error=\(error.localizedDescription)")
            self.lastResult = "Errore permesso: \(error.localizedDescription)"
        }
        await self.loadAuthStatus()
        self.refresh()
    }

    private func sendLocalTest() async {
        let status = await self.notificationCenter.authorizationStatus()
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            self.lastResult = "Permesso notifiche non concesso: premi prima “Richiedi permesso”."
            GatewayDiagnostics.log("push: local test skipped reason=not_authorized")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Iànua — notifica di prova"
        content.body = "Se vedi questo banner, le notifiche funzionano. \(Self.timestamp())"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(
            identifier: "ianua.push.debug.local.\(UUID().uuidString)",
            content: content,
            trigger: trigger)

        do {
            try await self.notificationCenter.add(request)
            GatewayDiagnostics.log("push: local test scheduled (3s)")
            self.lastResult = "Notifica di prova pianificata: arriva tra ~3s (metti l'app in background per vedere il banner)."
        } catch {
            GatewayDiagnostics.log("push: local test FAILED error=\(error.localizedDescription)")
            self.lastResult = "Errore invio prova: \(error.localizedDescription)"
        }
        self.refresh()
    }

    private func reregister() {
        UIApplication.shared.registerForRemoteNotifications()
        GatewayDiagnostics.log("push: manual re-register requested")
        self.lastResult = "Ri-registrazione APNs richiesta. Aggiorna il log tra qualche secondo."
    }

    // MARK: - Helpers

    private static func describe(_ status: NotificationAuthorizationStatus) -> String {
        switch status {
        case .authorized: "autorizzato"
        case .provisional: "provvisorio"
        case .ephemeral: "effimero"
        case .denied: "negato"
        case .notDetermined: "non richiesto"
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
