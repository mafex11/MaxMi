import Foundation
import MaxMiCore
import MaxMiRelay
import MaxMiActivity

struct GeminiAgentRelay: AgentGenerationRelay, Sendable {
    let geminiClient: GeminiClient

    func reviewActivity(_ input: AgentReviewInput) async throws -> [AgentOpDTO] {
        let prompt = AgentPrompts.hourlyReview(input: input)

        // Generate structured JSON response
        let text = try await geminiClient.generateContent(
            model: "gemini-2.5-flash-lite",
            prompt: prompt,
            responseMimeType: "application/json"
        )

        // Strict decode [AgentOpDTO]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = text.data(using: .utf8) else {
            throw RelayError.malformedResponse("response not valid UTF-8")
        }

        do {
            return try decoder.decode([AgentOpDTO].self, from: data)
        } catch {
            throw RelayError.malformedResponse("failed to decode [AgentOpDTO]: \(error)")
        }
    }
}
