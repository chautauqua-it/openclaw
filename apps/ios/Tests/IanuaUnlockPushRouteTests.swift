import Foundation
import Testing
import UserNotifications
@testable import OpenClaw

struct IanuaUnlockPushRouteTests {
    private let unlockUserInfo: [AnyHashable: Any] = [
        "openclaw": ["kind": "push.test", "nodeId": "node-1"],
    ]
    private let unlockTitle = "Iànua · Sblocco richiesto"

    @Test func `matches bridge unlock push`() {
        #expect(IanuaUnlockPushRoute.isUnlockPush(
            userInfo: self.unlockUserInfo,
            title: self.unlockTitle))
    }

    @Test func `matches connected node local notification payload`() {
        // Nodo connesso al gateway: la push arriva come notifica locale da
        // handleSystemNotify, che deve allegare lo stesso kind del canale APNs.
        let userInfo: [AnyHashable: Any] = [
            "openclaw": ["kind": IanuaUnlockPushRoute.pushTestKind],
        ]
        #expect(IanuaUnlockPushRoute.isUnlockPush(userInfo: userInfo, title: self.unlockTitle))
    }

    @Test func `title marker is case insensitive`() {
        #expect(IanuaUnlockPushRoute.isUnlockPush(
            userInfo: self.unlockUserInfo,
            title: "IÀNUA · SBLOCCO RICHIESTO"))
    }

    @Test func `rejects other push kinds`() {
        let userInfo: [AnyHashable: Any] = [
            "openclaw": ["kind": "exec.approval.requested", "approvalId": "abc"],
        ]
        #expect(!IanuaUnlockPushRoute.isUnlockPush(userInfo: userInfo, title: self.unlockTitle))
    }

    @Test func `rejects missing open claw payload`() {
        #expect(!IanuaUnlockPushRoute.isUnlockPush(userInfo: [:], title: self.unlockTitle))
    }

    @Test func `rejects test push without unlock title`() {
        #expect(!IanuaUnlockPushRoute.isUnlockPush(
            userInfo: self.unlockUserInfo,
            title: "OpenClaw"))
    }

    @Test func `routes only default tap action`() {
        #expect(IanuaUnlockPushRoute.shouldRoute(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: self.unlockUserInfo,
            title: self.unlockTitle))
        #expect(!IanuaUnlockPushRoute.shouldRoute(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: self.unlockUserInfo,
            title: self.unlockTitle))
    }
}
