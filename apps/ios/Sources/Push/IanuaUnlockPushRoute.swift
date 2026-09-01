import Foundation
import Observation
@preconcurrency import UserNotifications

/// Riconosce le push "Sblocco richiesto" del ponte Authenticator Iànua.
///
/// Il gateway invia le push del ponte con kind fisso `push.test` (unico canale
/// alert generico esposto dalla CLI `openclaw nodes push`), quindi il routing
/// avviene sulla convenzione di titolo concordata col server Iànua: il titolo
/// della coda `authenticator_push_queue` contiene sempre "Sblocco richiesto".
/// In caso di mancato match non succede nulla: il tap apre l'app come prima.
enum IanuaUnlockPushRoute {
    static let pushTestKind = "push.test"
    static let titleMarker = "Sblocco richiesto"

    static func isUnlockPush(userInfo: [AnyHashable: Any], title: String) -> Bool {
        guard ExecApprovalNotificationBridge.payloadKind(userInfo: userInfo) == self.pushTestKind else {
            return false
        }
        return title.range(of: self.titleMarker, options: [.caseInsensitive]) != nil
    }

    static func shouldRoute(actionIdentifier: String, userInfo: [AnyHashable: Any], title: String) -> Bool {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return false }
        return self.isUnlockPush(userInfo: userInfo, title: title)
    }
}

/// Stato condiviso di presentazione della schermata Authenticator: il tap
/// sulla notifica lo arma (anche a freddo, prima che la UI esista) e il root
/// lo consuma presentando la sheet appena la scena è pronta.
@MainActor
@Observable
final class AuthenticatorPresentation {
    static let shared = AuthenticatorPresentation()

    var isPresented = false

    func requestPresentation() {
        self.isPresented = true
    }
}
