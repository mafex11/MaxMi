import Foundation
import Observation
import MaxMiCore

public struct SettingsExcludedApp: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let excluded: Bool

    public init(id: String, name: String, excluded: Bool) {
        self.id = id
        self.name = name
        self.excluded = excluded
    }
}

public struct SettingsSnapshot: Sendable {
    public let launchAtLoginStatus: LaunchAtLoginState
    public let activityEnabled: Bool
    public let consentGranted: Bool
    public let excludedApps: [SettingsExcludedApp]
    public let version: String
    public let statusLines: [String]

    public init(
        launchAtLoginStatus: LaunchAtLoginState,
        activityEnabled: Bool,
        consentGranted: Bool,
        excludedApps: [SettingsExcludedApp],
        version: String,
        statusLines: [String]
    ) {
        self.launchAtLoginStatus = launchAtLoginStatus
        self.activityEnabled = activityEnabled
        self.consentGranted = consentGranted
        self.excludedApps = excludedApps
        self.version = version
        self.statusLines = statusLines
    }
}

@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var launchAtLoginStatus: LaunchAtLoginState = .notRegistered
    private var _activityEnabled: Bool = false
    public var activityEnabled: Bool {
        get { _activityEnabled }
        set {
            guard newValue != _activityEnabled else { return }
            // Consent gate: can't enable without consent
            if newValue && !consentGranted {
                return
            }
            _activityEnabled = newValue
            onSetActivityEnabled(newValue)
        }
    }
    public private(set) var consentGranted: Bool = false
    public private(set) var excludedApps: [SettingsExcludedApp] = []
    public private(set) var version: String = ""
    public private(set) var updateStatus: String = ""
    public private(set) var launchAtLoginError: String? = nil
    public private(set) var statusLines: [String] = []

    private let load: @Sendable () async -> SettingsSnapshot
    private let onSetLaunchAtLogin: @Sendable (Bool) async throws -> Void
    private let onSetActivityEnabled: @Sendable (Bool) -> Void
    private let onToggleExcluded: @Sendable (String, Bool) async -> Void
    private let onCheckUpdates: @Sendable () async -> String
    private let onOpenPrivacy: @MainActor @Sendable () -> Void
    private let onOpenLoginItems: @MainActor @Sendable () -> Void

    public init(
        load: @escaping @Sendable () async -> SettingsSnapshot,
        onSetLaunchAtLogin: @escaping @Sendable (Bool) async throws -> Void,
        onSetActivityEnabled: @escaping @Sendable (Bool) -> Void,
        onToggleExcluded: @escaping @Sendable (String, Bool) async -> Void,
        onCheckUpdates: @escaping @Sendable () async -> String,
        onOpenPrivacy: @escaping @MainActor @Sendable () -> Void,
        onOpenLoginItems: @escaping @MainActor @Sendable () -> Void
    ) {
        self.load = load
        self.onSetLaunchAtLogin = onSetLaunchAtLogin
        self.onSetActivityEnabled = onSetActivityEnabled
        self.onToggleExcluded = onToggleExcluded
        self.onCheckUpdates = onCheckUpdates
        self.onOpenPrivacy = onOpenPrivacy
        self.onOpenLoginItems = onOpenLoginItems
    }

    public func openPrivacy() {
        onOpenPrivacy()
    }

    public func openLoginItems() {
        onOpenLoginItems()
    }

    public func refresh() async {
        let snapshot = await load()
        launchAtLoginStatus = snapshot.launchAtLoginStatus
        _activityEnabled = snapshot.activityEnabled
        consentGranted = snapshot.consentGranted
        excludedApps = snapshot.excludedApps
        version = snapshot.version
        statusLines = snapshot.statusLines
        launchAtLoginError = nil
    }

    public func toggleExcluded(_ id: String) async {
        guard let app = excludedApps.first(where: { $0.id == id }) else { return }
        let newExcluded = !app.excluded
        await onToggleExcluded(id, newExcluded)
        await refresh()
    }

    public func checkUpdates() async {
        updateStatus = await onCheckUpdates()
    }

    public func setLaunchAtLogin(_ on: Bool) async {
        launchAtLoginError = nil
        do {
            try await onSetLaunchAtLogin(on)
        } catch {
            SafeLogger.shared.log(
                .error,
                subsystem: .settings,
                event: .launchAtLoginWriteFailed,
                error: error
            )
            launchAtLoginError = error.localizedDescription
        }
        // Reload status after attempt (authoritative, not optimistic)
        await refresh()
    }
}
