import Foundation
import MaxMiCore

public protocol GenerationMemoryRelay: MemoryRelay {
    func generateContent(
        model: String,
        prompt: String,
        temperature: Double,
        responseMimeType: String?
    ) async throws -> String
}

public extension GenerationMemoryRelay {
    func generateContent(
        model: String,
        prompt: String,
        temperature: Double = 0.2,
        responseMimeType: String? = nil
    ) async throws -> String {
        try await generateContent(
            model: model,
            prompt: prompt,
            temperature: temperature,
            responseMimeType: responseMimeType
        )
    }
}

public final class HostedRelayClient: GenerationMemoryRelay, @unchecked Sendable {
    private let config: EnvConfig
    private let session: URLSession
    private let baseURL: URL
    private let token: String
    private let maximumRequestBytes: Int
    private let maximumResponseBytes: Int

    public init?(
        config: EnvConfig,
        session: URLSession = .shared,
        maximumRequestBytes: Int = 128 * 1_024,
        maximumResponseBytes: Int = 4 * 1_024 * 1_024
    ) {
        guard let baseURL = config.relayURL,
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && baseURL.host == "127.0.0.1"),
              let token = config.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              token.utf8.count >= 16,
              token.utf8.count <= 2_048 else { return nil }
        self.config = config
        self.session = session
        self.baseURL = baseURL
        self.token = token
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func generateContent(
        model: String,
        prompt: String,
        temperature: Double = 0.2,
        responseMimeType: String? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "temperature": temperature,
        ]
        if let responseMimeType { body["responseMimeType"] = responseMimeType }
        let data = try await post(path: "v1/generate", body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw RelayError.malformedResponse("hosted relay generate response")
        }
        return text
    }

    public func extract(
        newContent: String,
        previousContent: String?,
        sourceApp: String,
        sourceKey: String
    ) async throws -> [String] {
        let prompt = ExtractPrompt.build(
            newContent: newContent,
            previousContent: previousContent,
            sourceApp: sourceApp,
            sourceKey: sourceKey
        )
        let text = try await generateContent(
            model: config.extractModel,
            prompt: prompt,
            responseMimeType: "application/json"
        )
        return try JSONArrayParser.parse(text)
    }

    public func embed(text: String) async throws -> [Float] {
        let data = try await post(path: "v1/embed", body: [
            "model": config.embedModel,
            "text": text,
            "dimensions": config.embedDims,
        ])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = object["values"] as? [Double],
              values.count == config.embedDims else {
            throw RelayError.malformedResponse("hosted relay embedding response")
        }
        let floats = values.map(Float.init)
        let magnitude = sqrt(floats.reduce(0) { $0 + $1 * $1 })
        return magnitude > 0 ? floats.map { $0 / magnitude } : floats
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        let requestData = try JSONSerialization.data(withJSONObject: body)
        guard requestData.count <= maximumRequestBytes else { throw RelayError.requestTooLarge }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = requestData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-MaxMi-Relay-Protocol")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw RelayError.network(underlying: error) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RelayError.httpStatus(status) }
        guard data.count <= maximumResponseBytes else { throw RelayError.malformedResponse("hosted relay response too large") }
        return data
    }
}

private struct UnavailableGenerationRelay: GenerationMemoryRelay {
    func generateContent(
        model: String,
        prompt: String,
        temperature: Double,
        responseMimeType: String?
    ) async throws -> String { throw RelayError.notConfigured }

    func extract(
        newContent: String,
        previousContent: String?,
        sourceApp: String,
        sourceKey: String
    ) async throws -> [String] { throw RelayError.notConfigured }

    func embed(text: String) async throws -> [Float] { throw RelayError.notConfigured }
}

public enum RelayClientFactory {
    public static func make(config: EnvConfig, session: URLSession = .shared)
        -> any GenerationMemoryRelay
    {
        if config.usesHostedRelay {
            return HostedRelayClient(config: config, session: session)
                ?? UnavailableGenerationRelay()
        }
        return GeminiClient(config: config, session: session)
    }
}
