@MainActor
public protocol ReminderNotificationAuthorizationRequester: AnyObject {
    func requestAuthorization() async -> Bool
}

@MainActor
public final class ReminderNotificationAuthorizationGate {
    private var authorizationRequested = false
    private var authorizationGranted = false

    public init() {}

    public func allowsPosting(
        using requester: any ReminderNotificationAuthorizationRequester
    ) async -> Bool {
        if !authorizationRequested {
            authorizationRequested = true
            authorizationGranted = await requester.requestAuthorization()
        }
        return authorizationGranted
    }
}
