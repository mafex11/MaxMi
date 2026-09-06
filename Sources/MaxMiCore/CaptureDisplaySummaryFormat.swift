import Foundation

/// Versioned display-summary formats. The store uses this to selectively refresh
/// summaries when their prompt/input contract changes without reprocessing every
/// source in the corpus.
public enum CaptureDisplaySummaryFormat {
    public static let standard = "capture-display-v1"
    public static let recentConversation = "capture-display-v2-recent-conversation"

    public static func promptVersion(
        sourceApp: String,
        contentKind: CaptureContentKind
    ) -> String {
        sourceApp == "WhatsApp" && contentKind == .conversation
            ? recentConversation
            : standard
    }
}
