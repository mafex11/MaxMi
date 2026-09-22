import MaxMiCore

public struct ReminderItem: Sendable, Equatable {
    public let id: String
    public let title: String
    public let sourceApp: String?
    public let detectedAtMs: EpochMs

    public init(id: String, title: String, sourceApp: String?, detectedAtMs: EpochMs) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.detectedAtMs = detectedAtMs
    }
}

public protocol ReminderRepository: Sendable {
    func dueReminders(nowMs: EpochMs) async -> [ReminderItem]
    func dueReminder(id: String, nowMs: EpochMs) async -> ReminderItem?
    func markReminded(_ id: String, nowMs: EpochMs) async
}

public enum ReminderPostOutcome: Sendable, Equatable {
    case posted
    case denied
    case failed
}

public protocol ReminderNotifier: Sendable {
    func post(id: String, title: String, body: String) async -> ReminderPostOutcome
}

public actor ReminderScheduler {
    private let repository: any ReminderRepository
    private let notifier: any ReminderNotifier
    private let isActivitySynthesisEnabled: @Sendable () -> Bool
    private let clock: @Sendable () -> EpochMs
    private var inFlight = false

    public init(
        repository: any ReminderRepository,
        notifier: any ReminderNotifier,
        isActivitySynthesisEnabled: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> EpochMs = epochNowMs
    ) {
        self.repository = repository
        self.notifier = notifier
        self.isActivitySynthesisEnabled = isActivitySynthesisEnabled
        self.clock = clock
    }

    public func tick() async {
        await tick(nowMs: clock())
    }

    public func tick(nowMs: EpochMs) async {
        guard isActivitySynthesisEnabled(), !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        for candidate in await repository.dueReminders(nowMs: nowMs) {
            guard let item = await repository.dueReminder(id: candidate.id, nowMs: nowMs) else {
                continue
            }
            let sourceApp = item.sourceApp ?? "MaxMi"
            let age = ActivityTime.ageDescription(detectedAtMs: item.detectedAtMs, nowMs: nowMs)
            let outcome = await notifier.post(
                id: item.id,
                title: item.title,
                body: "\(sourceApp) · \(age)"
            )
            switch outcome {
            case .posted:
                await repository.markReminded(item.id, nowMs: nowMs)
            case .denied:
                break
            case .failed:
                SafeLogger.shared.log(
                    .warning,
                    subsystem: .activity,
                    event: .reminderNotificationFailed
                )
            }
        }
    }

}
