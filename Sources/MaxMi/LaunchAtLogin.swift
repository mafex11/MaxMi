import Foundation
import ServiceManagement
import MaxMiCore

enum LaunchAtLogin {
    static func status() -> LaunchAtLoginState {
        let serviceStatus = SMAppService.mainApp.status
        switch serviceStatus {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    static func setEnabled(_ on: Bool) async throws {
        if on {
            // Guard against register when already enabled
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            try await SMAppService.mainApp.unregister()
        }
    }
}
