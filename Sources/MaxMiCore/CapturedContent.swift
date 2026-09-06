import Foundation

public enum Authorship: Codable, Sendable, Equatable {
    case user
    case other(String)
    case unknown
}

public enum BlockType: Codable, Sendable, Equatable {
    /// Clamped to 1...6 by `ContentRenderer`; the extractor clamps on the way in too.
    case heading(level: Int)
    case paragraph
    /// 0-based nesting depth.
    case listItem(depth: Int)
    /// Button/link/menu-item/tab/checkbox/image label.
    case label
    case tableRow(cells: [String], selected: Bool)
    /// Text field / text area / combo box value.
    case input(placeholder: String?)
}

public struct Block: Codable, Sendable, Equatable {
    public let type: BlockType
    public let text: String
    /// Set by `TypingObserver` (Phase B) when this block came from the focused field
    /// the user typed into. Absent in stored JSON written before Phase B.
    public let authoredByUser: Bool

    public init(type: BlockType, text: String, authoredByUser: Bool = false) {
        self.type = type
        self.text = text
        self.authoredByUser = authoredByUser
    }

    private enum CodingKeys: String, CodingKey { case type, text, authoredByUser }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(BlockType.self, forKey: .type)
        text = try c.decode(String.self, forKey: .text)
        authoredByUser = try c.decodeIfPresent(Bool.self, forKey: .authoredByUser) ?? false
    }
}

public enum RegionKind: String, Codable, Sendable, CaseIterable {
    case main, sidebar, navigation, toolbar, dialog, banner, footer, unknown
}

public struct Region: Codable, Sendable, Equatable {
    public let kind: RegionKind
    public let blocks: [Block]

    public init(kind: RegionKind, blocks: [Block]) {
        self.kind = kind
        self.blocks = blocks
    }
}

public struct FocusedElement: Codable, Sendable, Equatable {
    public let role: String
    public let identifier: String?
    /// nil when `isSecure` — a secure field's value is never read, not merely not stored.
    public let value: String?
    /// nil when `isSecure` for the same reason `value` is: a selection inside a secure field is
    /// the secret itself, so a caller cannot leak it by reading the selection instead.
    public let selectedText: String?
    public let isSecure: Bool

    public init(role: String, identifier: String?, value: String?, selectedText: String?, isSecure: Bool) {
        self.role = role
        self.identifier = identifier
        self.value = isSecure ? nil : value
        self.selectedText = isSecure ? nil : selectedText
        self.isSecure = isSecure
    }
}

public struct GenericPage: Codable, Sendable, Equatable {
    public let regions: [Region]
    public let focused: FocusedElement?
    public let url: String?

    public init(regions: [Region], focused: FocusedElement?, url: String?) {
        self.regions = regions
        self.focused = focused
        self.url = url
    }
}

public struct Document: Codable, Sendable, Equatable {
    public let title: String
    public let blocks: [Block]
    public let author: Authorship
    public let url: String?

    public init(title: String, blocks: [Block], author: Authorship, url: String?) {
        self.title = title
        self.blocks = blocks
        self.author = author
        self.url = url
    }
}

public struct Message: Codable, Sendable, Equatable {
    /// Stable fingerprint. See `Message.makeID`.
    public let id: String
    public let sender: String
    public let text: String
    public let timestamp: Date?
    public let timeString: String?
    public let isUser: Bool
    public let isDraft: Bool

    public init(id: String, sender: String, text: String, timestamp: Date?,
                timeString: String?, isUser: Bool, isDraft: Bool) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.timeString = timeString
        self.isUser = isUser
        self.isDraft = isDraft
    }

    /// Deterministic and order-independent, so accumulation can union by identity.
    public static func makeID(sender: String, timeString: String?, text: String) -> String {
        String(ContentHash.sha256Hex("\(sender)\u{1F}\(timeString ?? "")\u{1F}\(text)").prefix(24))
    }
}

public struct Conversation: Codable, Sendable, Equatable {
    public let channel: String
    public let isGroup: Bool
    public let messages: [Message]

