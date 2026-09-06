import Foundation

public struct StructuredAccumulationResult: Sendable, Equatable {
    public let content: CapturedContent
    /// `ContentRenderer.render(content, style: .full)` — what goes into `versions.content`.
    public let rendered: String
    public let changed: Bool
    /// Never discarded. `Store.commitCapture` hands it back through `CommitResult`.
    public let delta: CaptureDelta

    public init(content: CapturedContent, rendered: String, changed: Bool, delta: CaptureDelta) {
        self.content = content
        self.rendered = rendered
        self.changed = changed
        self.delta = delta
    }
}

extension CaptureAccumulator {
    /// Kind-aware accumulation. The incoming shape wins; a shape change is a replace.
    public static func merge(
        previous: CapturedContent?,
        incoming: CapturedContent,
        policy: CaptureAccumulationPolicy,
        maxCharacters: Int
    ) -> StructuredAccumulationResult {
        // No lower floor: `OffscreenCapturePolicy` already clamps its `maxCharacters` to
        // 1,000, and callers that pass a smaller explicit budget mean it.
        let cap = max(0, maxCharacters)
        let merged: CapturedContent
        if let previous, sameShape(previous, incoming) {
            merged = mergeSameShape(previous: previous, incoming: incoming, policy: policy)
        } else {
            merged = incoming
        }
        let bounded = bound(merged, to: cap)
        return StructuredAccumulationResult(
            content: bounded,
            rendered: ContentRenderer.render(bounded, style: .full),
            changed: previous != bounded,
            delta: CaptureDelta.between(previous: previous, merged: bounded)
        )
    }

    static func sameShape(_ lhs: CapturedContent, _ rhs: CapturedContent) -> Bool {
        switch (lhs, rhs) {
        case (.document, .document), (.conversation, .conversation), (.tasks, .tasks),
             (.calendar, .calendar), (.terminal, .terminal), (.generic, .generic):
            return true
        default:
            return false
        }
    }

    static func mergeSameShape(
        previous: CapturedContent,
        incoming: CapturedContent,
        policy: CaptureAccumulationPolicy
    ) -> CapturedContent {
        switch (previous, incoming) {
        case (.conversation(let old), .conversation(let new)):
            guard policy != .replace else { return incoming }
            var messages = old.messages.filter { !$0.isDraft }
            let existing = Set(messages.map(\.id))
            for message in new.messages where !message.isDraft && !existing.contains(message.id) {
                messages.append(message)
            }
            // At most one draft per (sender, isUser), always the incoming one: a draft is a
            // live edit, not history.
            messages.append(contentsOf: latestDrafts(new.messages.filter(\.isDraft)))
            return .conversation(Conversation(channel: new.channel, isGroup: new.isGroup,
                                             messages: messages))
        case (.terminal(let old), .terminal(let new)):
            guard policy != .replace, old.cwd == new.cwd,
                  CaptureDelta.isSegmentPrefix(old.segments, new.segments),
                  new.segments.count > old.segments.count else { return incoming }
            var segments = old.segments.map {
                TerminalSegment(command: $0.command, output: $0.output, isRunning: false)
            }
            segments.append(contentsOf: new.segments.dropFirst(old.segments.count))
            return .terminal(TerminalSession(cwd: new.cwd, segments: segments))
        case (.generic, .generic):
            // Legacy bridge: a not-yet-migrated parser still hands us a rendered string that
            // `LegacyContentAdapter` shapes into `.generic`, and its declared accumulation
            // policy has to keep working, so the string accumulator runs on the rendered
            // texts and the result is re-adapted. Structured pages from `GenericPageExtractor`
            // are NOT legacy-shaped and keep the `.generic` = replace rule.
            // Phase D removes this bridge once every parser emits structured content.
            guard policy != .replace, previous.isLegacyShaped, incoming.isLegacyShaped else {
                return incoming
            }
            // `Int.max` disables the string accumulator's own ellipsis truncation: bounding is
            // `CaptureAccumulator.bound`'s job, and it trims whole lines instead of splitting one.
            let merged = merge(
                previous: ContentRenderer.render(previous, style: .full),
                incoming: ContentRenderer.render(incoming, style: .full),
                policy: policy,
                maxCharacters: Int.max
            )
            return LegacyContentAdapter.adapt(renderedContent: merged.content, kind: .generic)
        default:
            // .document / .tasks / .calendar all replace with incoming.
            return incoming
        }
    }

