import Foundation
import MaxMiCore

public enum CheckinSchedule {
    public static func isAutomaticGenerationEligible(
        nowMs: EpochMs,
        timeZone: TimeZone,
        hasCheckinForToday: Bool
    ) -> Bool {
        guard !hasCheckinForToday else { return false }
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(nowMs) / 1_000)
        return calendar.component(.hour, from: date) >= 8
    }
}

public protocol CheckinGenerating: Sendable {
    func hasCheckinForToday(nowMs: EpochMs) async -> Bool
    func generateIfMissing(nowMs: EpochMs) async
    func regenerate(nowMs: EpochMs) async
}

public actor CheckinTrigger {
    private let generator: any CheckinGenerating
    private let schedule: @Sendable (EpochMs, TimeZone, Bool) -> Bool
    private let isActivitySynthesisEnabled: @Sendable () -> Bool
    private let clock: @Sendable () -> EpochMs
    private let timeZone: TimeZone

    public init(
        generator: any CheckinGenerating,
        schedule: @escaping @Sendable (EpochMs, TimeZone, Bool) -> Bool
            = CheckinSchedule.isAutomaticGenerationEligible,
        isActivitySynthesisEnabled: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> EpochMs = epochNowMs,
        timeZone: TimeZone = .current
    ) {
        self.generator = generator
        self.schedule = schedule
        self.isActivitySynthesisEnabled = isActivitySynthesisEnabled
        self.clock = clock
        self.timeZone = timeZone
    }

    public func tick() async {
        await tick(nowMs: clock())
    }

    public func tick(nowMs: EpochMs) async {
        guard isActivitySynthesisEnabled() else { return }
        let hasCheckinForToday = await generator.hasCheckinForToday(nowMs: nowMs)
        guard schedule(nowMs, timeZone, hasCheckinForToday) else { return }
        await generator.generateIfMissing(nowMs: nowMs)
    }

    public func regenerateNow() async {
        await regenerateNow(nowMs: clock())
    }

    public func regenerateNow(nowMs: EpochMs) async {
        guard isActivitySynthesisEnabled() else { return }
        await generator.regenerate(nowMs: nowMs)
    }
}
