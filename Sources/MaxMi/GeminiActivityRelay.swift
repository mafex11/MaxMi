import Foundation
import MaxMiRelay
import MaxMiActivity

struct GeminiActivityRelay: ActivityGenerationRelay, CaptureDisplayGenerationRelay {
    let geminiClient: GeminiClient
    let maxEvidenceChars: Int
    let modelID: String

    func summarizeSession(appLabel: String, evidence: [String]) async throws -> String {
        let prompt = AgentPrompts.summarizeForDisplay(appLabel: appLabel, evidence: evidence, maxEvidenceChars: maxEvidenceChars)
        return try await geminiClient.generateContent(model: modelID, prompt: prompt)
    }

    func summarizeCapture(appLabel: String, content: String) async throws -> String {
        let prompt = AgentPrompts.summarizeForDisplay(
            appLabel: appLabel,
            evidence: [content],
            maxEvidenceChars: maxEvidenceChars
        )
        return try await geminiClient.generateContent(model: modelID, prompt: prompt)
    }
}
