import Foundation
import MaxMiCore

enum UpdateChecker {
    static func currentVersion() -> String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "dev"
        }
        return version
    }

    static func check() async -> UpdateStatus {
        // M6c: honest — no update endpoint, no trust policy, no auto-update
        // Always return unknownManual; settings UI will show "updates are manual"
        return .unknownManual
    }
}
