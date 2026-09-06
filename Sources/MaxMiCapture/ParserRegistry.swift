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
    public static let finderBundleID = "com.apple.finder"
    public static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    public static let vsCodeBundleID = "com.microsoft.VSCode"
    public static let editorBundleIDs = [cursorBundleID, vsCodeBundleID]
    // Terminal emulators — all share TerminalParser (single-AXTextArea scrollback shape).
    public static let terminalBundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp",
                                           "com.apple.Terminal", "com.googlecode.iterm2"]
    private let parsers: [String: any SourceParser]
    let structuredParsers: [String: any StructuredParser]
    let hostParsers: [String: any StructuredParser]

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
        // Structured (v2) parsers. Each one declares the bundle IDs and hosts it claims, so the
        // two maps below are derived, never hand-maintained in parallel with the list. Tasks 7-26
        // append to this ONE list; by the end of Phase D it holds the seventeen entries written
        // out in this task's Interfaces block, and `PhaseDCoverageTests` asserts that.
        let structured: [any StructuredParser] = []
        var byBundle: [String: any StructuredParser] = [:]
        var byHost: [String: any StructuredParser] = [:]
        for parser in structured {
            let config = type(of: parser).config
            for bundleID in config.bundleIDs { byBundle[bundleID] = parser }
            for host in config.hosts { byHost[host.lowercased()] = parser }
        }
        structuredParsers = byBundle
        hostParsers = byHost
        parsers = p
    }

    /// Test seam: a registry with an explicit parser table. `CaptureDispatch`'s not-handled /
    /// refused / threw branches have to be exercised against parsers that do exactly one of those
    /// things, and no shipping parser throws a non-refusal error to borrow for that.
    init(parsers: [String: any SourceParser]) {
        self.parsers = parsers
        // A seam registry exercises the v1 dispatch branches only; it registers no v2 parser.
        self.structuredParsers = [:]
        self.hostParsers = [:]
    }

    /// Routing tests build a registry with exactly the parsers under test, so a future
    /// registration cannot silently change what a routing assertion is measuring.
    init(structuredParsers: [any StructuredParser], hostParsers: [any StructuredParser]) {
        parsers = [:]
        var byBundle: [String: any StructuredParser] = [:]
        var byHost: [String: any StructuredParser] = [:]
        for parser in structuredParsers {
            for bundleID in type(of: parser).config.bundleIDs { byBundle[bundleID] = parser }
        }
        for parser in hostParsers {
            for host in type(of: parser).config.hosts { byHost[host.lowercased()] = parser }
        }
        self.structuredParsers = byBundle
        self.hostParsers = byHost
    }

    public func parser(for bundleID: String) -> (any SourceParser)? {
        parsers[bundleID]
    }
}

/// Thrown by a parser that will not let this window be stored at all, as distinct from returning
/// nil, which only means "I can't read this shape" and lets the generic extractor stand in.
///
/// A conversation parser uses this when a generic capture would be actively wrong: WhatsApp with
/// no confirmed chat header would otherwise store the sidebar list of every unopened chat.
public struct ParserRefusal: Error, Sendable, Equatable {
    /// A fixed, token-safe slug — never captured content, since it is logged verbatim.
    /// Must satisfy `SafeLogToken(validating:)` or it is dropped from the log line.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public enum CaptureDispatch {
    public enum ParseResult: Sendable, Equatable {
        case parsed(ParsedCapture)
        /// A registered parser returned nil or threw, and the generic extractor stood in.
        /// `failedParser` is the type name, for the capture-health marker.
        case parsedByFallback(ParsedCapture, failedParser: String)
        case noContent
        /// No longer produced by `parseDetailed` — a parser throwing now falls through to the
        /// generic extractor. Kept because `AppWiring` still switches on it and
        /// `CaptureHealthStore` still records `.parserFailed` for other callers.
        case failed
    }

    public enum CommitDecision: Sendable, Equatable {
        case commit
        case blocked
        case paused
    }

    /// Decide what to store for a frontmost app's window. Returns nil = skip.
    public static func parse(window: AXNode, app: AppInfo, registry: ParserRegistry) -> ParsedCapture? {
        switch parseDetailed(window: window, app: app, registry: registry) {
        case .parsed(let parsed):                 return parsed
        case .parsedByFallback(let parsed, _):    return parsed
        case .noContent, .failed:                 return nil
        }
    }

    /// Diagnostic form of `parse`: distinguishes empty/not-handled from a generic fallback
    /// without ever carrying captured content into logs or the health ledger.
    ///
    /// A registered parser that returns nil or throws now FALLS THROUGH to
    /// `GenericPageExtractor` (spec 4f rule 3). This deliberately reverses the old
    /// no-silent-fallback rule: a broken or over-narrow parser must degrade to a worse
    /// capture, not to no capture. It stays non-silent because the caller records
    /// "GenericPageExtractor.v2/fallback/<ParserTypeName>" in `capture_health_events.parser`.
    public static func parseDetailed(window: AXNode, app: AppInfo, registry: ParserRegistry) -> ParseResult {
        if let parser = registry.parser(for: app.bundleID) {
            let parserName = String(describing: type(of: parser))
            do {
                if let result = try parser.parse(window: window, app: app) {
                    return .parsed(result)
                }
                SafeLogger.shared.log(
                    .info,
                    subsystem: .capture,
                    event: .parserNoContent,
                    fields: SafeLogFields(parserID: SafeLogToken(validating: parserName))
                )
            } catch let refusal as ParserRefusal {
                // REFUSE, not NOT-HANDLED: the parser has decided a generic capture of this
                // window would be wrong, so rule 3 does not apply and nothing is stored.
                SafeLogger.shared.log(
                    .info,
                    subsystem: .capture,
                    event: .parserRefused,
                    fields: SafeLogFields(
                        parserID: SafeLogToken(validating: parserName),
                        outcome: SafeLogToken(validating: refusal.reason)
                    )
                )
                return .noContent
            } catch {
                SafeLogger.shared.log(
                    .error,
                    subsystem: .capture,
                    event: .parserFailed,
                    error: error,
                    fields: SafeLogFields(parserID: SafeLogToken(validating: parserName))
                )
            }
            // The fallback re-keys this window as "bundleID:windowTitle", so an app whose
            // dedicated parser split it into per-thread keys collapses into one coarse thread
            // while it is degraded. Accepted for Phase A; Phase D revisits fallback keying.
            guard let fallback = genericCapture(window: window, app: app) else { return .noContent }
            return .parsedByFallback(fallback, failedParser: parserName)
        }
        guard let result = genericCapture(window: window, app: app) else { return .noContent }
        return .parsed(result)
    }

    /// The `capture_health_events.parser` marker for a degraded capture (spec 8). Composed here
    /// rather than at each call site so the health ledger and its tests agree on one spelling.
    public static func fallbackParserID(failedParser: String) -> String {
        "GenericPageExtractor.v2/fallback/\(failedParser)"
    }

    /// `GenericPageExtractor` is pure and total, so the only nil here is "no readable content".
    /// A throw is therefore not expected — it is logged rather than swallowed so that if the
    /// generic path ever does start throwing, it does not disappear as a silent skip.
    private static func genericCapture(window: AXNode, app: AppInfo) -> ParsedCapture? {
        do {
            return try GenericAXParser().parse(window: window, app: app)
        } catch {
            SafeLogger.shared.log(
                .error,
                subsystem: .capture,
                event: .parserFailed,
                error: error,
                fields: SafeLogFields(parserID: SafeLogToken(validating: "GenericAXParser"))
            )
            return nil
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
