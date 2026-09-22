import Foundation
import MaxMiCore

/// The browser generic-web path: `GenericPageExtractor` over the active `AXWebArea` subtree,
/// with the tab's URL attached. Landmark subroles give the regions, so a docs sidebar and a
/// nav bar stop being interleaved with the article the user is reading.
///
/// Not registered in `ParserRegistry` — it is the default a browser window reaches when no host
/// parser claims the URL, so it has no `ParserConfig`.
public enum WebPageParser {
    /// Traversal root is the web area, but budgets and region geometry are measured against the
    /// WINDOW, because `AXFrame` is global and the sidebar heuristic is window-relative.
    public static func extract(
        window: AXNode,
        webArea: AXNode,
        url: String?,
        options: GenericPageExtractor.Options
    ) -> GenericPageExtractor.Result {
        // Re-root the walk on the web area while keeping the window's frame, so browser chrome
        // (toolbar, address field, tab bar) is structurally out of reach.
        let rooted = AXNode(
            role: window.role, value: nil, title: window.title, url: url,
            frame: window.frame, focused: window.focused, children: [webArea],
            identifier: window.identifier, label: window.label, subrole: window.subrole,
            headingLevel: window.headingLevel, selected: window.selected,
            placeholder: window.placeholder, selectedText: window.selectedText,
            hidden: window.hidden, domClassList: window.domClassList,
            domIdentifier: window.domIdentifier
        )
        return GenericPageExtractor.extract(window: rooted, focusedElement: nil,
                                            url: url, options: options)
    }

    public static func parse(window: AXNode, tab: TabCapture) -> CapturedContent {
        var options = GenericPageExtractor.Options()
        options.offscreenPolicy = .accessibilityScroll(maxSteps: 3, maxCharacters: 64_000)
        return parse(window: window, tab: tab, options: options)
    }

    static func parse(
        window: AXNode,
        tab: TabCapture,
        options: GenericPageExtractor.Options
    ) -> CapturedContent {
        guard let webArea = BrowserTabExtractor.primaryWebArea(
            in: window, windowTitle: tab.title, engine: nil
        ) else {
            // No web area at all (a native error sheet, a blank tab). Walking the page remainder
            // is worse than a web-area root but far better than storing nothing.
            return .generic(GenericPageExtractor.extract(
                window: withoutToolbars(window), focusedElement: nil,
                url: tab.url, options: options
            ).page)
        }
        return .generic(extract(window: window, webArea: webArea,
                                url: tab.url, options: options).page)
    }

    /// A no-web-area fallback must not turn the address bar into user content.
    private static func withoutToolbars(_ node: AXNode) -> AXNode {
        AXNode(
            role: node.role, value: node.value, title: node.title, url: node.url,
            frame: node.frame, focused: node.focused,
            children: node.children.filter { $0.role != "AXToolbar" }.map(withoutToolbars),
            identifier: node.identifier, label: node.label, subrole: node.subrole,
            headingLevel: node.headingLevel, selected: node.selected,
            placeholder: node.placeholder, selectedText: node.selectedText, hidden: node.hidden,
            domClassList: node.domClassList, domIdentifier: node.domIdentifier
        )
    }
}
