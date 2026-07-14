import Foundation
import MaxMiCore

/// Fallback for any capturable app without a dedicated parser: visible text in
/// visual order, keyed by bundle id + window title (coarse but guarantees coverage).
public struct GenericAXParser: SourceParser {
    public init() {}

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        // Code editors and many Electron apps expose their primary content as AXTextArea,
        // while simpler native apps use AXStaticText. DocumentExtraction supports both.
        let content = DocumentExtraction.bodyText(in: window)
        guard !content.isEmpty else { return nil }   // no empty threads
        let title = app.windowTitle?.isEmpty == false ? app.windowTitle! : "window"
        let kind: CaptureContentKind = switch ApplicationRegistry.descriptor(for: app.bundleID)?.kind {
        case .document: .document
        case .chat: .conversation
        case .terminal: .terminal
        case .email: .email
        default: .generic
        }
        let offscreen: OffscreenCapturePolicy = switch kind {
        case .document, .conversation:
            .accessibilityScroll(maxSteps: 3)
        default:
            .visibleOnly(maxCharacters: 32_000)
        }
        return ParsedCapture(
            sourceApp: app.name,
            sourceKey: "\(app.bundleID):\(title)",
            sourceTitle: app.windowTitle,
            content: content,
            contentKind: kind,
            accumulationPolicy: .rollingText,
            offscreenPolicy: offscreen
        )
    }
}
