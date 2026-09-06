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
            // The delta describes what CHANGED, not what FIT. `bound` sheds `.dialog` last but it
            // does shed it (`boundGeneric`), and a delta computed from the bounded value would
            // silently lose the `dialog` event for exactly the over-cap pages most likely to have
            // one (Ruling 6). `content`/`rendered`/`changed` keep describing what was stored.
            delta: CaptureDelta.between(previous: previous, merged: merged)
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
    /// (oldest first) — never mid-item, and never below one item. `.generic` pages shed chrome
    /// regions before `.main` content; see `boundGeneric`. Public because the migrated parsers
    /// cap their own output the same way instead of each reinventing it.
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
            return .generic(boundGeneric(page, to: cap))
        }
    }

    /// A HARD cap, for parsers that must not let one pathological item bloat a version.
    /// `bound` is deliberately soft — it keeps a single over-cap item whole rather than rendering
    /// an empty value. `boundHard` applies `bound` first and then trims the one surviving message
    /// so the rendered form fits: the body keeps its TAIL (the newest words), and if even the
    /// rendered head (`(From: sender)(sent time): `) is over the cap the head is bounded too.
    /// Only `.conversation` is trimmed further; every other shape keeps `bound`'s soft floor.
    /// Bounding the STRUCTURED value is what keeps `content == render(content, .full)` true for
    /// the caller, which a string post-trim would break.
    public static func boundHard(_ content: CapturedContent, to maxCharacters: Int) -> CapturedContent {
        let cap = max(0, maxCharacters)
        let bounded = bound(content, to: cap)
        guard case .conversation(let value) = bounded, let message = value.messages.first,
              value.messages.count == 1,
              ContentRenderer.renderMessage(message).count > cap else { return bounded }
        return .conversation(Conversation(channel: value.channel, isGroup: value.isGroup,
                                          messages: [fitted(message, to: cap)]))
    }

    /// Trims one message until it renders within `cap`: body tail first, then the sender label,
    /// then the time label. A cap below the empty render (`"(From: ): "`) cannot be honoured.
    private static func fitted(_ message: Message, to cap: Int) -> Message {
        var sender = message.sender
        var text = message.text
        var timeString = message.timeString
        var timestamp = message.timestamp
        func candidate() -> Message {
            Message(id: Message.makeID(sender: sender, timeString: timeString, text: text),
                    sender: sender, text: text, timestamp: timestamp, timeString: timeString,
                    isUser: message.isUser, isDraft: message.isDraft)
        }
        func overflow() -> Int { ContentRenderer.renderMessage(candidate()).count - cap }
        // Dropping n characters of body removes at least n from the render (a newline renders as
        // "\n  "), so one pass always reaches the cap when the body is long enough.
        if overflow() > 0 { text = String(text.dropFirst(min(overflow(), text.count))) }
        // A name reads from the front, so the sender keeps its prefix.
        if overflow() > 0 { sender = String(sender.dropLast(min(overflow(), sender.count))) }
        // Last resort: the "(sent …)" segment goes entirely.
        if overflow() > 0 { timeString = nil; timestamp = nil }
        return candidate()
    }

    /// Trims a page's CHROME before its content: kinds are shed in reverse
    /// `ContentRenderer.regionOrder` (`.unknown` first, `.dialog` last) and `.main` only after
    /// every other kind is gone, because the user is reading `.main`. Within a kind, later
    /// regions and older (front) blocks go first. Soft cap: the last surviving region keeps its
    /// last block and `.main` always keeps one, so a single block longer than the cap is retained
    /// rather than the page rendering as an empty string.
    static func boundGeneric(_ page: GenericPage, to cap: Int) -> GenericPage {
        var regions = page.regions
        // Rendered cost of each block including the newline that joins it. Computed once:
        // trimming only ever removes entries.
        var costs = regions.map { $0.blocks.map { ContentRenderer.renderBlock($0).count + 1 } }
        var blockTotal = costs.reduce(0) { $0 + $1.reduce(0, +) }
        let urlCost: Int = {
            guard let url = page.url, !url.isEmpty else { return 0 }
            return "URL: \(url)".count + 1
        }()
        // Region headers are part of the rendered size, and a header disappears with the last
        // block of its kind, so they are re-totalled whenever a region empties.
        func headerTotal() -> Int {
            ContentRenderer.regionOrder.reduce(0) { total, kind in
                guard let header = ContentRenderer.regionHeader(kind),
                      regions.contains(where: { $0.kind == kind && !$0.blocks.isEmpty })
                else { return total }
                return total + header.count + 1
            }
        }
        var headers = headerTotal()
        // Chunks are joined by a single newline, so the very last join is not paid for.
        func size() -> Int { max(0, urlCost + blockTotal + headers - 1) }
        guard size() > cap else { return page }

        for kind in ContentRenderer.regionOrder.reversed().filter({ $0 != .main }) + [.main] {
            guard size() > cap else { break }
            for index in regions.indices.reversed() where regions[index].kind == kind {
                while size() > cap, !regions[index].blocks.isEmpty {
                    let othersHaveBlocks = regions.indices.contains {
                        $0 != index && !regions[$0].blocks.isEmpty
                    }
                    // The last block of the last surviving region stays, and `.main` never
                    // empties: an over-cap page is still worth more than nothing.
                    if regions[index].blocks.count == 1, kind == .main || !othersHaveBlocks { break }
                    blockTotal -= costs[index].removeFirst()
                    regions[index] = Region(kind: kind,
                                            blocks: Array(regions[index].blocks.dropFirst()))
                    if regions[index].blocks.isEmpty { headers = headerTotal() }
                }
            }
        }
        let kept = regions.filter { !$0.blocks.isEmpty }
        return GenericPage(regions: kept.isEmpty ? regions : kept,
                           focused: page.focused, url: page.url)
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
