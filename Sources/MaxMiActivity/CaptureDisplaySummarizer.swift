import Foundation
import MaxMiCore

public struct CaptureSummaryCandidate: Sendable, Equatable {
    public let threadID: String
    public let appLabel: String
    public let sourceTitle: String?
    public let contentKind: CaptureContentKind
    public let content: String
    public let expectedSourceHash: String
    public let promptVersion: String

    public init(
        threadID: String,
        appLabel: String,
        sourceTitle: String? = nil,
        contentKind: CaptureContentKind = .generic,
        content: String,
        expectedSourceHash: String,
        promptVersion: String = CaptureDisplaySummaryFormat.standard
    ) {
        self.threadID = threadID
        self.appLabel = appLabel
        self.sourceTitle = sourceTitle
        self.contentKind = contentKind
        self.content = content
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
    func summarizeCapture(
        appLabel: String,
        sourceTitle: String?,
        contentKind: CaptureContentKind,
        content: String
    ) async throws -> String
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
            guard capture.content != "[unreadable memory]" else {
                await repo.markCaptureSummaryFailed(
                    threadID: capture.threadID,
                    expectedSourceHash: capture.expectedSourceHash,
                    nowMs: nowMs
                )
                continue
            }
            do {
                let content = Self.summaryInput(for: capture)
                let generated = try await relay.summarizeCapture(
                    appLabel: capture.appLabel,
                    sourceTitle: capture.sourceTitle,
                    contentKind: capture.contentKind,
                    content: content
                )
                let summary = Self.clean(generated)
                guard !summary.isEmpty else { throw EmptySummaryError() }
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
        return String(result.prefix(280))
    }

    /// A conversation summary must describe the newest exchange, not the beginning
    /// of an accumulated thread. Keep complete trailing message lines so the prompt
    /// never begins in the middle of a message.
    static func summaryInput(for capture: CaptureSummaryCandidate) -> String {
        guard capture.contentKind == .conversation else { return capture.content }
        return trailingLines(in: capture.content, maxCharacters: 8_000)
    }

    private static func trailingLines(in content: String, maxCharacters: Int) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var retained: [Substring] = []
        var count = 0
        for line in lines.reversed() {
            let added = line.count + 1
            if count + added > maxCharacters, !retained.isEmpty { break }
            retained.append(line)
            count += added
        }
        return retained.reversed().joined(separator: "\n")
    }

    private struct EmptySummaryError: Error {}
}
