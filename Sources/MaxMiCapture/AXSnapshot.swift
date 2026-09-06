import Foundation

public struct AXNode: Codable, Sendable {
    public let role: String
    public let value: String?
    public let title: String?
    public let url: String?
    public let frame: CGRect?
    public let focused: Bool
    public let children: [AXNode]
    public let identifier: String?
    public let label: String?
    /// kAXSubroleAttribute. Region detection and secure-field masking depend on it.
    public let subrole: String?
    /// "AXHeadingLevel", fetched only when role == "AXHeading".
    public let headingLevel: Int?
    /// kAXSelectedAttribute.
    public let selected: Bool
    /// kAXPlaceholderValueAttribute, fetched only for text-entry roles.
    public let placeholder: String?
    /// kAXSelectedTextAttribute, fetched only for text-entry roles.
    public let selectedText: String?
    /// "AXHidden".
    public let hidden: Bool

    public init(role: String, value: String?, title: String?, url: String?,
                frame: CGRect?, focused: Bool, children: [AXNode],
                identifier: String? = nil, label: String? = nil,
                subrole: String? = nil, headingLevel: Int? = nil, selected: Bool = false,
                placeholder: String? = nil, selectedText: String? = nil, hidden: Bool = false) {
        self.role = role; self.value = value; self.title = title
        self.url = url; self.frame = frame; self.focused = focused; self.children = children
        self.identifier = identifier; self.label = label
        self.subrole = subrole; self.headingLevel = headingLevel; self.selected = selected
        self.placeholder = placeholder; self.selectedText = selectedText; self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case role, value, title, url, frame, focused, children, identifier, label
        case subrole, headingLevel, selected, placeholder, selectedText, hidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        focused = try container.decode(Bool.self, forKey: .focused)
        children = try container.decode([AXNode].self, forKey: .children)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        // decodeIfPresent + defaults: the eleven pre-M8 fixtures carry none of these keys.
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        headingLevel = try container.decodeIfPresent(Int.self, forKey: .headingLevel)
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false

        if let frameDict = try? container.decode([String: CGFloat].self, forKey: .frame) {
            let x = frameDict["x"] ?? 0
            let y = frameDict["y"] ?? 0
            let width = frameDict["width"] ?? 0
            let height = frameDict["height"] ?? 0
            frame = CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
        } else {
            frame = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(focused, forKey: .focused)
        try container.encode(children, forKey: .children)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(subrole, forKey: .subrole)
        try container.encodeIfPresent(headingLevel, forKey: .headingLevel)
        try container.encode(selected, forKey: .selected)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
        try container.encodeIfPresent(selectedText, forKey: .selectedText)
        try container.encode(hidden, forKey: .hidden)

        if let frame = frame {
            let frameDict: [String: CGFloat] = [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.size.width,
                "height": frame.size.height
            ]
            try container.encode(frameDict, forKey: .frame)
        } else {
            try container.encodeNil(forKey: .frame)
        }
    }
}