    public init(channel: String, isGroup: Bool, messages: [Message]) {
        self.channel = channel
        self.isGroup = isGroup
        self.messages = messages
    }
}

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case completed, open, unknown
}

public struct TaskItem: Codable, Sendable, Equatable {
    public let title: String
    public let status: TaskStatus
    public let due: Date?
    public let dueString: String?
    public let project: String?
    public let tags: [String]
    public let notes: String?

    public init(title: String, status: TaskStatus, due: Date?, dueString: String?,
                project: String?, tags: [String], notes: String?) {
        self.title = title
        self.status = status
        self.due = due
        self.dueString = dueString
        self.project = project
        self.tags = tags
        self.notes = notes
    }
}

public struct CalendarEvent: Codable, Sendable, Equatable {
    public let title: String
    public let dateString: String
    public let start: Date?
    public let end: Date?
    public let organizer: String?
    public let location: String?
    public let hasConference: Bool
    /// The event's detail/notes body, as the app exposes it.
    public let notes: String?

    public init(title: String, dateString: String, start: Date?, end: Date?,
                organizer: String?, location: String?, hasConference: Bool, notes: String?) {
        self.title = title
        self.dateString = dateString
        self.start = start
        self.end = end
        self.organizer = organizer
        self.location = location
        self.hasConference = hasConference
        self.notes = notes
    }
}

public struct TerminalSegment: Codable, Sendable, Equatable {
    /// nil when segmentation failed — the whole scrollback lands in `output`.
    public let command: String?
    public let output: String
    public let isRunning: Bool

    public init(command: String?, output: String, isRunning: Bool) {
        self.command = command
        self.output = output
        self.isRunning = isRunning
    }
}

public struct TerminalSession: Codable, Sendable, Equatable {
    public let cwd: String?
    public let segments: [TerminalSegment]

    public init(cwd: String?, segments: [TerminalSegment]) {
        self.cwd = cwd
        self.segments = segments
    }
}

public enum CapturedContent: Codable, Sendable, Equatable {
    case document(Document)
    case conversation(Conversation)
    case tasks([TaskItem])
    case calendar([CalendarEvent])
    case terminal(TerminalSession)
    case generic(GenericPage)

    /// True only for the exact shape `LegacyContentAdapter.adapt` produces: one `.main` region
    /// of `.paragraph` blocks, no url, no focused element. Accumulation uses it to tell a
    /// rendered-string capture from an unmigrated parser apart from a structured page.
    public var isLegacyShaped: Bool {
        guard case .generic(let page) = self,
              page.url == nil, page.focused == nil,
              page.regions.count == 1,
              let region = page.regions.first, region.kind == .main else { return false }
        return region.blocks.allSatisfy { $0.type == .paragraph }
    }

    /// The DEFAULT `CaptureContentKind` for this shape. Parsers may override:
    /// `.email` and `.webpage` are not derivable from the shape.
    public var kind: CaptureContentKind {
        switch self {
        case .document:     return .document
        case .conversation: return .conversation
        case .tasks:        return .task
        case .calendar:     return .calendar
        case .terminal:     return .terminal
        case .generic:      return .generic
        }
    }
}

/// Persisted JSON is wrapped so the shape can evolve without a column migration.
public struct CapturedContentEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public let v: Int
    public let content: CapturedContent

    public init(v: Int = CapturedContentEnvelope.currentSchemaVersion, content: CapturedContent) {
        self.v = v
        self.content = content
    }

    /// Deterministic bytes: sorted keys, unescaped slashes, ISO-8601 dates. Needed for
    /// hashing and for golden fixtures.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ content: CapturedContent) throws -> String {
        let data = try makeEncoder().encode(CapturedContentEnvelope(content: content))
        return String(decoding: data, as: UTF8.self)
    }

    /// nil for malformed JSON and for `v > currentSchemaVersion`. The caller treats nil
    /// exactly like a NULL column and falls back to `LegacyContentAdapter`.
    public static func decode(_ json: String) -> CapturedContent? {
        guard let envelope = try? makeDecoder().decode(CapturedContentEnvelope.self, from: Data(json.utf8)),
              envelope.v <= currentSchemaVersion else { return nil }
        return envelope.content
    }
}
