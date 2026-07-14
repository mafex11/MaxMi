import Foundation
import MaxMiCore

public struct CalendarParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.calendar(window: window, app: app, sourceApp: "Calendar", prefix: "calendar")
    }
}

public struct FantasticalParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.calendar(window: window, app: app, sourceApp: "Fantastical", prefix: "fantastical")
    }
}

public struct RemindersParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "Reminders", prefix: "reminder")
    }
}

public struct MicrosoftToDoParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "Microsoft To Do", prefix: "todo")
    }
}

public struct TodoistParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "Todoist", prefix: "todoist")
    }
}

public struct OmniFocusParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "OmniFocus", prefix: "omnifocus")
    }
}

public struct TogglParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "Toggl", prefix: "toggl")
    }
}

public struct WordParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.document(
            window: window, app: app, sourceApp: "Microsoft Word", prefix: "word",
            titleSuffixes: [" - Microsoft Word", " — Microsoft Word"]
        )
    }
}

public struct PagesParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.document(
            window: window, app: app, sourceApp: "Pages", prefix: "pages",
            titleSuffixes: [" - Pages", " — Pages"]
        )
    }
}

public struct OutlookParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.email(window: window, app: app, sourceApp: "Outlook", prefix: "outlook")
    }
}

public struct SparkParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.email(window: window, app: app, sourceApp: "Spark", prefix: "spark")
    }
}

enum StructuredEntityExtraction {
    struct Field {
        let role: String
        let value: String
        let metadata: String
        let y: CGFloat
        let x: CGFloat
    }

