import Foundation

public enum RenderStyle: Sendable, Equatable {
    case full
    case compact(maxChars: Int)
    case mainOnly(maxChars: Int)
}

/// Pure, total, deterministic `CapturedContent` -> `String`. `.full` is what goes into
/// `versions.content` and `latest_contexts.content_ciphertext`, so search, embeddings, MCP,
/// and `message_fingerprints` keep working unchanged. `.compact` and `.mainOnly` exist only
/// to feed prompts.
public enum ContentRenderer {
    /// Fixed render order. `.main` gets no header; everything else is announced.
    public static let regionOrder: [RegionKind] = [
        .main, .dialog, .sidebar, .navigation, .toolbar, .banner, .footer, .unknown,
    ]

    public static func regionHeader(_ kind: RegionKind) -> String? {
        switch kind {
        case .main:       return nil
        case .dialog:     return "## Dialog"
        case .sidebar:    return "## Sidebar"
        case .navigation: return "## Navigation"
        case .toolbar:    return "## Toolbar"
        case .banner:     return "## Banner"
        case .footer:     return "## Footer"
        case .unknown:    return "## Other"
        }
    }

    public static func render(_ content: CapturedContent, style: RenderStyle) -> String {
        switch style {
        case .full:
            return renderFull(content)
        case .compact(let maxChars):
            return CaptureAccumulator.bound(renderFull(content), to: max(4, maxChars))
        case .mainOnly(let maxChars):
            guard case .generic(let page) = content else {
                return CaptureAccumulator.bound(renderFull(content), to: max(4, maxChars))
            }
            // No region headers and no `URL:` line: the prompt's CONTEXT block (spec 6a)
            // already carries app, window, and url as separate fields.
            let blocks = page.regions
                .filter { $0.kind == .main || $0.kind == .dialog }
                .sorted { orderIndex($0.kind) < orderIndex($1.kind) }
                .flatMap(\.blocks)
            return CaptureAccumulator.bound(renderBlocks(blocks), to: max(4, maxChars))
        }
    }

    // MARK: - Per-item renderers (also used for sizing, so nothing has to re-render a page)

    public static func renderBlock(_ block: Block) -> String {
        switch block.type {
        case .heading(let level):
            return String(repeating: "#", count: min(max(level, 1), 6)) + " " + block.text
        case .paragraph:
            return block.text
        case .listItem(let depth):
            return String(repeating: "  ", count: max(0, depth)) + "- " + block.text
        case .label:
            return block.text
        case .tableRow(let cells, let selected):
            return (selected ? "* " : "") + cells.joined(separator: " | ")
        case .input(let placeholder):
            return block.text.isEmpty ? "«\(placeholder ?? "empty field")»" : block.text
        }
    }

    public static func renderBlocks(_ blocks: [Block]) -> String {
        blocks.map(renderBlock).joined(separator: "\n")
    }

    public static func renderMessage(_ message: Message) -> String {
        var sender = message.isUser ? "You" : message.sender
        if message.isDraft { sender += " (draft)" }
        var head = "(From: \(sender))"
        if let stamp = message.timeString ?? message.timestamp.map(formatTimestamp) {
            head += "(sent \(stamp))"
        }
        let lines = message.text.split(separator: "\n", omittingEmptySubsequences: false)
        return "\(head): \(lines.first ?? "")" + indentContinuation(lines.dropFirst())
    }

    public static func renderTask(_ item: TaskItem) -> String {
        var line: String
        switch item.status {
        case .completed: line = "- [x] "
        case .open:      line = "- [ ] "
        case .unknown:   line = "- "
        }
        line += item.title
        if let due = item.dueString, !due.isEmpty { line += " (due \(due))" }
        if let project = item.project, !project.isEmpty { line += " [\(project)]" }
        for tag in item.tags { line += " #\(tag)" }
        if let notes = item.notes, !notes.isEmpty {
            line += indentContinuation(notes.split(separator: "\n", omittingEmptySubsequences: false))
        }
        return line
    }

    public static func renderEvent(_ event: CalendarEvent) -> String {
        var line = "\(event.dateString) — \(event.title)"
        if let location = event.location, !location.isEmpty { line += " @\(location)" }
        if let organizer = event.organizer, !organizer.isEmpty { line += " / \(organizer)" }
        if event.hasConference { line += " [conference]" }
        if let notes = event.notes, !notes.isEmpty {
            let lines = notes.split(separator: "\n", omittingEmptySubsequences: false)
            line += "\nDetails: \(lines.first ?? "")" + indentContinuation(lines.dropFirst())
        }
        return line
    }

    public static func renderSegment(_ segment: TerminalSegment) -> String {
        var parts: [String] = []
        if let command = segment.command { parts.append("$ \(command)") }
        if !segment.output.isEmpty { parts.append(segment.output) }
        if segment.isRunning { parts.append("… (running)") }
        return parts.joined(separator: "\n")
    }

    /// `Message.timestamp` fallback format, local timezone.
    public static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    // MARK: - Private

    /// `DateFormatter` is thread-safe for formatting on macOS. Held once rather than rebuilt
    /// per message: a rendered conversation can carry hundreds of messages per capture.
    nonisolated(unsafe) private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d, HH:mm zzz"
        return formatter
    }()

    private static func orderIndex(_ kind: RegionKind) -> Int {
        regionOrder.firstIndex(of: kind) ?? regionOrder.count
    }

    /// Renders each line as `"\n  " + line`, concatenated in order. Shared by `renderMessage`,
    /// `renderTask`, and `renderEvent` for their multi-line text/notes fields: callers that want
    /// the first line inline pass `lines.dropFirst()`; `renderTask` passes every note line since
    /// task notes have no inline first line.
    private static func indentContinuation(_ lines: some Sequence<Substring>) -> String {
        lines.reduce(into: "") { $0 += "\n  " + $1 }
    }

    private static func renderFull(_ content: CapturedContent) -> String {
        switch content {
        case .document(let doc):
            let body = renderBlocks(doc.blocks)
            return body.isEmpty ? "# \(doc.title)" : "# \(doc.title)\n\n\(body)"
        case .conversation(let conversation):
            return conversation.messages.map(renderMessage).joined(separator: "\n")
        case .tasks(let items):
            return items.map(renderTask).joined(separator: "\n")
        case .calendar(let events):
            return events.map(renderEvent).joined(separator: "\n")
        case .terminal(let session):
            return session.segments.map(renderSegment).joined(separator: "\n\n")
        case .generic(let page):
            var chunks: [String] = []
            if let url = page.url, !url.isEmpty { chunks.append("URL: \(url)") }
            for kind in regionOrder {
                let blocks = page.regions.filter { $0.kind == kind }.flatMap(\.blocks)
                guard !blocks.isEmpty else { continue }
                let body = renderBlocks(blocks)
                if let header = regionHeader(kind) {
                    chunks.append("\(header)\n\(body)")
                } else {
                    chunks.append(body)
                }
            }
            return chunks.joined(separator: "\n")
        }
    }
}
