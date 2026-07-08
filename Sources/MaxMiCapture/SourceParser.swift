import Foundation

public struct AppInfo: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let windowTitle: String?
    public init(bundleID: String, name: String, windowTitle: String?) {
        self.bundleID = bundleID; self.name = name; self.windowTitle = windowTitle
    }
}

public struct ParsedCapture: Sendable, Equatable {
    public let sourceApp: String
    public let sourceKey: String
    public let sourceTitle: String?
    public let content: String
    public init(sourceApp: String, sourceKey: String, sourceTitle: String?, content: String) {
        self.sourceApp = sourceApp; self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle; self.content = content
    }
}

/// Turns a window's AX tree into a capture, or nil if it can't handle it.
/// Throwing is treated identically to nil by the caller (log + skip), never a crash.
public protocol SourceParser: Sendable {
    func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture?
}
