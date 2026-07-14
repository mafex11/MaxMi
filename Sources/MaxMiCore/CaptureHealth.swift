import Foundation

public enum CaptureTrigger: String, Sendable, Codable, CaseIterable {
    case appActivated
    case accessibilityChanged
    case browserNavigation
    case webContentChanged
    case periodic
    case retry
    case unknown
}

public enum CaptureOutcomeKind: String, Sendable, Codable, CaseIterable {
    case captured
    case deduplicated
    case skipped
    case failed
}

public enum CaptureSkipReason: String, Sendable, Codable, CaseIterable {
    case globalPaused
    case appPaused
    case excludedApp
    case blockedURL
    case userBlockedDomain
    case pausedThread
    case noWindow
    case emptyContent
    case parserNoContent
    case addressFieldFocused
    case permissionUnavailable
}

public enum CaptureFailureReason: String, Sendable, Codable, CaseIterable {
    case appPauseReadFailed
    case threadPauseReadFailed
    case privacySettingsReadFailed
    case browserExtractionFailed
    case parserFailed
    case storeCommitFailed
    case unexpected
}

/// Terminal outcome for one capture attempt. It intentionally carries no page/message text.
public enum CaptureOutcome: Sendable, Equatable {
    case captured(versionID: String, characterCount: Int, truncated: Bool)
    case deduplicated(characterCount: Int, truncated: Bool)
    case skipped(CaptureSkipReason)
    case failed(CaptureFailureReason)

    public var kind: CaptureOutcomeKind {
        switch self {
        case .captured: return .captured
        case .deduplicated: return .deduplicated
        case .skipped: return .skipped
        case .failed: return .failed
        }
    }

    public var reason: String? {
        switch self {
        case .skipped(let reason): return reason.rawValue
        case .failed(let reason): return reason.rawValue
        case .captured, .deduplicated: return nil
        }
    }

    public var versionID: String? {
        guard case .captured(let versionID, _, _) = self else { return nil }
        return versionID
    }

    public var characterCount: Int {
        switch self {
        case .captured(_, let count, _), .deduplicated(let count, _): return count
        case .skipped, .failed: return 0
        }
    }

    public var truncated: Bool {
        switch self {
        case .captured(_, _, let truncated), .deduplicated(_, let truncated): return truncated
        case .skipped, .failed: return false
        }
    }
}

/// Content-free event persisted in the bounded local Capture Health ledger.
public struct CaptureHealthRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let atMs: EpochMs
    public let appBundle: String
    public let appLabel: String
    public let trigger: CaptureTrigger
    public let parser: String
    public let outcome: CaptureOutcomeKind
    public let reason: String?
    public let characterCount: Int
    public let durationMs: Int
    public let truncated: Bool
    public let versionID: String?

    public init(
        id: String,
        atMs: EpochMs,
        appBundle: String,
        appLabel: String,
        trigger: CaptureTrigger,
        parser: String,
        outcome: CaptureOutcomeKind,
        reason: String?,
        characterCount: Int,
        durationMs: Int,
        truncated: Bool,
        versionID: String?
    ) {
        self.id = id
        self.atMs = atMs
        self.appBundle = appBundle
        self.appLabel = appLabel
        self.trigger = trigger
        self.parser = parser
        self.outcome = outcome
        self.reason = reason
        self.characterCount = characterCount
        self.durationMs = durationMs
        self.truncated = truncated
        self.versionID = versionID
    }
}
