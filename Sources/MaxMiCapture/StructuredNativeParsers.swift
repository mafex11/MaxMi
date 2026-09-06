import Foundation
import MaxMiCore

public struct CalendarParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.calendar(window: window, app: app, sourceApp: "Calendar", prefix: "calendar")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.calendarContent(window: window, app: app, sourceApp: "Calendar")?.content
    }
}

public struct FantasticalParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.calendar(window: window, app: app, sourceApp: "Fantastical", prefix: "fantastical")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.calendarContent(window: window, app: app, sourceApp: "Fantastical")?.content
    }
}

public struct RemindersParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "Reminders", prefix: "reminder")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.taskContent(window: window, app: app, sourceApp: "Reminders")?.content
    }
}

public struct MicrosoftToDoParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "Microsoft To Do", prefix: "todo")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.taskContent(window: window, app: app, sourceApp: "Microsoft To Do")?.content
    }
}

public struct TodoistParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "Todoist", prefix: "todoist")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.taskContent(window: window, app: app, sourceApp: "Todoist")?.content
    }
}

public struct OmniFocusParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "OmniFocus", prefix: "omnifocus")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.taskContent(window: window, app: app, sourceApp: "OmniFocus")?.content
    }
}

public struct TogglParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.task(window: window, app: app, sourceApp: "Toggl", prefix: "toggl")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.taskContent(window: window, app: app, sourceApp: "Toggl")?.content
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
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.documentContent(window: window)
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
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.documentContent(window: window)
    }
}

public struct OutlookParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.email(window: window, app: app, sourceApp: "Outlook", prefix: "outlook")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.emailContent(window: window)
    }
}

public struct SparkParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.email(window: window, app: app, sourceApp: "Spark", prefix: "spark")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.emailContent(window: window)
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

    struct Extracted {
        let content: CapturedContent
        let sourceKey: String
        let sourceTitle: String
    }

    static func calendarContent(window: AXNode, app: AppInfo, sourceApp: String) -> Extracted? {
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
        // No organizer is exposed by these detail views, so the account/calendar name — the
        // closest thing to "who owns this event" — lands in `organizer`.
        let organizer = firstValue(fields, metadataHints: ["organizer", "invitee", "calendar-name", "account"])
        let hasConference = fields.contains { field in
            let value = field.value.lowercased()
            return value.contains("zoom.us") || value.contains("meet.google.com")
                || value.contains("teams.microsoft.com") || value.contains("join with")
        }
        // Everything the four named fields did not claim becomes the detail body, exactly as
        // the v1 `Details:` block did.
        let details = remainingValues(
            fields, excluding: [title, when, location, organizer].compactMap { $0 }
        )
        let event = CalendarEvent(
            title: title,
            dateString: when ?? "",
            start: nil, end: nil,
            organizer: organizer,
            location: location,
            hasConference: hasConference,
            notes: details.isEmpty ? nil : details.joined(separator: "\n")
        )
        let identity = [title, when ?? "", organizer ?? ""].joined(separator: "|")
        return Extracted(content: .calendar([event]),
                         sourceKey: "event:\(shortHash(identity))",
                         sourceTitle: title)
    }

    static func calendar(window: AXNode, app: AppInfo, sourceApp: String, prefix: String) -> ParsedCapture? {
        guard let extracted = calendarContent(window: window, app: app, sourceApp: sourceApp) else { return nil }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):\(extracted.sourceKey)",
            sourceTitle: extracted.sourceTitle,
            content: ContentRenderer.render(extracted.content, style: .full),
            contentKind: .calendar,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: .visibleOnly(maxCharacters: 32_000),
            structured: extracted.content
        )
    }

    static func taskContent(window: AXNode, app: AppInfo, sourceApp: String) -> Extracted? {
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
        let checked = ["1", "true", "yes", "checked"].contains(statusField?.value.lowercased() ?? "")
        let status: TaskStatus = statusField == nil ? .unknown : (checked ? .completed : .open)
        let details = remainingValues(
            fields, excluding: [title, due, project, statusField?.value].compactMap { $0 }
        )
        let item = TaskItem(
            title: title,
            status: status,
            due: nil,
            dueString: due,
            project: project,
            tags: [],
            notes: details.isEmpty ? nil : details.joined(separator: "\n")
        )
        let identity = [title, project ?? ""].joined(separator: "|")
        return Extracted(content: .tasks([item]),
                         sourceKey: "task:\(shortHash(identity))",
                         sourceTitle: title)
    }

    static func task(window: AXNode, app: AppInfo, sourceApp: String, prefix: String) -> ParsedCapture? {
        guard let extracted = taskContent(window: window, app: app, sourceApp: sourceApp) else { return nil }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):\(extracted.sourceKey)",
            sourceTitle: extracted.sourceTitle,
            content: ContentRenderer.render(extracted.content, style: .full),
            contentKind: .task,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: .visibleOnly(maxCharacters: 32_000),
            structured: extracted.content
        )
    }

    static let documentOffscreen: OffscreenCapturePolicy =
        .accessibilityScroll(maxSteps: 6, maxCharacters: 96_000)
    static let emailOffscreen: OffscreenCapturePolicy =
        .accessibilityScroll(maxSteps: 4, maxCharacters: 64_000)
    /// Preserves the 32_000 cap `DocumentExtraction.bodyText` applied here.
    static let pageBudget = 32_000

    /// Generic v2 over the whole window. The anchored document parsers land in Phase D.
    static func documentContent(window: AXNode) -> CapturedContent? {
        GenericV2Content.page(window: window, budget: pageBudget,
                              offscreenPolicy: documentOffscreen)
    }

    static func document(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        prefix: String,
        titleSuffixes: [String]
    ) -> ParsedCapture? {
        guard let structured = documentContent(window: window) else { return nil }
        var title = app.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for suffix in titleSuffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        if title.isEmpty { title = "untitled" }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):\(docSlug(title))",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: .document,
            parserVersion: 2,
            // Whole-page semantics (spec 4d): each extraction is the window's current state.
            accumulationPolicy: .replace,
            offscreenPolicy: documentOffscreen,
            structured: structured
        )
    }

    static func emailContent(window: AXNode) -> CapturedContent? {
        GenericV2Content.page(window: window, budget: pageBudget,
                              offscreenPolicy: emailOffscreen)
    }

    static func email(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        prefix: String
    ) -> ParsedCapture? {
        guard let structured = emailContent(window: window) else { return nil }
        let title = meaningfulWindowTitle(app.windowTitle, excluding: [sourceApp]) ?? "message"
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):message:\(shortHash(title))",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            // Outlook and Spark expose no sender or date, so they stay a page — but the kind
            // is still .email (spec 12 Q3).
            contentKind: .email,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: emailOffscreen,
            structured: structured
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

    private static func isChrome(_ value: String) -> Bool {
        chrome.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
