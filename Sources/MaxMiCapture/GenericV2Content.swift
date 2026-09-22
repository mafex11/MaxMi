import Foundation
import MaxMiCore

/// Typed `.generic` content for parsers that do not yet have an anchored shape (Phase D, spec 7c).
enum GenericV2Content {
    /// A typed page plus whether budgeting dropped anything. `truncated` is not derivable from
    /// the rendered length — a page can sit under its budget and still have been trimmed, and a
    /// page can sit exactly on a large budget without having been.
    struct Page {
        let content: CapturedContent
        let truncated: Bool
    }

    /// The v2 extractor's page. nil when the window has no readable content, so the caller can
    /// return nil and let dispatch decide.
    static func page(
        window: AXNode,
        url: String? = nil,
        budget: Int = DocumentExtraction.contentCap,
        offscreenPolicy: OffscreenCapturePolicy
    ) -> Page? {
        var options = GenericPageExtractor.Options()
        options.totalBudget = budget
        options.offscreenPolicy = offscreenPolicy
        let result = GenericPageExtractor.extract(
            window: window, focusedElement: nil, url: url, options: options
        )
        guard !result.page.regions.isEmpty else { return nil }
        return Page(content: .generic(result.page), truncated: result.truncated)
    }

    /// One `.main` region of `.paragraph` blocks, for parsers whose own line collection is
    /// better than the generic walk (Discord's chrome filter, Messages' bubble ordering).
    static func lines(_ lines: [String]) -> CapturedContent? {
        let blocks = lines.filter { !$0.isEmpty }.map { Block(type: .paragraph, text: $0) }
        guard !blocks.isEmpty else { return nil }
        return .generic(GenericPage(
            regions: [Region(kind: .main, blocks: blocks)], focused: nil, url: nil
        ))
    }
}
