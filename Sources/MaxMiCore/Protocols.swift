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
    case requestTooLarge
    case insecureEndpoint

    public var kind: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .network: return "network"
        case .httpStatus(let code): return "httpStatus(\(code))"
        case .malformedResponse: return "malformedResponse"
        case .requestTooLarge: return "requestTooLarge"
        case .insecureEndpoint: return "insecureEndpoint"
        }
    }
}

public struct PipelineVersion: Sendable, Equatable {
    public let id: String, threadID: String, content: String, contentHash: String
    public let sourceApp: String, sourceKey: String
    public let previousFrozenContent: String?
    public init(id: String, threadID: String, content: String, contentHash: String,
                sourceApp: String, sourceKey: String, previousFrozenContent: String?) {
        self.id = id
        self.threadID = threadID
        self.content = content
        self.contentHash = contentHash
        self.sourceApp = sourceApp
        self.sourceKey = sourceKey
        self.previousFrozenContent = previousFrozenContent
    }
}

public struct PipelineDerivative: Sendable, Equatable {
    public let id: String, content: String
    public init(id: String, content: String) {
        self.id = id
        self.content = content
    }
}

public protocol MemoryStore: Sendable {
    func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PipelineVersion]
    func insertDerivatives(versionID: String, threadID: String, facts: [String], nowMs: EpochMs) throws -> [PipelineDerivative]
    func pendingDerivatives(versionID: String) throws -> [PipelineDerivative]
    func markExtracted(versionID: String, contentHashRead: String) throws -> Bool
    func markExtractFailed(versionID: String) throws
    func markEmbedded(derivativeID: String) throws
    func insertEmbedding(derivativeID: String, vector: [Float]) throws
    func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws
    func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)]
    func clearRetry(id: String) throws
}
