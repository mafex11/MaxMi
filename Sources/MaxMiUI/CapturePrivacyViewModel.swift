import Foundation
import Observation

public enum CapturePauseChoice: Sendable {
    case minutes(Int)
    case untilTomorrow
    case indefinite
    case resume
}

public struct PrivacyBlockedApp: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct PrivacyPausedThread: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let sourceApp: String
    public init(id: String, label: String, sourceApp: String) {
        self.id = id; self.label = label; self.sourceApp = sourceApp
    }
}

public struct CapturePrivacySnapshot: Sendable, Equatable {
    public let isPaused: Bool
    public let pauseDescription: String
    public let blockedDomains: [String]
    public let blockedApps: [PrivacyBlockedApp]
    public let pausedThreads: [PrivacyPausedThread]
    public let localOnlySources: [String]
    public let retentionDays: Int?

    public init(isPaused: Bool, pauseDescription: String, blockedDomains: [String],
                blockedApps: [PrivacyBlockedApp], pausedThreads: [PrivacyPausedThread],
                localOnlySources: [String] = [], retentionDays: Int?) {
        self.isPaused = isPaused
        self.pauseDescription = pauseDescription
        self.blockedDomains = blockedDomains
        self.blockedApps = blockedApps
        self.pausedThreads = pausedThreads
        self.localOnlySources = localOnlySources
        self.retentionDays = retentionDays
    }
}

@MainActor
@Observable
public final class CapturePrivacyViewModel {
    public private(set) var snapshot = CapturePrivacySnapshot(
        isPaused: false, pauseDescription: "Capture is active", blockedDomains: [],
        blockedApps: [], pausedThreads: [], retentionDays: nil
    )
    public var newDomain = ""
    public private(set) var message: String?

    private let load: @Sendable () async -> CapturePrivacySnapshot
    private let onPause: @Sendable (CapturePauseChoice) async throws -> Void
    private let onSetDomain: @Sendable (String, Bool) async throws -> Bool
    private let onResumeApp: @Sendable (String) async throws -> Void
    private let onResumeThread: @Sendable (String) async throws -> Void
    private let onSetRetention: @Sendable (Int?) async throws -> Void
    private let onAllowCloudSource: @Sendable (String) async throws -> Void

    public init(
        load: @escaping @Sendable () async -> CapturePrivacySnapshot,
        onPause: @escaping @Sendable (CapturePauseChoice) async throws -> Void,
        onSetDomain: @escaping @Sendable (String, Bool) async throws -> Bool,
        onResumeApp: @escaping @Sendable (String) async throws -> Void,
        onResumeThread: @escaping @Sendable (String) async throws -> Void,
        onSetRetention: @escaping @Sendable (Int?) async throws -> Void,
        onAllowCloudSource: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) {
        self.load = load
        self.onPause = onPause
        self.onSetDomain = onSetDomain
        self.onResumeApp = onResumeApp
        self.onResumeThread = onResumeThread
        self.onSetRetention = onSetRetention
        self.onAllowCloudSource = onAllowCloudSource
    }

    public func refresh() async { snapshot = await load() }

    public func setPause(_ choice: CapturePauseChoice) async {
        await perform("Capture pause updated") { try await onPause(choice) }
    }

    public func addDomain() async {
        let input = newDomain
        do {
            guard try await onSetDomain(input, true) else {
                message = "Enter a valid domain, such as example.com"
                return
            }
            newDomain = ""
            message = "Domain blocked"
            await refresh()
        } catch {
            message = "Could not update blocked domains"
        }
    }

    public func removeDomain(_ domain: String) async {
        do {
            _ = try await onSetDomain(domain, false)
            message = "Domain allowed"
            await refresh()
        } catch { message = "Could not update blocked domains" }
    }

    public func resumeApp(_ id: String) async {
        await perform("App capture resumed") { try await onResumeApp(id) }
    }

    public func resumeThread(_ id: String) async {
        await perform("Thread capture resumed") { try await onResumeThread(id) }
    }

    public func setRetention(_ days: Int?) async {
        await perform("Retention preference saved") { try await onSetRetention(days) }
    }

    public func allowCloudSource(_ sourceApp: String) async {
        await perform("Cloud processing allowed for \(sourceApp)") { try await onAllowCloudSource(sourceApp) }
    }

    private func perform(_ success: String, operation: () async throws -> Void) async {
        do {
            try await operation()
            message = success
            await refresh()
        } catch {
            message = "Privacy setting could not be saved"
        }
    }
}
