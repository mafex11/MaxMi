import Foundation
import Observation

public enum SetupState: String, Sendable {
    case ready
    case attention
    case unavailable
}

public enum SetupPermission: Sendable {
    case accessibility
    case microphone
    case screenRecording
}

public enum MCPSetupTarget: Sendable {
    case claudeCode
    case claudeDesktop
}

public struct SetupStatusItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let state: SetupState
    public let actionTitle: String?

    public init(id: String, title: String, detail: String, state: SetupState, actionTitle: String? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.state = state; self.actionTitle = actionTitle
    }
}

public struct SetupSnapshot: Sendable, Equatable {
    public let permissions: [SetupStatusItem]
    public let apiKeyConfigured: Bool
    public let encryption: SetupStatusItem
    public let mcp: SetupStatusItem

    public init(permissions: [SetupStatusItem], apiKeyConfigured: Bool,
                encryption: SetupStatusItem, mcp: SetupStatusItem) {
        self.permissions = permissions
        self.apiKeyConfigured = apiKeyConfigured
        self.encryption = encryption
        self.mcp = mcp
    }
}

@MainActor
@Observable
public final class SetupViewModel {
    public private(set) var snapshot = SetupSnapshot(
        permissions: [], apiKeyConfigured: false,
        encryption: SetupStatusItem(id: "encryption", title: "Encryption", detail: "Checking…", state: .attention),
        mcp: SetupStatusItem(id: "mcp", title: "Claude MCP", detail: "Checking…", state: .attention)
    )
    public var apiKey = ""
    public private(set) var message = ""
    public private(set) var isWorking = false

    private let load: @MainActor @Sendable () async -> SetupSnapshot
    private let onPermission: @MainActor @Sendable (SetupPermission) async -> Void
    private let onSaveAPIKey: @Sendable (String) async throws -> String
    private let onCopyMCPSetup: @MainActor @Sendable (MCPSetupTarget) -> String

    public init(
        load: @escaping @MainActor @Sendable () async -> SetupSnapshot,
        onPermission: @escaping @MainActor @Sendable (SetupPermission) async -> Void,
        onSaveAPIKey: @escaping @Sendable (String) async throws -> String,
        onCopyMCPSetup: @escaping @MainActor @Sendable (MCPSetupTarget) -> String
    ) {
        self.load = load
        self.onPermission = onPermission
        self.onSaveAPIKey = onSaveAPIKey
        self.onCopyMCPSetup = onCopyMCPSetup
    }

    public func refresh() async { snapshot = await load() }

    public func handlePermission(_ id: String) async {
        let permission: SetupPermission?
        switch id {
        case "accessibility": permission = .accessibility
        case "microphone": permission = .microphone
        case "screenRecording": permission = .screenRecording
        default: permission = nil
        }
        guard let permission else { return }
        await onPermission(permission)
        await refresh()
    }

    public func saveAPIKey() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { message = "Enter a Gemini API key"; return }
        guard !key.contains("\n"), !key.contains("\r") else { message = "API key contains invalid characters"; return }
        isWorking = true
        defer { isWorking = false }
        do {
            message = try await onSaveAPIKey(key)
            apiKey = ""
            await refresh()
        } catch {
            message = "API key validation failed: \(error.localizedDescription)"
        }
    }

    public func copyMCPSetup(_ target: MCPSetupTarget) {
        message = onCopyMCPSetup(target)
    }
}

