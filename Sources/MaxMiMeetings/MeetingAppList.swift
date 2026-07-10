import Foundation

/// Kind of meeting app classification
public enum MeetingAppKind: Equatable {
    case native(String)
    case browser(String)
}

/// Allowlist of bundle IDs for meeting apps + classification
public struct MeetingAppList {
    /// All known meeting app bundle IDs
    public static let bundleIDs: Set<String> = [
        // Native meeting apps
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.tinyspeck.slackmacgap",
        // Browsers
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser"  // Arc
    ]

    private static let nativeApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.tinyspeck.slackmacgap": "Slack"
    ]

    private static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "com.operasoftware.Opera": "Opera",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "company.thebrowser.Browser": "Arc"
    ]

    /// Classify a bundle ID into a meeting app kind
    public static func classify(bundleID: String) -> MeetingAppKind? {
        if let name = nativeApps[bundleID] {
            return .native(name)
        }
        if let name = browsers[bundleID] {
            return .browser(name)
        }
        return nil
    }
}
