import Foundation

public struct EnvConfig: Sendable, Equatable {
    public let geminiAPIKey: String?
    public let extractModel: String
    public let embedModel: String
    public let embedDims: Int

    public init(geminiAPIKey: String?, extractModel: String, embedModel: String, embedDims: Int) {
        self.geminiAPIKey = geminiAPIKey
        self.extractModel = extractModel
        self.embedModel = embedModel
        self.embedDims = embedDims
    }

    public static func load(searchPaths: [URL]) -> EnvConfig {
        var kv: [String: String] = [:]
        if let path = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let raw = try? String(contentsOf: path, encoding: .utf8) {
            for line in raw.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
                let key = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
                var val = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    val = String(val.dropFirst().dropLast())
                }
                kv[key] = val
            }
        }
        return EnvConfig(
            geminiAPIKey: kv["GEMINI_API_KEY"],
            extractModel: kv["MAXMI_EXTRACT_MODEL"] ?? "gemini-flash-lite-latest",
            embedModel: kv["MAXMI_EMBED_MODEL"] ?? "gemini-embedding-001",
            embedDims: kv["MAXMI_EMBED_DIMS"].flatMap(Int.init) ?? 1536
        )
    }
}
