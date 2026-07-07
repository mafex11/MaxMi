import Foundation
import MaxMiCore

enum JSONArrayParser {
    /// Spec §10: direct parse, then one reparse attempt (strip fences, first-[ to last-]).
    static func parse(_ raw: String) throws -> [String] {
        if let arr = decode(raw) { return arr }
        var s = raw
        s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start < end {
            if let arr = decode(String(s[start...end])) { return arr }
        }
        throw RelayError.malformedResponse(String(raw.prefix(200)))
    }
    private static func decode(_ s: String) -> [String]? {
        try? JSONDecoder().decode([String].self, from: Data(s.utf8))
    }
}
