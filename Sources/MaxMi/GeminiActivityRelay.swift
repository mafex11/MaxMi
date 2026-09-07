import Foundation
import MaxMiCore
import MaxMiRelay
import MaxMiActivity

struct GeminiActivityRelay: ActivityGenerationRelay, CaptureDisplayGenerationRelay, CheckinGenerationRelay {
    let geminiClient: any GenerationMemoryRelay
    let maxEvidenceChars: Int
    let modelID: String

    func summarizeSession(appLabel: String, evidence: [String]) async throws -> String {
        let prompt = AgentPrompts.summarizeForDisplay(appLabel: appLabel, evidence: evidence, maxEvidenceChars: maxEvidenceChars)
        return try await geminiClient.generateContent(model: modelID, prompt: prompt)
    }

    func summarizeCapture(
        appLabel: String,
        sourceTitle: String?,
        contentKind: CaptureContentKind,
        content: String
    ) async throws -> String {
        let prompt: String
        if contentKind == .conversation {
            prompt = AgentPrompts.summarizeRecentConversationForDisplay(
                appLabel: appLabel,
                sourceTitle: sourceTitle,
                recentMessages: content
            )
        } else {
            prompt = AgentPrompts.summarizeForDisplay(
                appLabel: appLabel,
                evidence: [content],
                maxEvidenceChars: maxEvidenceChars
            )
        }
        return try await geminiClient.generateContent(model: modelID, prompt: prompt)
    }

    func generateCheckin(_ input: DailyCheckinInput) async throws -> String {
        try await geminiClient.generateContent(model: modelID, prompt: AgentPrompts.dailyCheckin(input))
    }
}
