import Foundation
import MaxMiCore
import MaxMiRelay

enum APIKeyManager {
    static func validateAndSave(_ key: String, at envURL: URL, baseConfig: EnvConfig) async throws {
        let candidate = EnvConfig(
            geminiAPIKey: key,
            extractModel: baseConfig.extractModel,
            embedModel: baseConfig.embedModel,
            embedDims: baseConfig.embedDims
        )
        _ = try await GeminiClient(config: candidate).embed(text: "MaxMi connection check")

        var lines: [String] = []
        if let existing = try? String(contentsOf: envURL, encoding: .utf8) {
            lines = existing.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("GEMINI_API_KEY=") }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("GEMINI_API_KEY=\(key)")
        lines.append("")
        try FileManager.default.createDirectory(at: envURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: envURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
    }
}

