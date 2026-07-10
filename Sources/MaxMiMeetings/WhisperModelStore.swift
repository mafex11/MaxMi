import Foundation
import CryptoKit

public struct WhisperModelStore: Sendable {
    private let directory: URL

    public init(dir: URL) {
        self.directory = dir
    }

    public var isReady: Bool {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return false }
        guard let computed = computeSHA256(url: modelURL) else { return false }
        return computed == Self.sha256
    }

    public func ensureModel(download: (URL) async throws -> URL) async throws {
        if isReady { return }

        // Check available disk space (model is ~140MB)
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let freeSpace = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard freeSpace > 200_000_000 else {
            throw ModelStoreError.insufficientDiskSpace
        }

        // Download to temp location
        let tempURL = try await download(Self.remoteURL)

        // Verify checksum
        guard let downloadedSHA = computeSHA256(url: tempURL) else {
            throw ModelStoreError.checksumComputationFailed
        }
        guard downloadedSHA == Self.sha256 else {
            throw ModelStoreError.checksumMismatch(expected: Self.sha256, actual: downloadedSHA)
        }

        // Create directory if needed
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Atomic install via moveItem
        let destination = modelURL
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    public var modelURL: URL {
        directory.appendingPathComponent(Self.modelName)
    }

    public static let modelName = "ggml-base.bin"
    public static let remoteURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin")!
    public static let sha256 = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"

    private func computeSHA256(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ModelStoreError: Error {
    case insufficientDiskSpace
    case checksumComputationFailed
    case checksumMismatch(expected: String, actual: String)
}
