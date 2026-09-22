import Foundation
import MaxMiCore

public struct CalendarParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)),
              case .calendar(let events) = unbounded,
              let event = events.first else { return nil }
        let content = CaptureAccumulator.boundHard(
            unbounded,
            to: Self.config.offscreenPolicy.maxCharacters
        )
        let identity = [event.title, event.dateString, event.organizer ?? ""].joined(separator: "|")
        return ParsedCapture(
            sourceApp: "Calendar",
            sourceKey: "calendar:event:\(String(ContentHash.sha256Hex(identity).prefix(24)))",
            sourceTitle: event.title,
            content: ContentRenderer.render(content, style: .full),
            contentKind: .calendar,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: content,
            truncated: content != unbounded
        )
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
}

public struct FantasticalParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)),
              case .calendar(let events) = unbounded,
              let event = events.first else { return nil }
        let content = CaptureAccumulator.boundHard(
            unbounded,
            to: Self.config.offscreenPolicy.maxCharacters
        )
        let identity = [event.title, event.dateString, event.organizer ?? ""].joined(separator: "|")
        return ParsedCapture(
            sourceApp: "Fantastical",
            sourceKey: "fantastical:event:\(String(ContentHash.sha256Hex(identity).prefix(24)))",
            sourceTitle: event.title,
            content: ContentRenderer.render(content, style: .full),
            contentKind: .calendar,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: content,
            truncated: content != unbounded
        )
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }
}

/// `.calendar` events for a window. Phase A already retyped this anchor — `calendarContent`
/// resolves the detail root, scores the fields and builds the `CalendarEvent` — so this is a thin
/// adapter that lets a `StructuredParser` reach it, NOT a second extractor (spec §7c, ruling
/// F15's no-duplicate-implementations rule).
enum CalendarStructuredExtraction {
    static func events(in window: AXNode, context: ParseContext, sourceApp: String) throws
        -> [CalendarEvent]? {
        guard let detailRoot = StructuredEntityExtraction.calendarDetailRoot(in: window) else {
            return nil
        }
        guard let extracted = StructuredEntityExtraction.calendarContent(
                detailRoot: detailRoot, context: context, sourceApp: sourceApp),
              case .calendar(let events) = extracted.content else { return [] }
        return events
    }

    static func isKnownNonContentSurface(in window: AXNode) -> Bool {
        window.children.isEmpty || window.children.allSatisfy {
            $0.role == "AXToolbar" || $0.identifier?.contains("calendar-sidebar") == true
        }
    }
}

extension CalendarParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Calendar",
        bundleIDs: ParserRegistry.calendarBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        guard let events = try CalendarStructuredExtraction.events(
            in: snapshot,
            context: context,
            sourceApp: Self.config.app
        ) else {
            if CalendarStructuredExtraction.isKnownNonContentSurface(in: snapshot) {
                throw ParserRefusal(reason: "unmatched-calendar-window")
            }
            return nil
        }
        return events.isEmpty ? nil : .calendar(events)
    }
}

extension FantasticalParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Fantastical",
        bundleIDs: ParserRegistry.fantasticalBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        guard let events = try CalendarStructuredExtraction.events(
            in: snapshot,
            context: context,
            sourceApp: Self.config.app
        ) else {
            if CalendarStructuredExtraction.isKnownNonContentSurface(in: snapshot) {
                throw ParserRefusal(reason: "unmatched-calendar-window")
            }
            return nil
        }
        return events.isEmpty ? nil : .calendar(events)
    }
}