    static let readableRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCheckBox",
    ]
    static let chrome: Set<String> = [
        "calendar", "today", "day", "week", "month", "year", "inbox", "search",
        "reminders", "completed", "flagged", "all", "scheduled", "add list", "settings",
    ]

    static func calendar(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        prefix: String
    ) -> ParsedCapture? {
        let root = preferredDetailRoot(in: window, hints: ["event", "detail", "popover"])
        let fields = orderedFields(in: root)
        guard !fields.isEmpty else { return nil }

        let title = firstValue(fields, metadataHints: ["title", "summary", "event-name"])
            ?? fields.first(where: { $0.role == "AXHeading" && !isChrome($0.value) })?.value
            ?? meaningfulWindowTitle(app.windowTitle, excluding: [sourceApp, "Calendar"])
        guard let title, !title.isEmpty else { return nil }
        let when = firstValue(fields, metadataHints: ["date", "time", "start", "end"])
            ?? fields.first(where: { looksLikeDateOrTime($0.value) })?.value
        let location = firstValue(fields, metadataHints: ["location", "place"])
        let calendarName = firstValue(fields, metadataHints: ["calendar-name", "account"])
        let details = remainingValues(
            fields, excluding: [title, when, location, calendarName].compactMap { $0 }
        )

        var lines = ["Event: \(title)"]
        if let when { lines.append("When: \(when)") }
        if let location { lines.append("Location: \(location)") }
        if let calendarName { lines.append("Calendar: \(calendarName)") }
        if !details.isEmpty { lines.append("Details:\n" + details.joined(separator: "\n")) }
        let identity = [title, when ?? "", calendarName ?? ""].joined(separator: "|")
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):event:\(shortHash(identity))",
            sourceTitle: title,
            content: bounded(lines.joined(separator: "\n")),
            contentKind: .calendar,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
        )
    }

    static func task(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        prefix: String
    ) -> ParsedCapture? {
        let root = preferredDetailRoot(in: window, hints: ["task", "reminder", "detail"])
        let fields = orderedFields(in: root)
        guard !fields.isEmpty else { return nil }

        let title = firstValue(fields, metadataHints: ["title", "name", "task-title", "reminder-title"])
            ?? fields.first(where: { $0.role == "AXHeading" && !isChrome($0.value) })?.value
            ?? meaningfulWindowTitle(app.windowTitle, excluding: [sourceApp, "Reminders"])
        guard let title, !title.isEmpty else { return nil }
        let due = firstValue(fields, metadataHints: ["due", "date", "time"])
            ?? fields.first(where: { looksLikeDateOrTime($0.value) })?.value
        let project = firstValue(fields, metadataHints: ["list", "project", "section"])
        let statusField = fields.first { $0.role == "AXCheckBox" || $0.metadata.contains("completed") }
        let status: String
        if let value = statusField?.value.lowercased(), ["1", "true", "yes", "checked"].contains(value) {
            status = "completed"
        } else {
            status = "open"
        }
        let details = remainingValues(
            fields, excluding: [title, due, project, statusField?.value].compactMap { $0 }
        )

        var lines = ["Task: \(title)", "Status: \(status)"]
        if let project { lines.append("List: \(project)") }
        if let due { lines.append("Due: \(due)") }
        if !details.isEmpty { lines.append("Details:\n" + details.joined(separator: "\n")) }
        let identity = [title, project ?? ""].joined(separator: "|")
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):task:\(shortHash(identity))",
            sourceTitle: title,
            content: bounded(lines.joined(separator: "\n")),
            contentKind: .task,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
        )
    }

    static func document(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        prefix: String,
        titleSuffixes: [String]
    ) -> ParsedCapture? {
        let content = DocumentExtraction.bodyText(in: window, maxCharacters: 32_000)
        guard !content.isEmpty else { return nil }
        var title = app.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for suffix in titleSuffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        if title.isEmpty { title = "untitled" }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):\(docSlug(title))",
            sourceTitle: app.windowTitle,
            content: content,
            contentKind: .document,
            parserVersion: 2,
            accumulationPolicy: .rollingText,
            offscreenPolicy: .accessibilityScroll(maxSteps: 6, maxCharacters: 96_000)
        )
    }

    static func email(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        prefix: String
    ) -> ParsedCapture? {
        let content = DocumentExtraction.bodyText(in: window, maxCharacters: 32_000)
        guard !content.isEmpty else { return nil }
        let title = meaningfulWindowTitle(app.windowTitle, excluding: [sourceApp]) ?? "message"
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):message:\(shortHash(title))",
            sourceTitle: app.windowTitle,
            content: content,
            contentKind: .email,
            parserVersion: 2,
            accumulationPolicy: .rollingText,
            offscreenPolicy: .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000)
        )
    }

    private static func preferredDetailRoot(in root: AXNode, hints: [String]) -> AXNode {
        let metadata = [root.identifier, root.label, root.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if ["AXSheet", "AXPopover", "AXDialog"].contains(root.role)
            || hints.contains(where: metadata.contains) {
            return root
        }
        for child in root.children {
            let preferred = preferredDetailRoot(in: child, hints: hints)
            if preferred.role != child.role || preferred.identifier != child.identifier
                || isPreferred(child, hints: hints) {
                return preferred
            }
        }
        return root
    }

    private static func isPreferred(_ node: AXNode, hints: [String]) -> Bool {
        if ["AXSheet", "AXPopover", "AXDialog"].contains(node.role) { return true }
        let metadata = [node.identifier, node.label, node.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return hints.contains(where: metadata.contains)
    }

    private static func orderedFields(in root: AXNode) -> [Field] {
        var fields: [Field] = []
        collectFields(root, into: &fields)
        return fields.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
    }

    private static func collectFields(_ node: AXNode, into out: inout [Field]) {
        if readableRoles.contains(node.role), let raw = node.value ?? node.title {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                let metadata = [node.identifier, node.label, node.title]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                out.append(Field(
                    role: node.role, value: value, metadata: metadata,
                    y: node.frame?.minY ?? 0, x: node.frame?.minX ?? 0
                ))
            }
        }
        for child in node.children { collectFields(child, into: &out) }
    }

    private static func firstValue(_ fields: [Field], metadataHints: [String]) -> String? {
        fields.first { field in metadataHints.contains(where: field.metadata.contains) }?.value
    }

    private static func remainingValues(_ fields: [Field], excluding: [String]) -> [String] {
        var seen = Set<String>()
        return fields.compactMap { field in
            let normalized = field.value.lowercased()
            guard !excluding.contains(where: { $0.caseInsensitiveCompare(field.value) == .orderedSame }),
                  !isChrome(field.value), seen.insert(normalized).inserted else { return nil }
            return field.value
        }
    }

    private static func looksLikeDateOrTime(_ value: String) -> Bool {
        let lower = value.lowercased()
        let tokens = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june", "july", "august",
            "september", "october", "november", "december", "am", "pm", "tomorrow", "today",
        ]
        return tokens.contains(where: lower.contains)
    }

    private static func meaningfulWindowTitle(_ title: String?, excluding: [String]) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return excluding.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) ? nil : title
    }

    private static func shortHash(_ value: String) -> String {
        String(ContentHash.sha256Hex(value).prefix(24))
    }

    private static func bounded(_ value: String) -> String {
        String(value.suffix(32_000))
    }

    private static func isChrome(_ value: String) -> Bool {
        chrome.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
