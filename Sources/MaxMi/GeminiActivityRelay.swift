import Foundation
import MaxMiCore
import MaxMiRelay
import MaxMiActivity

struct GeminiActivityRelay: ActivityGenerationRelay, CaptureDisplayGenerationRelay {
    let geminiClient: any GenerationMemoryRelay
    let modelID: String

    func summarizeSession(appLabel: String, timelineText: String) async throws -> String {
        try await geminiClient.generateContent(
            model: modelID,
            prompt: AgentPrompts.summarizeForDisplay(
                appLabel: appLabel,
                timelineText: timelineText,
                maxChars: 6_000
            )
        )
    }

    func summarizeCapture(_ input: CaptureSummaryPromptInput) async throws -> String {
        try await geminiClient.generateContent(
            model: modelID,
            prompt: AgentPrompts.summarizeCaptureForDisplay(input)
        )
    }
}
