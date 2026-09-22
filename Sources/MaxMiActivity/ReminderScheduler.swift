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
    func markReminded(_ id: String, nowMs: EpochMs) async
}

public protocol ReminderNotifier: Sendable {
    func post(id: String, title: String, body: String) async
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

        for item in await repository.dueReminders(nowMs: nowMs) {
            let sourceApp = item.sourceApp ?? "MaxMi"
            let age = Self.ageDescription(detectedAtMs: item.detectedAtMs, nowMs: nowMs)
            await notifier.post(
                id: item.id,
                title: item.title,
                body: "\(sourceApp) · \(age)"
            )
            await repository.markReminded(item.id, nowMs: nowMs)
        }
    }

    private static func ageDescription(detectedAtMs: EpochMs, nowMs: EpochMs) -> String {
        let elapsedMs = max(0, nowMs - detectedAtMs)
        let elapsedHours = elapsedMs / 3_600_000
        if elapsedHours < 24 {
            return "\(elapsedHours)h"
        }
        return "\(elapsedHours / 24)d"
    }
}
