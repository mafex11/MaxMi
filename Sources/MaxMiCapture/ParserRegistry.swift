import Foundation

public struct ParserRegistry: Sendable {
    public static let slackBundleID = "com.tinyspeck.slackmacgap"
    public static let notionBundleID = "notion.id"
    public static let obsidianBundleID = "md.obsidian"
    public static let notesBundleID = "com.apple.Notes"
    public static let mailBundleID = "com.apple.mail"
    public static let discordBundleID = "com.hnc.Discord"
    public static let messagesBundleID = "com.apple.MobileSMS"
    public static let whatsAppBundleIDs = ["net.whatsapp.WhatsApp"]
    public static let teamsBundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]
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
            Self.mailBundleID: MailParser(),
            Self.discordBundleID: DiscordParser(),
            Self.messagesBundleID: MessagesParser(),
        ]
        for bid in Self.terminalBundleIDs { p[bid] = TerminalParser() }
        for bid in Self.whatsAppBundleIDs { p[bid] = WhatsAppParser() }
        for bid in Self.teamsBundleIDs { p[bid] = TeamsParser() }
        parsers = p
    }

    public func parser(for bundleID: String) -> (any SourceParser)? {
        parsers[bundleID]
    }
}

public enum CaptureDispatch {
    public enum ParseResult: Sendable, Equatable {
        case parsed(ParsedCapture)
        case noContent
        case failed
    }

    public enum CommitDecision: Sendable, Equatable {
        case commit
        case blocked
        case paused
    }

    /// Decide what to store for a frontmost app's window. Returns nil = skip.
    /// registeredParser nil => use generic. A registered parser returning nil/throwing
    /// => nil (NEVER fall through to generic) — the no-silent-fallback rule.
    public static func parse(window: AXNode, app: AppInfo, registry: ParserRegistry) -> ParsedCapture? {
        guard case .parsed(let parsed) = parseDetailed(window: window, app: app, registry: registry) else {
            return nil
        }
        return parsed
    }

    /// Diagnostic form of `parse`: distinguishes empty/not-handled from a parser failure
    /// without ever carrying captured content into logs or the health ledger.
    public static func parseDetailed(window: AXNode, app: AppInfo, registry: ParserRegistry) -> ParseResult {
        if let parser = registry.parser(for: app.bundleID) {
            // No-silent-fallback: registered parser owns this app. nil/throw -> skip, never generic.
            do {
                guard let result = try parser.parse(window: window, app: app) else {
                    FileHandle.standardError.write(Data("maxmi: parser for \(app.bundleID) returned nil (skipped)\n".utf8))
                    return .noContent
                }
                return .parsed(result)
            } catch {
                FileHandle.standardError.write(Data("maxmi: parser for \(app.bundleID) threw: \(error)\n".utf8))
                return .failed
            }
        }
        do {
            guard let result = try GenericAXParser().parse(window: window, app: app) else {
                return .noContent
            }
            return .parsed(result)
        } catch {
            return .failed
        }
    }

    /// Pure decision: should this parsed capture commit or be skipped?
    /// Checks native denylist (on raw key) and per-thread pause set (on clean key + compat raw key).
    public static func shouldCommit(parsed: ParsedCapture, cleanKey: String, pausedThreads: Set<String>) -> Bool {
        decision(parsed: parsed, cleanKey: cleanKey, pausedThreads: pausedThreads) == .commit
    }

    public static func decision(parsed: ParsedCapture, cleanKey: String, pausedThreads: Set<String>) -> CommitDecision {
        // Denylist: match on raw key (adult-URL denylist must match raw URLs)
        if Denylist.isBlocked(parsed.sourceKey) { return .blocked }
        // Pause: match on clean key (new pauses) OR raw key (compat: pre-existing pauses from before this branch)
        if pausedThreads.contains(cleanKey) || pausedThreads.contains(parsed.sourceKey) { return .paused }
        return .commit
    }
}

public extension ParserRegistry {
    func parserName(for bundleID: String) -> String {
        if let parser = parser(for: bundleID) {
            return String(describing: type(of: parser))
        }
        return "GenericAXParser"
    }
}
