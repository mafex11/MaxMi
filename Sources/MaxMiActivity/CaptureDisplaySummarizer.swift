import Foundation
import MaxMiCore

public struct CaptureSummaryCandidate: Sendable, Equatable {
    public let threadID: String
    public let appLabel: String
    public let sourceTitle: String?
    public let url: String?
    public let contentKind: CaptureContentKind
    public let capturedAt: EpochMs
    public let trigger: CaptureTrigger
    public let structured: CapturedContent
    public let delta: CaptureDelta
    public let typedText: String?
    public let expectedSourceHash: String
    public let promptVersion: String

    public init(
        threadID: String,
        appLabel: String,
        sourceTitle: String?,
        url: String?,
        contentKind: CaptureContentKind,
        capturedAt: EpochMs,
        trigger: CaptureTrigger,
        structured: CapturedContent,
        delta: CaptureDelta,
        typedText: String?,
        expectedSourceHash: String,
        promptVersion: String = CaptureDisplaySummaryFormat.standard
    ) {
        self.threadID = threadID
        self.appLabel = appLabel
        self.sourceTitle = sourceTitle
        self.url = url
        self.contentKind = contentKind
        self.capturedAt = capturedAt
        self.trigger = trigger
        self.structured = structured
        self.delta = delta
        self.typedText = typedText
        self.expectedSourceHash = expectedSourceHash
        self.promptVersion = promptVersion
    }
}

public protocol CaptureDisplaySummaryRepository: Sendable {
    func capturesNeedingSummary(nowMs: EpochMs) async -> [CaptureSummaryCandidate]
    func saveCaptureSummary(
        threadID: String,
        summary: String,
        expectedSourceHash: String,
        promptVersion: String,
        nowMs: EpochMs
    ) async
    func markCaptureSummaryFailed(
        threadID: String,
        expectedSourceHash: String,
        nowMs: EpochMs
    ) async
}

public protocol CaptureDisplayGenerationRelay: Sendable {
    func summarizeCapture(_ input: CaptureSummaryPromptInput) async throws -> String
}

public struct CaptureDisplaySummarizer: Sendable {
    private let repo: any CaptureDisplaySummaryRepository
    private let relay: any CaptureDisplayGenerationRelay

    public init(
        repo: any CaptureDisplaySummaryRepository,
        relay: any CaptureDisplayGenerationRelay
    ) {
        self.repo = repo
        self.relay = relay
    }

    public func summarizeDue(nowMs: EpochMs) async {
        for capture in await repo.capturesNeedingSummary(nowMs: nowMs) {
            do {
                let input = CaptureSummaryInputBuilder.build(
                    appLabel: capture.appLabel,
                    sourceTitle: capture.sourceTitle,
                    url: capture.url,
                    contentKind: capture.contentKind,
                    capturedAt: capture.capturedAt,
                    trigger: capture.trigger,
                    structured: capture.structured,
                    delta: capture.delta,
                    typedText: capture.typedText
                )
                let fallback = CaptureDisplaySummaryFormat.fallback(
                    app: capture.appLabel,
                    title: capture.sourceTitle
                )
                let summary: String
                if !input.hasMeaningfulContent {
                    summary = fallback
                } else {
                    let generated = try await relay.summarizeCapture(input)
                    let cleaned = Self.clean(generated)
                    summary = Self.isRefused(cleaned)
                        || CaptureDisplaySummaryFormat.isChromeOnly(cleaned)
                        ? fallback
                        : cleaned
                }
                await repo.saveCaptureSummary(
                    threadID: capture.threadID,
                    summary: summary,
                    expectedSourceHash: capture.expectedSourceHash,
                    promptVersion: capture.promptVersion,
                    nowMs: nowMs
                )
            } catch {
                SafeLogger.shared.log(
                    .error,
                    subsystem: .capture,
                    event: .captureSummaryFailed,
                    error: error
                )
                await repo.markCaptureSummaryFailed(
                    threadID: capture.threadID,
                    expectedSourceHash: capture.expectedSourceHash,
                    nowMs: nowMs
                )
            }
        }
    }

    private static func clean(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 {
            result.removeFirst()
            result.removeLast()
        }
        return result
    }

    static func isRefused(_ summary: String) -> Bool {
        let lower = summary.lowercased()
        let letters = lower.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let refusalPhrases = [
            "i can't",
            "i cannot",
            "i'm unable",
            "i am unable",
            "i am not able to summarize this.",
            "as an ai",
            "i'm sorry",
            "i am sorry",
        ]
        return summary.isEmpty
            || letters.isEmpty
            || summary.count > 280
            || lower.range(of: #"\n[ \t\r]*\n"#, options: .regularExpression) != nil
            || refusalPhrases.contains { lower.contains($0) }
    }
}
