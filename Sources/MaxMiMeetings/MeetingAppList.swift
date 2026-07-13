import Foundation
import MaxMiCore

/// Kind of meeting app classification
public enum MeetingAppKind: Equatable {
    case native(String)
    case browser(String)
}

/// Allowlist of bundle IDs for meeting apps + classification
public struct MeetingAppList {
    public static var bundleIDs: Set<String> {
        Set(
            (ApplicationRegistry.browsers + ApplicationRegistry.nativeMeetingApps)
                .filter { $0.meetingDetection != .none }
                .map(\.bundleID)
        )
    }

    /// Classify a bundle ID into a meeting app kind
    public static func classify(bundleID: String) -> MeetingAppKind? {
        guard let app = ApplicationRegistry.descriptor(for: bundleID) else { return nil }
        switch app.meetingDetection {
        case .nativeAudio:
            return .native(app.displayName)
        case .browserURLRequired:
            return .browser(app.displayName)
        case .none:
            return nil
        }
    }
}
