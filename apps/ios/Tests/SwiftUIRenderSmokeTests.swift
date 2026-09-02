import OpenClawKit
import SwiftUI
import Testing
import UIKit
@testable import OpenClaw

struct SwiftUIRenderSmokeTests {
    @MainActor private static func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    @Test @MainActor func `status pill connecting builds A view hierarchy`() {
        let root = StatusPill(gateway: .connecting, voiceWakeEnabled: true, brighten: true) {}
        _ = Self.host(root)
    }

    @Test @MainActor func `status pill disconnected builds A view hierarchy`() {
        let root = StatusPill(gateway: .disconnected, voiceWakeEnabled: false) {}
        _ = Self.host(root)
    }

    @Test @MainActor func `settings tab builds A view hierarchy`() {
        let appModel = NodeAppModel()
        let gatewayController = GatewayConnectionController(appModel: appModel, startDiscovery: false)

        let root = SettingsTab()
            .environment(appModel)
            .environment(appModel.voiceWake)
            .environment(gatewayController)

        _ = Self.host(root)
    }

    @Test @MainActor func `root canvas builds A view hierarchy`() {
        let appModel = NodeAppModel()
        let gatewayController = GatewayConnectionController(appModel: appModel, startDiscovery: false)

        let root = RootCanvas()
            .environment(appModel)
            .environment(appModel.voiceWake)
            .environment(gatewayController)

        _ = Self.host(root)
    }

    @Test @MainActor func `voice tab builds A view hierarchy`() {
        let appModel = NodeAppModel()

        let root = VoiceTab()
            .environment(appModel)
            .environment(appModel.voiceWake)

        _ = Self.host(root)
    }

    @Test @MainActor func `voice wake words view builds A view hierarchy`() {
        let appModel = NodeAppModel()
        let root = NavigationStack { VoiceWakeWordsSettingsView() }
            .environment(appModel)
        _ = Self.host(root)
    }

    @Test @MainActor func `chat sheet builds A view hierarchy`() {
        let appModel = NodeAppModel()
        let gateway = GatewayNodeSession()
        let root = ChatSheet(gateway: gateway, sessionKey: "test")
            .environment(appModel)
            .environment(appModel.voiceWake)
        _ = Self.host(root)
    }

    @Test @MainActor func `voice wake toast builds A view hierarchy`() {
        let root = VoiceWakeToast(command: "openclaw: do something")
        _ = Self.host(root)
    }
}
