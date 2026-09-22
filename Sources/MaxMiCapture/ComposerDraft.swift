import Foundation
import MaxMiCore

/// The user's in-progress message in a chat composer, as a draft `Message`.
///
/// Read from the focused text field only. A secure field is never read (Phase A nils its value at
/// the source), and a focused field anywhere inside the MESSAGE LIST is not the composer — it is
/// a bubble being edited or a virtualised list cell, and treating it as a draft would attribute
/// somebody else's message to the user.
///
/// The disqualifying test is the ancestor CONTAINER, not the row: spec 5c says "not a descendant of
/// the message-list node", and a rows/cells-only test misses a field parented directly to the list
/// (common in Electron re-renders) while wrongly disqualifying a toolbar field that happens to sit
/// in a bare `AXRow`. `GenericPageExtractor.listContainerRoles` already names the container roles
/// the text walk treats as lists, so it is reused rather than re-listed; `AXTable` is added because
/// a table is a message list in the same sense an `AXList` is.
///
/// Phase D's per-parser configs name the composer anchor explicitly; until then this is the generic
/// rule spec 5c describes.
public enum ComposerDraft {
    static let composerRoles: Set<String> = ["AXTextArea", "AXTextField"]
    /// Ancestor roles that mean "inside the message list", so a focused field below one of them is
    /// history being edited rather than a draft being written.
    static let messageListContainerRoles: Set<String> =
        GenericPageExtractor.listContainerRoles.union(["AXTable"])

    public static func draft(window: AXNode) -> Message? {
        guard let field = focusedComposer(window, inMessageList: false) else { return nil }
        let text = (field.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Message(
            id: "draft:\(field.identifier ?? field.role)",
            sender: "You",
            text: text,
            timestamp: nil,
            timeString: nil,
            isUser: true,
            isDraft: true
        )
    }

    /// Depth-first, first match wins. Menu subtrees are skipped for the same reason the text walk
    /// skips them: a Spotlight or menu search field is not this window's content.
    static func focusedComposer(_ node: AXNode, inMessageList: Bool) -> AXNode? {
        if GenericPageExtractor.menuRoles.contains(node.role) { return nil }
        let inList = inMessageList || messageListContainerRoles.contains(node.role)
        if node.focused, composerRoles.contains(node.role),
           node.subrole != GenericPageExtractor.secureSubrole, !inList {
            return node
        }
        for child in node.children {
            if let found = focusedComposer(child, inMessageList: inList) { return found }
        }
        return nil
    }
}
