import Foundation
import MaxMiCore

/// The privacy decision shared by focus and typing event writers.
///
/// Browser URL policy is intentionally evaluated before either writer reads a focused field or
/// persists a title. A browser whose URL cannot be resolved is safe enough to record its app
/// focus, but not its title or typed text.
public enum EventPrivacyGate {
    public struct Decision: Sendable, Equatable {
        public let writesFocusEvent: Bool
        public let writesTypingEvent: Bool
        public let includesFocusWindowTitle: Bool

        public init(
            writesFocusEvent: Bool,
            writesTypingEvent: Bool,
            includesFocusWindowTitle: Bool
        ) {
            self.writesFocusEvent = writesFocusEvent
            self.writesTypingEvent = writesTypingEvent
            self.includesFocusWindowTitle = includesFocusWindowTitle
        }
    }

    private static let denyAll = Decision(
        writesFocusEvent: false,
        writesTypingEvent: false,
        includesFocusWindowTitle: false
    )
    private static let allowed = Decision(
        writesFocusEvent: true,
        writesTypingEvent: true,
        includesFocusWindowTitle: true
    )
    private static let unresolvedBrowser = Decision(
        writesFocusEvent: true,
        writesTypingEvent: false,
        includesFocusWindowTitle: false
    )

    public static func decision(
        bundleID: String,
        isAppEligible: Bool,
        browserURL: String?,
        blockedDomains: Set<String>
    ) -> Decision {
        guard isAppEligible, !Denylist.isSensitiveApp(bundleID) else { return denyAll }
        guard ApplicationRegistry.isBrowser(bundleID) else { return allowed }
        guard let browserURL else { return unresolvedBrowser }
        guard !Denylist.isBlockedWebURL(browserURL),
              !Denylist.isBlockedByUser(browserURL, blockedDomains: blockedDomains) else {
            return denyAll
        }
        return allowed
    }
}
