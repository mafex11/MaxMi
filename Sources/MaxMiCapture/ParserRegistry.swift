import Foundation

public struct ParserRegistry: Sendable {
    public static let slackBundleID = "com.tinyspeck.slackmacgap"
    public static let notionBundleID = "notion.id"
    public static let obsidianBundleID = "md.obsidian"
    public static let notesBundleID = "com.apple.Notes"
    // Terminal emulators — all share TerminalParser (single-AXTextArea scrollback shape).
    public static let terminalBundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp",
                                           "com.apple.Terminal", "com.googlecode.iterm2"]
    private let parsers: [String: any SourceParser]

    public init() {
        var p: [String: any SourceParser] = [
            Self.slackBundleID: SlackParser(),
            Self.notionBundleID: NotionParser(),
            Self.obsidianBundleID: ObsidianParser(),
            Self.notesBundleID: NotesParser(),
        ]
        for bid in Self.terminalBundleIDs { p[bid] = TerminalParser() }
        parsers = p
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

    /// Pure decision: should this parsed capture commit or be skipped?
    /// Checks native denylist and per-thread pause set.
    public static func shouldCommit(parsed: ParsedCapture, pausedThreads: Set<String>) -> Bool {
        if Denylist.isBlocked(parsed.sourceKey) { return false }
        if pausedThreads.contains(parsed.sourceKey) { return false }
        return true
    }
}
