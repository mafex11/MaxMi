import Foundation
import UserNotifications
import MaxMiActivity

@MainActor
final class UNUserNotificationCenterNotifier: NSObject, ReminderNotifier, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let onNotificationClick: @MainActor () -> Void
    private let authorizationGate = ReminderNotificationAuthorizationGate()

    init(
        center: UNUserNotificationCenter = .current(),
        onNotificationClick: @escaping @MainActor () -> Void
    ) {
        self.center = center
        self.onNotificationClick = onNotificationClick
        super.init()
        center.delegate = self
    }

    func post(id: String, title: String, body: String) async -> ReminderPostOutcome {
        let requester = UserNotificationAuthorizationRequester(center: center)
        let authorizationOutcome = await authorizationGate.postOutcome(using: requester)
        guard authorizationOutcome == .posted else { return authorizationOutcome }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["actionItemID": id]
        let request = UNNotificationRequest(
            identifier: "maxmi-reminder-\(id)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return .posted
        } catch {
            return .failed
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        _ = center
        _ = response
        Task { @MainActor [onNotificationClick] in
            onNotificationClick()
        }
        completionHandler()
    }
}

@MainActor
private final class UserNotificationAuthorizationRequester: ReminderNotificationAuthorizationRequester {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
