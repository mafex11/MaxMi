import Foundation
import MaxMiCore

/// Finder. A Finder window is exactly what `GenericPageExtractor` was designed for: a source
/// list that must become a `.sidebar` region, a table whose rows must join into one
/// `.tableRow` block each (not one block per cell), and a toolbar whose progress text must not
/// be mixed into the listing. So this parser adds identity — the folder path — and delegates
/// the walk, rather than re-implementing the §4e rules.
public struct FinderParser: SourceParser, StructuredParser {
    public init() {}

    public static let config = ParserConfig(
        app: "Finder",
        bundleIDs: [ParserRegistry.finderBundleID],
        offscreenPolicy: .visibleOnly(maxCharacters: 32_000)
    )

    /// `AXDocument` is a file URL and Finder puts it on the window in list view but on the
    /// browser/outline beneath it in column view, so the anchor is a path query rather than one
    /// field read. The window title is only a folder name, so it is the last resort.
    static func folderPath(in snapshot: AXNode, windowTitle: String?) -> String? {
        let raw = [snapshot.url]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })
            ?? AXQuery.findAll("//*", in: snapshot)
                .compactMap(\.url)
                .first(where: { !$0.isEmpty })
        if let raw {
            if let url = URL(string: raw), url.isFileURL { return url.path }
            return raw
        }
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    /// The source list's rows. Used by the sidebar-classification assertion: the §4e sidebar
    /// rules are geometric and window-relative, and this is the structural statement of the same
    /// thing — every row under the split group's `AXOutline` is chrome, never a folder listing.
    static func sidebarRows(in snapshot: AXNode) -> [AXNode] {
        AXQuery.findAll("//AXSplitGroup//AXOutline//AXRow", in: snapshot)
    }

    static func key(fromPath path: String?, windowTitle: String?) -> String {
        if let path, !path.isEmpty { return "finder:\(path.lowercased())" }
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "finder:unknown" : "finder:\(docSlug(title))"
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        var options = GenericPageExtractor.Options()
        // The v2 structured path preserves every block. Its consumer applies the configured
        // capture bound; the v1 bridge below performs that same bound before rendering.
        options.totalBudget = .max
        options.offscreenPolicy = Self.config.offscreenPolicy
        let page = GenericPageExtractor.extract(
            window: snapshot,
            focusedElement: nil,
            url: Self.folderPath(in: snapshot, windowTitle: context.windowTitle),
            options: options
        ).page
        guard !page.regions.isEmpty else { return nil }
        return .generic(page)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        guard let unbounded = try parse(window, context: ParseContext(app: app)) else { return nil }
        let content = CaptureAccumulator.boundHard(
            unbounded,
            to: Self.config.offscreenPolicy.maxCharacters
        )
        let path: String?
        if case .generic(let page) = unbounded {
            path = page.url
        } else {
            path = nil
        }
        return ParsedCapture(
            sourceApp: "Finder",
            sourceKey: Self.key(fromPath: path, windowTitle: app.windowTitle),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(content, style: .full),
            contentKind: .generic,
            parserVersion: 1,
            // §4d: .generic accumulates by replace.
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
