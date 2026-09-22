@MainActor
public protocol ReminderNotificationAuthorizationRequester: AnyObject {
    func requestAuthorization() async -> Bool
}

@MainActor
public final class ReminderNotificationAuthorizationGate {
    private var authorizationRequested = false
    private var authorizationGranted = false

    public init() {}

    public func postOutcome(
        using requester: any ReminderNotificationAuthorizationRequester
    ) async -> ReminderPostOutcome {
        if !authorizationRequested {
            authorizationRequested = true
            authorizationGranted = await requester.requestAuthorization()
        }
        return authorizationGranted ? .posted : .denied
    }
}
