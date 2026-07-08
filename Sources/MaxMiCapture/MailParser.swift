import Foundation

/// Dedicated parser for Apple Mail.
///
/// IMPORTANT: Mail's accessibility tree is pathologically slow (~80ms per node — reaching the
/// message list would take minutes), so AX-tree walking is NOT viable here. Instead we read
/// Mail via its AppleScript interface (fast: recent messages across all accounts in ~1s).
/// This is the only parser that ignores the AX `window` and sources its own data.
///
/// Requires Automation (AppleEvents) permission for MaxMi → Mail; the first run triggers the
/// system prompt. If scripting is unavailable/denied, parse returns nil (→ skipped, per the
/// no-silent-fallback rule) rather than crashing.
public struct MailParser: SourceParser {
    static let contentCap = 8000
    static let perAccountLimit = 6      // most-recent N messages per account
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let raw = Self.runAppleScript(Self.script) else { return nil }
        return Self.makeCapture(fromScriptOutput: raw, windowTitle: app.windowTitle)
    }

    /// Pure transform from raw osascript output → ParsedCapture (nil if no usable lines).
    /// Separated from the Process call so it's unit-testable without a live Mail app.
    static func makeCapture(fromScriptOutput raw: String, windowTitle: String?) -> ParsedCapture? {
        let lines = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let content = String(lines.joined(separator: "\n").suffix(contentCap))
        return ParsedCapture(sourceApp: "Mail", sourceKey: "mail:inbox",
                             sourceTitle: windowTitle, content: content)
    }

    /// Per-account inbox read. Avoids the unified "inbox" (which errors -1741 on some setups)
    /// by iterating accounts and their INBOX mailboxes. Emits "account » sender | subject".
    static let script = """
    tell application "Mail"
        set out to ""
        repeat with acct in accounts
            set acctName to name of acct
            try
                repeat with mb in (mailboxes of acct)
                    if (name of mb) is "INBOX" or (name of mb) is "Inbox" then
                        set msgs to (messages of mb)
                        set n to count of msgs
                        if n > \(perAccountLimit) then set n to \(perAccountLimit)
                        repeat with i from 1 to n
                            set m to item i of msgs
                            try
                                set out to out & acctName & " » " & (sender of m) & " | " & (subject of m) & linefeed
                            end try
                        end repeat
                    end if
                end repeat
            end try
        end repeat
        return out
    end tell
    """

    /// Run an AppleScript via /usr/bin/osascript. Returns stdout, or nil on failure/timeout.
    /// Synchronous — safe because capture already runs off the main thread.
    static func runAppleScript(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()   // swallow AppleScript errors (e.g. perms) — parse returns nil
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}
