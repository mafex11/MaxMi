import Foundation
import MaxMiRelay
import MaxMiActivity

struct GeminiActivityRelay: ActivityGenerationRelay {
    let geminiClient: GeminiClient

    func summarizeSession(appLabel: String, evidence: [String]) async throws -> String {
        let prompt = AgentPrompts.summarizeForDisplay(appLabel: appLabel, evidence: evidence, maxEvidenceChars: 12_000)
        return try await geminiClient.generateContent(model: "gemini-2.5-flash-lite", prompt: prompt)
    }
}
