import Foundation
import MaxMiCore

public struct CaptureSummaryCandidate: Sendable, Equatable {
    public let threadID: String
    public let appLabel: String
    public let content: String
    public let expectedSourceHash: String

    public init(threadID: String, appLabel: String, content: String, expectedSourceHash: String) {
        self.threadID = threadID
        self.appLabel = appLabel
        self.content = content
        self.expectedSourceHash = expectedSourceHash
    }
}

public protocol CaptureDisplaySummaryRepository: Sendable {
    func capturesNeedingSummary(nowMs: EpochMs) async -> [CaptureSummaryCandidate]
    func saveCaptureSummary(
        threadID: String,
        summary: String,
        expectedSourceHash: String,
        nowMs: EpochMs
    ) async
    func markCaptureSummaryFailed(
        threadID: String,
        expectedSourceHash: String,
        nowMs: EpochMs
    ) async
}

public protocol CaptureDisplayGenerationRelay: Sendable {
    func summarizeCapture(appLabel: String, content: String) async throws -> String
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
                let generated = try await relay.summarizeCapture(
                    appLabel: capture.appLabel,
                    content: capture.content
                )
                let summary = Self.clean(generated)
                guard !summary.isEmpty else { throw EmptySummaryError() }
                await repo.saveCaptureSummary(
                    threadID: capture.threadID,
                    summary: summary,
                    expectedSourceHash: capture.expectedSourceHash,
                    nowMs: nowMs
                )
            } catch {
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

    private struct EmptySummaryError: Error {}
}