    static func latestDrafts(_ drafts: [Message]) -> [Message] {
        var byKey: [String: Message] = [:]
        var order: [String] = []
        for draft in drafts {
            let key = "\(draft.isUser)\u{1F}\(draft.sender)"
            if byKey[key] == nil { order.append(key) }
            byKey[key] = draft
        }
        return order.compactMap { byKey[$0] }
    }

    /// Bounds the RENDERED form, trimming whole blocks/messages/segments from the front
    /// (oldest first) — never mid-item, and never below one item. Public because the migrated
    /// parsers cap their own output the same way instead of each reinventing it.
    public static func bound(_ content: CapturedContent, to maxCharacters: Int) -> CapturedContent {
        let cap = max(0, maxCharacters)
        guard ContentRenderer.render(content, style: .full).count > cap else { return content }
        switch content {
        case .conversation(let value):
            let kept = dropOldest(value.messages, cost: { ContentRenderer.renderMessage($0).count }, cap: cap)
            return .conversation(Conversation(channel: value.channel, isGroup: value.isGroup, messages: kept))
        case .terminal(let value):
            // Segments render separated by a blank line, so each costs two joining newlines.
            let kept = dropOldest(value.segments,
                                  cost: { ContentRenderer.renderSegment($0).count + 1 }, cap: cap)
            return .terminal(TerminalSession(cwd: value.cwd, segments: kept))
        case .tasks(let items):
            return .tasks(dropOldest(items, cost: { ContentRenderer.renderTask($0).count }, cap: cap))
        case .calendar(let events):
            return .calendar(dropOldest(events, cost: { ContentRenderer.renderEvent($0).count }, cap: cap))
        case .document(let value):
            // The title line is always kept; it is the document's identity.
            let titleCost = "# \(value.title)".count + 2
            let kept = dropOldest(value.blocks, cost: { ContentRenderer.renderBlock($0).count },
                                  cap: max(0, cap - titleCost))
            return .document(Document(title: value.title, blocks: kept,
                                      author: value.author, url: value.url))
        case .generic(let page):
            var regions = page.regions
            var urlCost = 0
            if let url = page.url, !url.isEmpty { urlCost = "URL: \(url)".count + 1 }
            // Drop from the front of the first region, then drop that region and continue.
            while !regions.isEmpty {
                let candidate = GenericPage(regions: regions, focused: page.focused, url: page.url)
                if ContentRenderer.render(.generic(candidate), style: .full).count <= cap { break }
                let first = regions[0]
                let others = regions.dropFirst().reduce(0) { $0 + ContentRenderer.renderBlocks($1.blocks).count + 1 }
                let allowance = max(0, cap - urlCost - others)
                let kept = dropOldest(first.blocks, cost: { ContentRenderer.renderBlock($0).count },
                                      cap: allowance)
                if kept.count == first.blocks.count { regions.removeFirst(); continue }
                regions[0] = Region(kind: first.kind, blocks: kept)
                if kept.count <= 1 && regions.count > 1 { break }
            }
            return .generic(GenericPage(regions: regions, focused: page.focused, url: page.url))
        }
    }

    /// Drops items from the FRONT until the joined cost fits, always keeping at least one.
    static func dropOldest<Item>(_ items: [Item], cost: (Item) -> Int, cap: Int) -> [Item] {
        guard items.count > 1 else { return items }
        var kept = items
        var total = kept.reduce(0) { $0 + cost($1) + 1 } - 1
        while kept.count > 1, total > cap {
            total -= cost(kept.removeFirst()) + 1
        }
        return kept
    }
}
