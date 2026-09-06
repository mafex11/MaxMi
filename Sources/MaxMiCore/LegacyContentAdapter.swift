import Foundation

/// Adapts an already-rendered capture string into the typed contract, for every row written
/// before schema v10 and every parser that has not been migrated yet.
public enum LegacyContentAdapter {
    /// One `.main` region of `.paragraph` blocks, one per line.
    ///
    /// Empty lines are preserved as empty `.paragraph` blocks: the round-trip invariant
    /// `ContentRenderer.render(adapt(s, kind:), .full) == s` must hold byte-for-byte, and real
    /// rendered captures do contain blank lines (a `.document` renders one after its title).
    ///
    /// `kind` is accepted, and deliberately unused, so the call site reads honestly and so a
    /// future refinement can specialise per kind without changing every caller.
    public static func adapt(renderedContent: String, kind: CaptureContentKind) -> CapturedContent {
        let blocks = renderedContent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Block(type: .paragraph, text: String($0)) }
        return .generic(GenericPage(
            regions: [Region(kind: .main, blocks: blocks)],
            focused: nil,
            url: nil
        ))
    }
}
