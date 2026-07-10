import Foundation
import MaxMiCore

public final class GeminiClient: MemoryRelay {
    let config: EnvConfig
    let session: URLSession
    let baseURL: URL
    let throttle: GeminiThrottle

    public init(config: EnvConfig, session: URLSession = .shared,
                baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
                throttle: GeminiThrottle = GeminiThrottle.shared) {
        self.config = config; self.session = session; self.baseURL = baseURL; self.throttle = throttle
    }

    public func generateContent(model: String, prompt: String, temperature: Double = 0.2, responseMimeType: String? = nil) async throws -> String {
        await throttle.waitIfNeeded()

        var generationConfig: [String: Any] = ["temperature": temperature]
        if let mimeType = responseMimeType {
            generationConfig["responseMimeType"] = mimeType
        }

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig,
        ]

        let data: Data
        do {
            data = try await post(path: "models/\(model):generateContent", body: body)
            await throttle.recordSuccess()
        } catch let RelayError.httpStatus(code) {
            await throttle.recordFailure(statusCode: code)
            throw RelayError.httpStatus(code)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw RelayError.malformedResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }

        return text
    }

    public func extract(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) async throws -> [String] {
        let prompt = ExtractPrompt.build(newContent: newContent, previousContent: previousContent,
                                         sourceApp: sourceApp, sourceKey: sourceKey)
        let text = try await generateContent(model: config.extractModel, prompt: prompt, temperature: 0.2, responseMimeType: "application/json")
        return try JSONArrayParser.parse(text)
    }

    public func embed(text: String) async throws -> [Float] {
        let body: [String: Any] = [
            "model": "models/\(config.embedModel)",
            "content": ["parts": [["text": text]]],
            "outputDimensionality": config.embedDims,
        ]
        let data = try await post(path: "models/\(config.embedModel):embedContent", body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let emb = obj["embedding"] as? [String: Any],
              let values = emb["values"] as? [Double] else {
            throw RelayError.malformedResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return normalize(values.map(Float.init))
    }

    /// Spec §7: only 3072-dim output is pre-normalized by Google; at 1536 we re-normalize.
    func normalize(_ v: [Float]) -> [Float] {
        let mag = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard mag > 0 else { return v }
        return v.map { $0 / mag }
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        guard let key = config.geminiAPIKey else { throw RelayError.notConfigured }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw RelayError.network(underlying: error) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RelayError.httpStatus(status) }
        return data
    }
}
