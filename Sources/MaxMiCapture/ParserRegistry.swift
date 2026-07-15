import Foundation
import MaxMiCore

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
    public static let calendarBundleIDs = ["com.apple.iCal"]
    public static let fantasticalBundleIDs = ["com.flexibits.fantastical2.mac"]
    public static let remindersBundleIDs = ["com.apple.reminders"]
    public static let microsoftToDoBundleIDs = ["com.microsoft.to-do-mac"]
    public static let todoistBundleIDs = ["com.todoist.mac.Todoist"]
    public static let omniFocusBundleIDs = ["com.omnigroup.OmniFocus3", "com.omnigroup.OmniFocus4"]
    public static let togglBundleIDs = ["com.toggl.toggldesktop"]
    public static let wordBundleIDs = ["com.microsoft.Word"]
    public static let pagesBundleIDs = ["com.apple.iWork.Pages"]
    public static let outlookBundleIDs = ["com.microsoft.Outlook"]
    public static let sparkBundleIDs = ["com.readdle.smartemail-Mac", "com.readdle.SparkDesktop"]
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
        for bid in Self.calendarBundleIDs { p[bid] = CalendarParser() }
        for bid in Self.fantasticalBundleIDs { p[bid] = FantasticalParser() }
        for bid in Self.remindersBundleIDs { p[bid] = RemindersParser() }
        for bid in Self.microsoftToDoBundleIDs { p[bid] = MicrosoftToDoParser() }
        for bid in Self.todoistBundleIDs { p[bid] = TodoistParser() }
        for bid in Self.omniFocusBundleIDs { p[bid] = OmniFocusParser() }
        for bid in Self.togglBundleIDs { p[bid] = TogglParser() }
        for bid in Self.wordBundleIDs { p[bid] = WordParser() }
        for bid in Self.pagesBundleIDs { p[bid] = PagesParser() }
        for bid in Self.outlookBundleIDs { p[bid] = OutlookParser() }
        for bid in Self.sparkBundleIDs { p[bid] = SparkParser() }
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
                    SafeLogger.shared.log(
                        .info,
                        subsystem: .capture,
                        event: .parserNoContent,
                        fields: SafeLogFields(
                            parserID: SafeLogToken(validating: String(describing: type(of: parser)))
                        )
                    )
                    return .noContent
                }
                return .parsed(result)
            } catch {
                SafeLogger.shared.log(
                    .error,
                    subsystem: .capture,
                    event: .parserFailed,
                    error: error,
                    fields: SafeLogFields(
                        parserID: SafeLogToken(validating: String(describing: type(of: parser)))
                    )
                )
                return .failed
            }
        }
        do {
            guard let result = try GenericAXParser().parse(window: window, app: app) else {
                return .noContent
            }
            return .parsed(result)
        } catch {
            SafeLogger.shared.log(
                .error,
                subsystem: .capture,
                event: .parserFailed,
                error: error,
                fields: SafeLogFields(parserID: SafeLogToken(validating: "GenericAXParser"))
            )
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