public struct RemindersParser: SourceParser {
    private struct ParsedTasks {
        let content: CapturedContent
        let identity: TaskItem
        let truncated: Bool
    }

    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let result = try Self.v2Result(in: window, context: ParseContext(app: app)) else {
            return nil
        }
        let content = result.content
        let identity = [result.identity.title, result.identity.project ?? ""].joined(separator: "|")
        return ParsedCapture(
            sourceApp: "Reminders",
            sourceKey: "reminder:task:\(String(ContentHash.sha256Hex(identity).prefix(24)))",
            sourceTitle: result.identity.title,
            content: ContentRenderer.render(content, style: .full),
            contentKind: .task,
            parserVersion: 3,
            accumulationPolicy: .replace,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: content,
            truncated: result.truncated
        )
    }

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
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
        StructuredEntityExtraction.documentContent(window: window)?.content
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
        StructuredEntityExtraction.documentContent(window: window)?.content
    }
}

public struct OutlookParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.email(window: window, app: app, sourceApp: "Outlook", prefix: "outlook")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.emailContent(window: window)?.content
    }
}

public struct SparkParser: SourceParser {
    public init() {}
    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        StructuredEntityExtraction.email(window: window, app: app, sourceApp: "Spark", prefix: "spark")
    }
    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        StructuredEntityExtraction.emailContent(window: window)?.content
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

    static func calendarContent(
        detailRoot: AXNode,
        context: ParseContext,
        sourceApp: String
    ) -> Extracted? {
        let fields = orderedFields(in: detailRoot)
        guard !fields.isEmpty else { return nil }

        let title = firstValue(fields, metadataHints: ["title", "summary", "event-name"])
            ?? fields.first(where: { $0.role == "AXHeading" && !isChrome($0.value) })?.value
            ?? meaningfulWindowTitle(context.windowTitle, excluding: [sourceApp, "Calendar"])
        guard let title, !title.isEmpty else { return nil }
        let when = firstValue(fields, metadataHints: ["date", "time", "start", "end"])
            ?? fields.first(where: { looksLikeDateOrTime($0.value) })?.value
        let timing = calendarTiming(from: fields, context: context)
        let location = firstValue(fields, metadataHints: ["location", "place"])
        // No organizer is exposed by these detail views, so the account/calendar name — the
        // closest thing to "who owns this event" — lands in `organizer`.
        let organizer = firstValue(fields, metadataHints: ["organizer", "invitee", "calendar-name", "account"])
        let hasConference = fields.contains { field in
            let value = field.value.lowercased()
            return field.metadata.contains("conference")
                || value.contains("zoom.us") || value.contains("meet.google.com")
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
            start: timing.start, end: timing.end,
            organizer: organizer,
            location: location,
            hasConference: hasConference,
            notes: details.isEmpty ? nil : details.joined(separator: "\n"),
            allDay: timing.allDay
        )
        let identity = [title, when ?? "", organizer ?? ""].joined(separator: "|")
        return Extracted(content: .calendar([event]),
                         sourceKey: "event:\(shortHash(identity))",
                         sourceTitle: title)
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

    /// Preserves the 32_000 cap `DocumentExtraction.bodyText` applied here.
    static let pageBudget = 32_000
    // Whole-page `.replace` accumulation bounds ONE capture to `pageBudget`, so the scroll
    // ceiling is `pageBudget` too — a larger one would be unreachable and its truncation branch
    // dead. Unioning blocks across scrolls so a long document can exceed it is a Phase D
    // candidate, alongside the anchored document parsers.
    static let documentOffscreen: OffscreenCapturePolicy =
        .accessibilityScroll(maxSteps: 6, maxCharacters: pageBudget)
    static let emailOffscreen: OffscreenCapturePolicy =
        .accessibilityScroll(maxSteps: 4, maxCharacters: pageBudget)

    /// Generic v2 over the whole window. The anchored document parsers land in Phase D.
    static func documentContent(window: AXNode) -> GenericV2Content.Page? {
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
        guard let page = documentContent(window: window) else { return nil }
        var title = app.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for suffix in titleSuffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        if title.isEmpty { title = "untitled" }
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):\(docSlug(title))",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(page.content, style: .full),
            contentKind: .document,
            parserVersion: 2,
            // Whole-page semantics (spec 4d): each extraction is the window's current state.
            accumulationPolicy: .replace,
            offscreenPolicy: documentOffscreen,
            structured: page.content,
            truncated: page.truncated
        )
    }

    static func emailContent(window: AXNode) -> GenericV2Content.Page? {
        GenericV2Content.page(window: window, budget: pageBudget,
                              offscreenPolicy: emailOffscreen)
    }

    static func email(
        window: AXNode,
        app: AppInfo,
        sourceApp: String,
        prefix: String
    ) -> ParsedCapture? {
        guard let page = emailContent(window: window) else { return nil }
        let title = meaningfulWindowTitle(app.windowTitle, excluding: [sourceApp]) ?? "message"
        return ParsedCapture(
            sourceApp: sourceApp,
            sourceKey: "\(prefix):message:\(shortHash(title))",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(page.content, style: .full),
            // Outlook and Spark expose no sender or date, so they stay a page — but the kind
            // is still .email (spec 12 Q3).
            contentKind: .email,
            parserVersion: 2,
            accumulationPolicy: .replace,
            offscreenPolicy: emailOffscreen,
            structured: page.content,
            truncated: page.truncated
        )
    }

    static func preferredDetailRoot(in root: AXNode, hints: [String]) -> AXNode {
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

    /// Calendar/Fantastical only claims a detail surface, never the app's bare sidebar, toolbar,
    /// or day grid. A surface can be explicitly named by AX metadata or be one of the native
    /// popover/sheet/dialog roles Calendar uses for an event inspector.
    static func calendarDetailRoot(in root: AXNode) -> AXNode? {
        if isCalendarDetailSurface(root) { return root }
        for child in root.children {
            if let detail = calendarDetailRoot(in: child) { return detail }
        }
        return nil
    }

    private static func isCalendarDetailSurface(_ node: AXNode) -> Bool {
        let metadata = [node.identifier, node.label, node.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let isSurface = ["AXSheet", "AXPopover", "AXDialog"].contains(node.role)
            || ["event", "detail", "popover"].contains { metadata.contains($0) }
        guard isSurface else { return false }
        return orderedFields(in: node).contains { field in
            ["event", "title", "summary", "date", "time", "start", "end", "all-day"].contains {
                field.metadata.contains($0)
            } || (field.role == "AXHeading" && !isChrome(field.value))
        }
    }

    private static func isPreferred(_ node: AXNode, hints: [String]) -> Bool {
        if ["AXSheet", "AXPopover", "AXDialog"].contains(node.role) { return true }
        let metadata = [node.identifier, node.label, node.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return hints.contains(where: metadata.contains)
    }

    static func orderedFields(in root: AXNode) -> [Field] {
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

    static func firstValue(_ fields: [Field], metadataHints: [String]) -> String? {
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

    static func looksLikeDateOrTime(_ value: String) -> Bool {
        let lower = value.lowercased()
        let tokens = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june", "july", "august",
            "september", "october", "november", "december", "am", "pm", "tomorrow", "today",
        ]
        return tokens.contains(where: lower.contains)
    }

    struct CalendarTiming {
        let start: Date?
        let end: Date?
        let allDay: Bool
    }

    /// Parses only the detail surface's explicitly date/time-like fields. The reference instant
    /// and timezone are injected through `ParseContext`: capture parsing must never consult the
    /// machine's current clock or timezone.
    static func calendarTiming(from fields: [Field], context: ParseContext) -> CalendarTiming {
        let timingFields = fields.filter { field in
            ["date", "time", "start", "end", "all-day", "allday"].contains {
                field.metadata.contains($0)
            } || looksLikeDateOrTime(field.value)
        }
        guard !timingFields.isEmpty else {
            return CalendarTiming(start: nil, end: nil, allDay: false)
        }

        let raw = timingFields.map(\.value).joined(separator: " ")
        let explicitAllDay = timingFields.contains { field in
            guard field.metadata.contains("all-day") || field.metadata.contains("allday")
                    || field.value.localizedCaseInsensitiveContains("all day") else {
                return false
            }
            return !["0", "false", "no", "unchecked"].contains(
                field.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        let reference = Date(timeIntervalSince1970: TimeInterval(context.now) / 1_000)
        let date = calendarDate(in: raw, reference: reference, calendar: calendar)
        let times = timeTokens(in: raw).compactMap(parseClockTime)

        if explicitAllDay || (date != nil && times.isEmpty) {
            guard let date else { return CalendarTiming(start: nil, end: nil, allDay: true) }
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start)
            return CalendarTiming(start: start, end: end, allDay: true)
        }
        guard let first = times.first else {
            return CalendarTiming(start: nil, end: nil, allDay: false)
        }

        let base = date ?? reference
        var components = calendar.dateComponents([.year, .month, .day], from: base)
        components.hour = first.hour
        components.minute = first.minute
        guard let start = calendar.date(from: components) else {
            return CalendarTiming(start: nil, end: nil, allDay: false)
        }
        guard let second = times.dropFirst().first else {
            return CalendarTiming(start: start, end: nil, allDay: false)
        }
        components.hour = second.hour
        components.minute = second.minute
        guard var end = calendar.date(from: components) else {
            return CalendarTiming(start: start, end: nil, allDay: false)
        }
        if end < start {
            end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        }
        return CalendarTiming(start: start, end: end, allDay: false)
    }

    private static let months: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
        "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
    ]
    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static func calendarDate(in raw: String, reference: Date, calendar: Calendar) -> Date? {
        let lower = raw.lowercased()
        if lower.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference))
        }
        if lower.contains("today") {
            return calendar.startOfDay(for: reference)
        }
        if let parts = captures(#"\b(\d{1,2})\s+(january|february|march|april|may|june|july|august|september|october|november|december)\b"#, in: lower),
           let day = Int(parts[0]), let month = months[parts[1]] {
            return calendarDate(year: nil, month: month, day: day, reference: reference, calendar: calendar)
        }
        if let parts = captures(#"\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})\b"#, in: lower),
           let month = months[parts[0]], let day = Int(parts[1]) {
            return calendarDate(year: nil, month: month, day: day, reference: reference, calendar: calendar)
        }
        guard let wanted = weekdays.first(where: { lower.contains($0.key) })?.value else { return nil }
        let current = calendar.component(.weekday, from: reference)
        let delta = (wanted - current + 7) % 7
        return calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: reference))
    }

    private static func calendarDate(
        year: Int?,
        month: Int,
        day: Int,
        reference: Date,
        calendar: Calendar
    ) -> Date? {
        let referenceComponents = calendar.dateComponents([.year], from: reference)
        guard var candidate = calendar.date(from: DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: year ?? referenceComponents.year, month: month, day: day
        )) else { return nil }
        if year == nil, candidate < calendar.startOfDay(for: reference) {
            candidate = calendar.date(byAdding: .year, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private static func timeTokens(in raw: String) -> [String] {
        allMatches(
            #"\b\d{1,2}:\d{2}\s*(?:[AaPp]\.?[Mm]\.?)?\b|\b\d{1,2}\s*(?:[AaPp]\.?[Mm]\.?)\b"#,
            in: raw
        )
    }

    private static func parseClockTime(_ raw: String) -> (hour: Int, minute: Int)? {
        var value = raw.lowercased().replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        let isPM = value.hasSuffix("pm")
        let isAM = value.hasSuffix("am")
        if isPM || isAM { value.removeLast(2) }
        let pieces = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard let rawHour = Int(pieces[0]), rawHour >= 0, rawHour <= 23 else { return nil }
        let minute = pieces.count == 2 ? Int(pieces[1]) : 0
        guard let minute, (0...59).contains(minute) else { return nil }
        let hour: Int
        if isPM {
            hour = rawHour == 12 ? 12 : rawHour + 12
        } else if isAM {
            hour = rawHour == 12 ? 0 : rawHour
        } else {
            hour = rawHour
        }
        return (hour, minute)
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value, range: NSRange(value.startIndex..., in: value)
              ) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func allMatches(_ pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .compactMap { match in
                guard let range = Range(match.range, in: value) else { return nil }
                return String(value[range])
            }
    }

    private static func meaningfulWindowTitle(_ title: String?, excluding: [String]) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return excluding.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) ? nil : title
    }

    private static func shortHash(_ value: String) -> String {
        String(ContentHash.sha256Hex(value).prefix(24))
    }

    static func isChrome(_ value: String) -> Bool {
        chrome.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// The `.tasks` retyping of `StructuredEntityExtraction.task`. A Reminders window is a LIST of
/// rows, so unlike the v1 extraction (which produced one blob for the selected reminder) this
/// yields one `TaskItem` per row, with status read from the row's own `AXCheckBox` (spec §7c).
enum TaskStructuredExtraction {
    struct Extraction {
        let items: [TaskItem]
        let identity: TaskItem
    }

    /// The same truthy set `StructuredEntityExtraction.task` already tests against.
    static let completedValues: Set<String> = ["1", "true", "yes", "checked"]

    static func status(ofRow row: AXNode) -> TaskStatus {
        guard let checkbox = AXQuery.findAll("//AXCheckBox", in: row).first,
              let value = checkbox.value?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() else { return .unknown }
        return completedValues.contains(value) ? .completed : .open
    }

    static func tasks(in window: AXNode, windowTitle: String?) -> [TaskItem] {
        extraction(in: window, windowTitle: windowTitle)?.items ?? []
    }

    /// The structured task list and the v1 bridge identity are resolved together. A selected
    /// detail pane owns identity when present; otherwise the first visible task does.
    static func extraction(in window: AXNode, windowTitle: String?) -> Extraction? {
        let rows = AXQuery.findAll("//AXRow", in: window)
            .filter { !AXQuery.findAll("//AXCheckBox", in: $0).isEmpty }
        let detail = detailItem(in: window, windowTitle: windowTitle)
        if !rows.isEmpty {
            let items = AXQuery.sortedByVisualOrder(rows, relativeTo: window.frame)
                .compactMap { item(fromRow: $0) }
            guard let identity = detail ?? items.first else { return nil }
            return Extraction(items: items, identity: identity)
        }
        // No rows with checkboxes: this is a single reminder's detail pane, which is the shape
        // the v1 extraction was written for. Reuse its anchor rather than returning nothing.
        guard let detail else { return nil }
        return Extraction(items: [detail], identity: detail)
    }

    /// A Reminders window is either the row list (each row has its own checkbox) or a selected
    /// reminder detail surface. Toolbar/sidebar-only windows must refuse rather than becoming a
    /// generic capture of unrelated application chrome.
    static func hasExpectedShape(in window: AXNode) -> Bool {
        let hasRows = AXQuery.findAll("//AXRow", in: window)
            .contains { !AXQuery.findAll("//AXCheckBox", in: $0).isEmpty }
        return hasRows || reminderDetailRoot(in: window) != nil
    }

    static func isKnownNonContentSurface(in window: AXNode) -> Bool {
        window.children.isEmpty || window.children.allSatisfy {
            $0.role == "AXToolbar" || $0.identifier?.contains("reminders-sidebar") == true
        }
    }

    /// Everything the named fields did not claim, as the notes body. `AXCheckBox` is excluded
    /// because it is in `StructuredEntityExtraction.readableRoles` — without this, a row's
    /// checkbox value ("0") is rendered as a task note (ruling F23). One implementation, used by
    /// both the row path and the detail path.
    static func notes(from fields: [StructuredEntityExtraction.Field],
                      excluding claimed: [String?]) -> String? {
        let claimed = Set(claimed.compactMap { $0 })
        let remaining = fields
            .filter { $0.role != "AXCheckBox" }
            .filter { !claimed.contains($0.value) }
            .filter { !StructuredEntityExtraction.isChrome($0.value) }
            .map(\.value)
        return remaining.isEmpty ? nil : remaining.joined(separator: "\n")
    }

    static func item(fromRow row: AXNode) -> TaskItem? {
        let fields = StructuredEntityExtraction.orderedFields(in: row)
        let title = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["title", "name", "task-title", "reminder-title"]
        ) ?? fields.first { $0.role == "AXStaticText" }?.value
        guard let title, !title.isEmpty else { return nil }
        let dueString = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["due", "date", "time"]
        )
        let project = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["list", "project", "section"]
        )
        return TaskItem(title: title, status: status(ofRow: row), due: nil, dueString: dueString,
                        project: project, tags: [],
                        notes: notes(from: fields, excluding: [title, dueString, project]))
    }

    static func detailItem(in window: AXNode, windowTitle: String?) -> TaskItem? {
        guard let root = reminderDetailRoot(in: window) else { return nil }
        let fields = StructuredEntityExtraction.orderedFields(in: root)
        guard !fields.isEmpty else { return nil }
        let title = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["title", "name", "task-title", "reminder-title"]
        ) ?? fields.first {
            $0.role == "AXHeading" && !StructuredEntityExtraction.isChrome($0.value)
        }?.value
        guard let title, !title.isEmpty else { return nil }
        let dueString = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["due", "date", "time"]
        ) ?? fields.first { StructuredEntityExtraction.looksLikeDateOrTime($0.value) }?.value
        let project = StructuredEntityExtraction.firstValue(
            fields, metadataHints: ["list", "project", "section"]
        )
        let checkboxValue = fields.first { $0.role == "AXCheckBox" }?.value.lowercased()
        let status: TaskStatus = checkboxValue.map {
            completedValues.contains($0) ? .completed : .open
        } ?? .unknown
        return TaskItem(title: title, status: status, due: nil, dueString: dueString,
                        project: project, tags: [],
                        notes: notes(from: fields, excluding: [title, dueString, project]))
    }

    private static func reminderDetailRoot(in root: AXNode) -> AXNode? {
        if isReminderDetailSurface(root) { return root }
        for child in root.children {
            if let detail = reminderDetailRoot(in: child) { return detail }
        }
        return nil
    }

    private static func isReminderDetailSurface(_ node: AXNode) -> Bool {
        let metadata = [node.identifier, node.label, node.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let isSurface = ["AXSheet", "AXPopover", "AXDialog"].contains(node.role)
            || ["task", "reminder", "detail"].contains { metadata.contains($0) }
        guard isSurface else { return false }
        return StructuredEntityExtraction.orderedFields(in: node).contains { field in
            ["title", "name", "task-title", "reminder-title", "due", "date", "time",
             "list", "project", "section", "completed"].contains {
                field.metadata.contains($0)
            } || (field.role == "AXHeading" && !StructuredEntityExtraction.isChrome(field.value))
        }
    }
}

extension RemindersParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Reminders",
        bundleIDs: ParserRegistry.remindersBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    private static func v2Result(
        in snapshot: AXNode,
        context: ParseContext
    ) throws -> ParsedTasks? {
        guard TaskStructuredExtraction.hasExpectedShape(in: snapshot) else {
            if TaskStructuredExtraction.isKnownNonContentSurface(in: snapshot) {
                throw ParserRefusal(reason: "unmatched-reminders-window")
            }
            return nil
        }
        guard let extraction = TaskStructuredExtraction.extraction(
            in: snapshot, windowTitle: context.windowTitle
        ) else { return nil }
        let unbounded = CapturedContent.tasks(extraction.items)
        let content = CaptureAccumulator.boundHard(
            unbounded,
            to: Self.config.offscreenPolicy.maxCharacters
        )
        return ParsedTasks(
            content: content,
            identity: extraction.identity,
            truncated: content != unbounded
        )
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        try Self.v2Result(in: snapshot, context: context)?.content
    }
}
