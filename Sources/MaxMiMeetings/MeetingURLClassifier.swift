import Foundation

public struct MeetingURLMatch: Sendable, Equatable {
    public let platform: String
    public let canonicalHost: String

    public init(platform: String, canonicalHost: String) {
        self.platform = platform
        self.canonicalHost = canonicalHost
    }
}

/// Strict URL proof for browser microphone activity. A recognized browser using
/// the microphone is not a meeting unless its active tab matches one of these routes.
public enum MeetingURLClassifier {
    public static func classify(_ urlString: String) -> MeetingURLMatch? {
        guard let components = URLComponents(string: urlString),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased() else { return nil }
        let path = components.path.lowercased()
        let query = components.query?.lowercased() ?? ""

        if host == "meet.google.com", path.split(separator: "/").first?.isEmpty == false {
            return MeetingURLMatch(platform: "Google Meet", canonicalHost: host)
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            if path.hasPrefix("/j/") || path.hasPrefix("/wc/") || path.hasPrefix("/s/") {
                return MeetingURLMatch(platform: "Zoom", canonicalHost: "zoom.us")
            }
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            if path.contains("meetup-join") || path.contains("/meeting/")
                || query.contains("meetingjoin") || query.contains("meetingid") {
                return MeetingURLMatch(platform: "Microsoft Teams", canonicalHost: host)
            }
        }
        if host == "app.slack.com" || host.hasSuffix(".slack.com") {
            if path.contains("/huddle") || path.contains("/call") {
                return MeetingURLMatch(platform: "Slack Huddle", canonicalHost: "app.slack.com")
            }
        }
        if host == "webex.com" || host.hasSuffix(".webex.com") {
            if path.contains("/meet/") || path.contains("/join/") || path.hasPrefix("/m/") {
                return MeetingURLMatch(platform: "Webex", canonicalHost: "webex.com")
            }
        }
        return nil
    }
}
