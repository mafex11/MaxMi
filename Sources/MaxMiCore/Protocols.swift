import Foundation

public protocol MemoryRelay: Sendable {
    func extract(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) async throws -> [String]
    func embed(text: String) async throws -> [Float]
}

public enum RelayError: Error {
    case notConfigured          // no API key
    case network(underlying: Error)
    case httpStatus(Int)        // 429/5xx -> retryable
    case malformedResponse(String)
}
