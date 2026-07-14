import Foundation
import MaxMiCore

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
    static let contentCap = 32_000
    static let perAccountLimit = 6      // most-recent N messages per account
    static let structuredHeader = "MAXMI_MAIL_V2"
    static let recordSeparator = "\u{1D}"
    static let fieldSeparator = "\u{1E}"
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let raw = Self.runAppleScript(Self.script) else { return nil }
        return Self.makeCapture(fromScriptOutput: raw, windowTitle: app.windowTitle)
    }

    /// Pure transform from raw osascript output → ParsedCapture (nil if no usable lines).
    /// Separated from the Process call so it's unit-testable without a live Mail app.
    static func makeCapture(fromScriptOutput raw: String, windowTitle: String?) -> ParsedCapture? {
        if raw.hasPrefix(structuredHeader) {
            return makeSelectedMessageCapture(fromScriptOutput: raw, windowTitle: windowTitle)
        }
        let lines = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let content = String(lines.joined(separator: "\n").suffix(contentCap))
        return ParsedCapture(sourceApp: "Mail", sourceKey: "mail:inbox",
                             sourceTitle: windowTitle, content: content,
                             contentKind: .email, parserVersion: 2,
                             accumulationPolicy: .rollingText,
                             offscreenPolicy: .accessibilityScroll(maxSteps: 3))
    }

    static func makeSelectedMessageCapture(
        fromScriptOutput raw: String,
        windowTitle: String?
    ) -> ParsedCapture? {
        let payload = raw.dropFirst(structuredHeader.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let records = payload.components(separatedBy: recordSeparator).compactMap { record -> MailRecord? in
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count >= 5 else { return nil }
            let body = fields.dropFirst(4).joined(separator: fieldSeparator)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let messageID = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let sender = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let date = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sender.isEmpty || !subject.isEmpty || !body.isEmpty else { return nil }
            return MailRecord(messageID: messageID, sender: sender, subject: subject, date: date, body: body)
        }
        guard !records.isEmpty else { return nil }

        let rendered = records.map { record in
            var lines: [String] = []
            if !record.sender.isEmpty { lines.append("From: \(record.sender)") }
            if !record.subject.isEmpty { lines.append("Subject: \(record.subject)") }
            if !record.date.isEmpty { lines.append("Date: \(record.date)") }
            if !record.body.isEmpty { lines.append(record.body) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n---\n\n")

        let identities = records.map {
            $0.messageID.isEmpty ? "\($0.sender)|\($0.subject)" : $0.messageID
        }.joined(separator: "|")
        let keyHash = String(ContentHash.sha256Hex(identities).prefix(24))
        let title = records.first(where: { !$0.subject.isEmpty })?.subject ?? windowTitle
        return ParsedCapture(
            sourceApp: "Mail",
            sourceKey: "mail:thread:\(keyHash)",
            sourceTitle: title,
            content: String(rendered.suffix(contentCap)),
            contentKind: .email,
            parserVersion: 2,
            accumulationPolicy: .rollingText,
            offscreenPolicy: .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000)
        )
    }

    struct MailRecord {
        let messageID: String
        let sender: String
        let subject: String
        let date: String
        let body: String
    }

    /// Per-account inbox read. Avoids the unified "inbox" (which errors -1741 on some setups)
    /// by iterating accounts and their INBOX mailboxes. Emits "account » sender | subject".
    static let script = """
    tell application "Mail"
        set fieldSep to character id 30
        set recordSep to character id 29
        try
            if (count of message viewers) > 0 then
                set selectedMessages to selected messages of front message viewer
                if (count of selectedMessages) > 0 then
                    set selectedOut to ""
                    repeat with m in selectedMessages
                        try
                            set msgID to message id of m
                        on error
                            set msgID to ""
                        end try
                        try
                            set msgDate to (date received of m) as string
                        on error
                            set msgDate to ""
                        end try
                        try
                            set msgBody to content of m
                        on error
                            set msgBody to ""
                        end try
                        set selectedOut to selectedOut & msgID & fieldSep & (sender of m) & fieldSep & (subject of m) & fieldSep & msgDate & fieldSep & msgBody & recordSep
                    end repeat
                    return "(structuredHeader)" & linefeed & selectedOut
                end if
            end if
        end try

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
