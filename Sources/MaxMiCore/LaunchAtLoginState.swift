import Foundation

public enum LaunchAtLoginState: Sendable, Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case unavailable
}

public enum UpdateStatus: Sendable, Equatable {
    case unknownManual
}
