import Foundation
import MaxMiCore

public struct RecentCaptureDTO: Identifiable, Sendable, Equatable {
    public let id: String
    public let appLabel: String
    public let title: String?
    public let contentKind: CaptureContentKind
    public let parserID: String
    public let capturedAtMs: EpochMs
    public let characterCount: Int
    public let truncated: Bool
    public let displaySummary: String?
    public let summaryStatus: String
    public let cloudState: CloudProcessingDisplayState

    public init(
        id: String,
        appLabel: String,
        title: String?,
        contentKind: CaptureContentKind,
        parserID: String,
        capturedAtMs: EpochMs,
        characterCount: Int,
        truncated: Bool,
        displaySummary: String? = nil,
        summaryStatus: String = "pending",
        cloudState: CloudProcessingDisplayState = .allowed
    ) {
        self.id = id
        self.appLabel = appLabel
        self.title = title
        self.contentKind = contentKind
        self.parserID = parserID
        self.capturedAtMs = capturedAtMs
        self.characterCount = characterCount
        self.truncated = truncated
        self.displaySummary = displaySummary
        self.summaryStatus = summaryStatus
        self.cloudState = cloudState
    }
}

public struct RecentCaptureRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let appLabel: String
    public let summary: String
    public let sourceTitle: String
    public let contentKind: CaptureContentKind
    public let timeAgo: String
    public let detail: String
    public let cloudState: CloudProcessingDisplayState
}

public enum CloudProcessingDisplayState: String, Sendable, Equatable {
    case pendingReview
    case allowed
    case localOnly
}
