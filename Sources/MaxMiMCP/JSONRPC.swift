import Foundation

enum JSONRPC {
    static func parse(_ line: String) -> [String: Any]? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { return nil }
        return obj as? [String: Any]
    }

    static func response(id: Any, result: [String: Any]) -> String {
        serialize(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: Any?, code: Int, message: String) -> String {
        serialize(["jsonrpc": "2.0", "id": id ?? NSNull(),
                   "error": ["code": code, "message": message]])
    }

    private static func serialize(_ obj: [String: Any]) -> String {
        // fragmentsAllowed unnecessary; keys sorted for deterministic tests.
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
