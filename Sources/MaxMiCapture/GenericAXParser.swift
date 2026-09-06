import Foundation
import MaxMiCore

/// Fallback for any capturable app without a dedicated parser, and the degradation target when a
/// dedicated parser cannot handle its window. Content is `GenericPageExtractor`'s typed page
/// rendered back to text, keyed by bundle id + window title (coarse but guarantees coverage).
public struct GenericAXParser: SourceParser {
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        var options = GenericPageExtractor.Options()
        options.offscreenPolicy = Self.profile(for: app).offscreen
        // focusedElement is nil here: only AppWiring knows the pid that
        // AXReader.focusedElementSnapshot needs, and Phase B's TypingObserver wires it.
        let result = GenericPageExtractor.extract(
            window: window, focusedElement: nil, url: nil, options: options
        )
        guard !result.page.regions.isEmpty else { return nil }   // no empty threads
        return .generic(result.page)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let structured = try parseStructured(window: window, app: app) else { return nil }
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "window"
        let profile = Self.profile(for: app)
        return ParsedCapture(
            sourceApp: app.name,
            sourceKey: "\(app.bundleID):\(title)",
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(structured, style: .full),
            contentKind: profile.kind,
            parserVersion: 2,
            // Whole-page semantics (spec 4d): each extraction is the current state of the
            // window, so it supersedes the previous one rather than merging into it.
            accumulationPolicy: .replace,
            offscreenPolicy: profile.offscreen,
            structured: structured
        )
    }

    /// Unchanged from v1: the kind comes from the application registry's descriptor, and the
    /// offscreen policy from the kind.
    static func profile(for app: AppInfo) -> (kind: CaptureContentKind, offscreen: OffscreenCapturePolicy) {
        let kind: CaptureContentKind = switch ApplicationRegistry.descriptor(for: app.bundleID)?.kind {
        case .document: .document
        case .chat: .conversation
        case .terminal: .terminal
        case .email: .email
        case .calendar: .calendar
        case .task: .task
        default: .generic
        }
        let offscreen: OffscreenCapturePolicy = switch kind {
        case .document, .conversation, .calendar, .task, .meeting, .voiceNote:
            .accessibilityScroll(maxSteps: 3)
        default:
            .visibleOnly(maxCharacters: 32_000)
        }
        return (kind, offscreen)
    }
}
