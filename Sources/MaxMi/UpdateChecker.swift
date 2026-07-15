import Foundation
import MaxMiCore

enum UpdateChecker {
    static let releaseURL = URL(string: "https://github.com/mafex11/MaxMi/releases/latest")!

    static func currentVersion() -> String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "dev"
        }
        return version
    }

    static func check() async -> UpdateStatus {
        // Releases are explicit and manual. The signed release manifest, checksum,
        // Developer ID signature, notarization, and Gatekeeper checks are authoritative.
        return .unknownManual
    }
}
