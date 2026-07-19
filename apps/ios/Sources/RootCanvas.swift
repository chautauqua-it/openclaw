import OpenClawProtocol
import SwiftUI
import UIKit

struct RootCanvas: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(GatewayConnectionController.self) private var gatewayController
    @Environment(VoiceWakeManager.self) private var voiceWake
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(VoiceWakePreferences.enabledKey) private var voiceWakeEnabled: Bool = false
    @AppStorage("screen.preventSleep") private var preventSleep: Bool = true
    @AppStorage("canvas.debugStatusEnabled") private var canvasDebugStatusEnabled: Bool = false
    @AppStorage("onboarding.requestID") private var onboardingRequestID: Int = 0
    @AppStorage("gateway.onboardingComplete") private var onboardingComplete: Bool = false
    @AppStorage("gateway.hasConnectedOnce") private var hasConnectedOnce: Bool = false
    @AppStorage("gateway.preferredStableID") private var preferredGatewayStableID: String = ""
    @AppStorage("gateway.manual.enabled") private var manualGatewayEnabled: Bool = false
    @AppStorage("gateway.manual.host") private var manualGatewayHost: String = ""
    @AppStorage("onboarding.quickSetupDismissed") private var quickSetupDismissed: Bool = false
    @State private var presentedSheet: PresentedSheet?
    @State private var voiceWakeToastText: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var showOnboarding: Bool = false
    @State private var onboardingAllowSkip: Bool = true
    @State private var didEvaluateOnboarding: Bool = false
    @State private var didAutoOpenSettings: Bool = false
    @State private var wadSiriLaunchSignal = WADSiriLaunchSignal.shared
    @State private var showSpockTalk: Bool = false

    private enum PresentedSheet: Identifiable {
        case wadChat
        case settings
        case agents
        case quickSetup

        var id: Int {
            switch self {
            case .wadChat: 0
            case .settings: 1
            case .agents: 2
            case .quickSetup: 3
            }
        }
    }

    enum StartupPresentationRoute: Equatable {
        case none
        case onboarding
        case settings
    }

    static func startupPresentationRoute(
        gatewayConnected: Bool,
        hasConnectedOnce: Bool,
        onboardingComplete: Bool,
        hasExistingGatewayConfig: Bool,
        shouldPresentOnLaunch: Bool) -> StartupPresentationRoute
    {
        if gatewayConnected {
            return .none
        }
        // On first run or explicit launch onboarding state, onboarding always wins.
        if shouldPresentOnLaunch || !hasConnectedOnce || !onboardingComplete {
            return .onboarding
        }
        // Settings auto-open is a recovery path for previously-connected installs only.
        if !hasExistingGatewayConfig {
            return .settings
        }
        return .none
    }

    static func shouldPresentQuickSetup(
        quickSetupDismissed: Bool,
        showOnboarding: Bool,
        hasPresentedSheet: Bool,
        gatewayConnected: Bool,
        hasExistingGatewayConfig: Bool,
        discoveredGatewayCount: Int) -> Bool
    {
        guard !quickSetupDismissed else { return false }
        guard !showOnboarding else { return false }
        guard !hasPresentedSheet else { return false }
        guard !gatewayConnected else { return false }
        // If a gateway target is already configured (manual or last-known), skip quick setup.
        guard !hasExistingGatewayConfig else { return false }
        return discoveredGatewayCount > 0
    }

    var body: some View {
        ZStack {
            CanvasContent(
                systemColorScheme: self.systemColorScheme,
                gatewayStatus: self.gatewayStatus,
                voiceWakeEnabled: self.voiceWakeEnabled,
                voiceWakeToastText: self.voiceWakeToastText,
                cameraHUDText: self.appModel.cameraHUDText,
                cameraHUDKind: self.appModel.cameraHUDKind,
                openChannels: {
                    self.openWADChannels()
                },
                openAgents: {
                    self.showSpockTalk = true
                },
                openSettings: {
                    self.presentedSheet = .settings
                },
                retryGatewayConnection: {
                    Task { await self.gatewayController.connectLastKnown() }
                })
                .preferredColorScheme(.dark)

            if self.appModel.cameraFlashNonce != 0 {
                CameraFlashOverlay(nonce: self.appModel.cameraFlashNonce)
            }
        }
        .gatewayTrustPromptAlert()
        .deepLinkAgentPromptAlert()
        .execApprovalPromptDialog()
        .sheet(item: self.$presentedSheet) { sheet in
            switch sheet {
            case .wadChat:
                WADNativeChatSheet()
            case .settings:
                SettingsTab()
                    .environment(self.appModel)
                    .environment(self.appModel.voiceWake)
                    .environment(self.gatewayController)
            case .agents:
                ChatSheet(
                    // Chat RPCs run on the operator session (read/write scopes).
                    gateway: self.appModel.operatorSession,
                    sessionKey: self.appModel.chatSessionKey,
                    agentName: self.appModel.activeAgentName,
                    userAccent: self.appModel.seamColor)
            case .quickSetup:
                GatewayQuickSetupSheet()
                    .environment(self.appModel)
                    .environment(self.gatewayController)
            }
        }
        .fullScreenCover(isPresented: self.$showSpockTalk) {
            SpockTalkView(accent: self.appModel.seamColor)
                .environment(self.appModel)
        }
        .fullScreenCover(isPresented: self.$showOnboarding) {
            OnboardingWizardView(
                allowSkip: self.onboardingAllowSkip,
                onClose: {
                    self.showOnboarding = false
                })
                .environment(self.appModel)
                .environment(self.appModel.voiceWake)
                .environment(self.gatewayController)
        }
        .onAppear {
            // TEMP repro hook: auto-open Spock talk (bypasses onboarding/quick setup).
            if ProcessInfo.processInfo.environment["SPOCK_TALK_AUTOOPEN"] == "1" {
                self.didEvaluateOnboarding = true
                self.didAutoOpenSettings = true
                self.quickSetupDismissed = true
                self.showSpockTalk = true
            }
        }
        .onAppear { self.updateIdleTimer() }
        .onAppear { self.updateHomeCanvasState() }
        .onAppear { self.evaluateOnboardingPresentation(force: false) }
        .onAppear { self.maybeAutoOpenSettings() }
        .onAppear { self.presentPendingWADSiriRoute() }
        .onChange(of: self.preventSleep) { _, _ in self.updateIdleTimer() }
        .onChange(of: self.scenePhase) { _, newValue in
            self.updateIdleTimer()
            self.updateHomeCanvasState()
            guard newValue == .active else { return }
            Task {
                await self.appModel.refreshGatewayOverviewIfConnected()
                await MainActor.run {
                    self.updateHomeCanvasState()
                }
            }
        }
        .onAppear { self.maybeShowQuickSetup() }
        .onChange(of: self.gatewayController.gateways.count) { _, _ in self.maybeShowQuickSetup() }
        .onAppear { self.updateCanvasDebugStatus() }
        .onChange(of: self.canvasDebugStatusEnabled) { _, _ in self.updateCanvasDebugStatus() }
        .onChange(of: self.appModel.gatewayStatusText) { _, _ in
            self.updateCanvasDebugStatus()
            self.updateHomeCanvasState()
        }
        .onChange(of: self.appModel.gatewayServerName) { _, _ in
            self.updateCanvasDebugStatus()
            self.updateHomeCanvasState()
        }
        .onChange(of: self.appModel.gatewayServerName) { _, newValue in
            if newValue != nil {
                self.showOnboarding = false
            }
        }
        .onChange(of: self.onboardingRequestID) { _, _ in
            self.evaluateOnboardingPresentation(force: true)
        }
        .onChange(of: self.appModel.gatewayRemoteAddress) { _, _ in
            self.updateCanvasDebugStatus()
            self.updateHomeCanvasState()
        }
        .onChange(of: self.appModel.homeCanvasRevision) { _, _ in
            self.updateHomeCanvasState()
        }
        .onChange(of: self.appModel.gatewayServerName) { _, newValue in
            if newValue != nil {
                self.onboardingComplete = true
                self.hasConnectedOnce = true
                OnboardingStateStore.markCompleted(mode: nil)
            }
            self.maybeAutoOpenSettings()
        }
        .onChange(of: self.appModel.openChatRequestID) { _, _ in
            self.presentedSheet = .agents
        }
        .onChange(of: self.wadSiriLaunchSignal.activationToken) { _, _ in
            self.presentPendingWADSiriRoute()
        }
        .onChange(of: self.voiceWake.lastTriggeredCommand) { _, newValue in
            guard let newValue else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            self.toastDismissTask?.cancel()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                self.voiceWakeToastText = trimmed
            }

            self.toastDismissTask = Task {
                try? await Task.sleep(nanoseconds: 2_300_000_000)
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.25)) {
                        self.voiceWakeToastText = nil
                    }
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            self.toastDismissTask?.cancel()
            self.toastDismissTask = nil
        }
    }

    private var gatewayStatus: StatusPill.GatewayState {
        GatewayStatusBuilder.build(appModel: self.appModel)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = (self.scenePhase == .active && self.preventSleep)
    }

    private func updateCanvasDebugStatus() {
        self.appModel.screen.setDebugStatusEnabled(self.canvasDebugStatusEnabled)
        guard self.canvasDebugStatusEnabled else { return }
        let title = self.appModel.gatewayDisplayStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = self.appModel.gatewayServerName ?? self.appModel.gatewayRemoteAddress
        self.appModel.screen.updateDebugStatus(title: title, subtitle: subtitle)
    }

    private func openWADChannels() {
        self.presentedSheet = .wadChat
    }

    private func presentPendingWADSiriRoute() {
        guard let route = self.wadSiriLaunchSignal.consumePendingRoute() else { return }
        switch route {
        case .agents:
            self.presentedSheet = .agents
        case .chat:
            self.presentedSheet = .wadChat
        case .spockTalk:
            if self.presentedSheet != nil {
                // SwiftUI non presenta un fullScreenCover mentre un sheet è ancora
                // in dismissione: piccolo ritardo per lasciare chiudere l'animazione.
                self.presentedSheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self.showSpockTalk = true
                }
            } else {
                self.showSpockTalk = true
            }
        }
    }

    private func updateHomeCanvasState() {
        let payload = self.makeHomeCanvasPayload()
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            self.appModel.screen.updateHomeCanvasState(json: nil)
            return
        }
        self.appModel.screen.updateHomeCanvasState(json: json)
    }

    private func makeHomeCanvasPayload() -> HomeCanvasPayload {
        let gatewayName = self.normalized(self.appModel.gatewayServerName)
        let gatewayAddress = self.normalized(self.appModel.gatewayRemoteAddress)
        let gatewayLabel = gatewayName ?? gatewayAddress ?? "Gateway"
        let activeAgentID = self.resolveActiveAgentID()
        let agents = self.homeCanvasAgents(activeAgentID: activeAgentID)

        switch self.gatewayStatus {
        case .connected:
            return HomeCanvasPayload(
                gatewayState: "connected",
                eyebrow: "Connesso a \(gatewayLabel)",
                title: "WAD è pronto",
                subtitle:
                "Chat apre i canali WAD. Agenti apre la conversazione diretta con l'agente selezionato.",
                gatewayLabel: gatewayLabel,
                activeAgentName: self.appModel.activeAgentName,
                activeAgentBadge: agents.first(where: { $0.isActive })?.badge ?? "OC",
                activeAgentCaption: "Agente selezionato",
                agentCount: agents.count,
                agents: Array(agents.prefix(6)),
                footer: "La vista si aggiorna quando l'app torna in primo piano.")
        case .connecting:
            return HomeCanvasPayload(
                gatewayState: "connecting",
                eyebrow: "Riconnessione",
                title: "WAD si sta riallineando",
                subtitle:
                "La sessione gateway sta tornando online. "
                    + "Le scorciatoie degli agenti si sistemano automaticamente tra poco.",
                gatewayLabel: gatewayLabel,
                activeAgentName: self.appModel.activeAgentName,
                activeAgentBadge: "OC",
                activeAgentCaption: "Sessione gateway in corso",
                agentCount: agents.count,
                agents: Array(agents.prefix(4)),
                footer: "Se il gateway è raggiungibile, la riconnessione si chiude senza interventi.")
        case .error, .disconnected:
            return HomeCanvasPayload(
                gatewayState: self.gatewayStatus == .error ? "error" : "offline",
                eyebrow: "WAD",
                title: "Il telefono resta pronto quando serve",
                subtitle:
                "Abbina questo iPhone al gateway per usare canali, agenti e strumenti dal telefono.",
                gatewayLabel: gatewayLabel,
                activeAgentName: "Main",
                activeAgentBadge: "OC",
                activeAgentCaption: "Connetti per caricare gli agenti",
                agentCount: agents.count,
                agents: Array(agents.prefix(4)),
                footer:
                "Quando è connesso, il gateway può svegliare il telefono solo quando serve.")
        }
    }

    private func resolveActiveAgentID() -> String {
        let selected = self.normalized(self.appModel.selectedAgentId) ?? ""
        if !selected.isEmpty {
            return selected
        }
        return self.resolveDefaultAgentID()
    }

    private func resolveDefaultAgentID() -> String {
        self.normalized(self.appModel.gatewayDefaultAgentId) ?? ""
    }

    private func homeCanvasAgents(activeAgentID: String) -> [HomeCanvasAgentCard] {
        let defaultAgentID = self.resolveDefaultAgentID()
        let cards = self.appModel.gatewayAgents.map { agent -> HomeCanvasAgentCard in
            let isActive = !activeAgentID.isEmpty && agent.id == activeAgentID
            let isDefault = !defaultAgentID.isEmpty && agent.id == defaultAgentID
            return HomeCanvasAgentCard(
                id: agent.id,
                name: self.homeCanvasName(for: agent),
                badge: self.homeCanvasBadge(for: agent),
                caption: isActive ? "Active on this phone" : (isDefault ? "Default agent" : "Ready"),
                isActive: isActive)
        }

        return cards.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func homeCanvasName(for agent: AgentSummary) -> String {
        self.normalized(agent.name) ?? agent.id
    }

    private func homeCanvasBadge(for agent: AgentSummary) -> String {
        if let identity = agent.identity,
           let emoji = identity["emoji"]?.value as? String,
           let normalizedEmoji = self.normalized(emoji)
        {
            return normalizedEmoji
        }
        let words = self.homeCanvasName(for: agent)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(2)
        let initials = words.compactMap(\.first).map(String.init).joined()
        if !initials.isEmpty {
            return initials.uppercased()
        }
        return "OC"
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func evaluateOnboardingPresentation(force: Bool) {
        if force {
            self.onboardingAllowSkip = true
            self.showOnboarding = true
            return
        }

        guard !self.didEvaluateOnboarding else { return }
        self.didEvaluateOnboarding = true
        let route = Self.startupPresentationRoute(
            gatewayConnected: self.appModel.gatewayServerName != nil,
            hasConnectedOnce: self.hasConnectedOnce,
            onboardingComplete: self.onboardingComplete,
            hasExistingGatewayConfig: self.hasExistingGatewayConfig(),
            shouldPresentOnLaunch: OnboardingStateStore.shouldPresentOnLaunch(appModel: self.appModel))
        switch route {
        case .none:
            break
        case .onboarding:
            self.onboardingAllowSkip = true
            self.showOnboarding = true
        case .settings:
            self.didAutoOpenSettings = true
            self.presentedSheet = .settings
        }
    }

    private func hasExistingGatewayConfig() -> Bool {
        if self.appModel.activeGatewayConnectConfig != nil { return true }
        if GatewaySettingsStore.loadLastGatewayConnection() != nil { return true }

        let preferredStableID = self.preferredGatewayStableID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredStableID.isEmpty { return true }

        let manualHost = self.manualGatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.manualGatewayEnabled && !manualHost.isEmpty
    }

    private func maybeAutoOpenSettings() {
        guard !self.didAutoOpenSettings else { return }
        guard !self.showOnboarding else { return }
        let route = Self.startupPresentationRoute(
            gatewayConnected: self.appModel.gatewayServerName != nil,
            hasConnectedOnce: self.hasConnectedOnce,
            onboardingComplete: self.onboardingComplete,
            hasExistingGatewayConfig: self.hasExistingGatewayConfig(),
            shouldPresentOnLaunch: false)
        guard route == .settings else { return }
        self.didAutoOpenSettings = true
        self.presentedSheet = .settings
    }

    private func maybeShowQuickSetup() {
        let shouldPresent = Self.shouldPresentQuickSetup(
            quickSetupDismissed: self.quickSetupDismissed,
            showOnboarding: self.showOnboarding,
            hasPresentedSheet: self.presentedSheet != nil,
            gatewayConnected: self.appModel.gatewayServerName != nil,
            hasExistingGatewayConfig: self.hasExistingGatewayConfig(),
            discoveredGatewayCount: self.gatewayController.gateways.count)
        guard shouldPresent else { return }
        self.presentedSheet = .quickSetup
    }
}

private struct HomeCanvasPayload: Codable {
    var gatewayState: String
    var eyebrow: String
    var title: String
    var subtitle: String
    var gatewayLabel: String
    var activeAgentName: String
    var activeAgentBadge: String
    var activeAgentCaption: String
    var agentCount: Int
    var agents: [HomeCanvasAgentCard]
    var footer: String
}

private struct HomeCanvasAgentCard: Codable {
    var id: String
    var name: String
    var badge: String
    var caption: String
    var isActive: Bool
}

private struct CanvasContent: View {
    @Environment(NodeAppModel.self) private var appModel
    @AppStorage("talk.enabled") private var talkEnabled: Bool = false
    @State private var showGatewayActions: Bool = false
    @State private var showGatewayProblemDetails: Bool = false
    var systemColorScheme: ColorScheme
    var gatewayStatus: StatusPill.GatewayState
    var voiceWakeEnabled: Bool
    var voiceWakeToastText: String?
    var cameraHUDText: String?
    var cameraHUDKind: NodeAppModel.CameraHUDKind?
    var openChannels: () -> Void
    var openAgents: () -> Void
    var openSettings: () -> Void
    var retryGatewayConnection: () -> Void

    private var brightenButtons: Bool {
        self.systemColorScheme == .light
    }

    private var talkActive: Bool {
        self.appModel.talkMode.isEnabled || self.talkEnabled
    }

    var body: some View {
        ZStack {
            ScreenTab()
        }
        .overlay(alignment: .center) {
            if self.talkActive {
                TalkOrbOverlay()
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HomeToolbar(
                gateway: self.gatewayStatus,
                voiceWakeEnabled: self.voiceWakeEnabled,
                activity: self.statusActivity,
                brighten: self.brightenButtons,
                talkActive: self.talkActive,
                talkTint: self.appModel.seamColor,
                onStatusTap: {
                    if self.gatewayStatus == .connected {
                        self.showGatewayActions = true
                    } else if self.appModel.lastGatewayProblem != nil {
                        self.showGatewayProblemDetails = true
                    } else {
                        self.openSettings()
                    }
                },
                onChannelsTap: {
                    self.openChannels()
                },
                onAgentsTap: {
                    self.openAgents()
                },
                onSettingsTap: {
                    self.openSettings()
                })
        }
        .overlay(alignment: .top) {
            if let gatewayProblem = self.appModel.lastGatewayProblem,
               self.gatewayStatus != .connected
            {
                GatewayProblemBanner(
                    problem: gatewayProblem,
                    primaryActionTitle: gatewayProblem.retryable ? "Retry" : "Open Settings",
                    onPrimaryAction: {
                        if gatewayProblem.retryable {
                            self.retryGatewayConnection()
                        } else {
                            self.openSettings()
                        }
                    },
                    onShowDetails: {
                        self.showGatewayProblemDetails = true
                    })
                    .padding(.horizontal, 12)
                    .safeAreaPadding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            if let voiceWakeToastText, !voiceWakeToastText.isEmpty {
                VoiceWakeToast(
                    command: voiceWakeToastText,
                    brighten: self.brightenButtons)
                    .padding(.leading, 10)
                    .safeAreaPadding(.top, self.appModel.lastGatewayProblem == nil ? 58 : 132)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .gatewayActionsDialog(
            isPresented: self.$showGatewayActions,
            onDisconnect: { self.appModel.disconnectGateway() },
            onOpenSettings: { self.openSettings() })
        .sheet(isPresented: self.$showGatewayProblemDetails) {
            if let gatewayProblem = self.appModel.lastGatewayProblem {
                GatewayProblemDetailsSheet(
                    problem: gatewayProblem,
                    primaryActionTitle: "Open Settings",
                    onPrimaryAction: {
                        self.openSettings()
                    })
            }
        }
        .onAppear {
            // Keep the runtime talk state aligned with persisted toggle state on cold launch.
            if self.talkEnabled != self.appModel.talkMode.isEnabled {
                self.appModel.setTalkEnabled(self.talkEnabled)
            }
        }
    }

    private var statusActivity: StatusPill.Activity? {
        StatusActivityBuilder.build(
            appModel: self.appModel,
            voiceWakeEnabled: self.voiceWakeEnabled,
            cameraHUDText: self.cameraHUDText,
            cameraHUDKind: self.cameraHUDKind)
    }
}

private struct CameraFlashOverlay: View {
    var nonce: Int

    @State private var opacity: CGFloat = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        Color.white
            .opacity(self.opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: self.nonce) { _, _ in
                self.task?.cancel()
                self.task = Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.08)) {
                        self.opacity = 0.85
                    }
                    try? await Task.sleep(nanoseconds: 110_000_000)
                    withAnimation(.easeOut(duration: 0.32)) {
                        self.opacity = 0
                    }
                }
            }
    }
}
