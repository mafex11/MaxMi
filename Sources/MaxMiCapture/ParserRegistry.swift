import Foundation

public struct ParserRegistry: Sendable {
    public static let slackBundleID = "com.tinyspeck.slackmacgap"
    private let parsers: [String: any SourceParser]

    public init() {
        parsers = [Self.slackBundleID: SlackParser()]
    }

    public func parser(for bundleID: String) -> (any SourceParser)? {
        parsers[bundleID]
    }
}

public enum CaptureDispatch {
    /// Decide what to store for a frontmost app's window. Returns nil = skip.
    /// registeredParser nil => use generic. A registered parser returning nil/throwing
    /// => nil (NEVER fall through to generic) — the no-silent-fallback rule.
    public static func parse(window: AXNode, app: AppInfo, registry: ParserRegistry) -> ParsedCapture? {
        if let parser = registry.parser(for: app.bundleID) {
            // No-silent-fallback: registered parser owns this app. nil/throw -> skip, never generic.
            do {
                guard let result = try parser.parse(window: window, app: app) else {
                    FileHandle.standardError.write(Data("maxmi: parser for \(app.bundleID) returned nil (skipped)\n".utf8))
                    return nil
                }
                return result
            } catch {
                FileHandle.standardError.write(Data("maxmi: parser for \(app.bundleID) threw: \(error)\n".utf8))
                return nil
            }
        }
        return (try? GenericAXParser().parse(window: window, app: app)) ?? nil
    }
}
