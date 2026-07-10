import Foundation
import MaxMiRelay
import MaxMiActivity

struct GeminiActivityRelay: ActivityGenerationRelay {
    let geminiClient: GeminiClient
    let maxEvidenceChars: Int

    func summarizeSession(appLabel: String, evidence: [String]) async throws -> String {
        let prompt = AgentPrompts.summarizeForDisplay(appLabel: appLabel, evidence: evidence, maxEvidenceChars: maxEvidenceChars)
        return try await geminiClient.generateContent(model: "gemini-2.5-flash-lite", prompt: prompt)
    }
}
