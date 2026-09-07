import Foundation

/// Versioned display-summary formats. The store uses this to selectively refresh
/// summaries when their prompt/input contract changes without reprocessing every
/// source in the corpus.
public enum CaptureDisplaySummaryFormat {
    public static let standard = "capture-display-v3-structured"
    public static let recentConversation = "capture-display-v4-recent-conversation"

    public static func fallback(app: String, title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return "Viewing \(app)" }
        return "Viewing \(app): \(title)"
    }

    public static func promptVersion(
        sourceApp: String,
        contentKind: CaptureContentKind
    ) -> String {
        _ = sourceApp
        return contentKind == .conversation ? recentConversation : standard
    }

    public static func isChromeOnly(_ summary: String) -> Bool {
        let words = summary.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        return !words.isEmpty && words.allSatisfy {
            ["button", "buttons", "tab", "tabs", "sidebar", "toolbar", "menu", "window", "panel"].contains($0)
        }
    }
}
