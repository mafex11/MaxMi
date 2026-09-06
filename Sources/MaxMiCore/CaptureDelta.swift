import Foundation

/// What actually changed in one capture. Exactly one of the three `added*` arrays is non-empty
/// for any given delta; the others are empty. A struct rather than an enum so the encrypted JSON
/// payload Phase B writes stays flat and stable.
public struct CaptureDelta: Codable, Sendable, Equatable {
    public let addedBlocks: [Block]
    public let addedMessages: [Message]
    public let addedSegments: [TerminalSegment]
    public let removedCount: Int
    public let addedChars: Int
    public let removedChars: Int
    public let isFirstCapture: Bool
    /// The blocks of a `.dialog` region that appeared in this capture and was NOT in the
    /// previous one. Empty for every other case, including a dialog that was already on screen
    /// and every non-`.generic` shape.
    ///
    /// It rides on the delta because `between` is the only function that sees both the previous
    /// and the merged content — `AppWiring.finishCapture`, which writes the `dialog` event, has
    /// only the `CommitResult` (spec 12 Q12).
    public let dialogBlocks: [Block]

    public init(addedBlocks: [Block] = [], addedMessages: [Message] = [],
                addedSegments: [TerminalSegment] = [], removedCount: Int = 0,
                addedChars: Int = 0, removedChars: Int = 0, isFirstCapture: Bool = false,
                dialogBlocks: [Block] = []) {
        self.addedBlocks = addedBlocks
        self.addedMessages = addedMessages
        self.addedSegments = addedSegments
        self.removedCount = removedCount
        self.addedChars = addedChars
        self.removedChars = removedChars
        self.isFirstCapture = isFirstCapture
        self.dialogBlocks = dialogBlocks
    }

    private enum CodingKeys: String, CodingKey {
        case addedBlocks, addedMessages, addedSegments, removedCount
        case addedChars, removedChars, isFirstCapture, dialogBlocks
    }

    /// `dialogBlocks` is decoded leniently so a payload written before it existed still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        addedBlocks = try c.decode([Block].self, forKey: .addedBlocks)
        addedMessages = try c.decode([Message].self, forKey: .addedMessages)
        addedSegments = try c.decode([TerminalSegment].self, forKey: .addedSegments)
        removedCount = try c.decode(Int.self, forKey: .removedCount)
        addedChars = try c.decode(Int.self, forKey: .addedChars)
        removedChars = try c.decode(Int.self, forKey: .removedChars)
        isFirstCapture = try c.decode(Bool.self, forKey: .isFirstCapture)
        dialogBlocks = try c.decodeIfPresent([Block].self, forKey: .dialogBlocks) ?? []
    }

    public var isEmpty: Bool {
        addedBlocks.isEmpty && addedMessages.isEmpty && addedSegments.isEmpty
            && removedCount == 0
    }

    /// Whether this delta is worth a `content_delta` event.
    ///
    /// NOT `!isEmpty`: `.tasks` and `.calendar` deltas carry no arrays and no `removedCount` by
    /// design (spec 5a), so `isEmpty` is always true for them and gating on it would drop every
    /// Reminders and Calendar event. The rendered character counts are the only change signal
    /// those two shapes have.
    public var hasRecordableChange: Bool {
        !isEmpty || addedChars > 0 || removedChars > 0
    }

    public static let empty = CaptureDelta()

    /// Computed once, inside `CaptureAccumulator.merge`. Never recomputed elsewhere.
    public static func between(previous: CapturedContent?, merged: CapturedContent) -> CaptureDelta {
        let previousRendered = previous.map { ContentRenderer.render($0, style: .full) } ?? ""
        let mergedRendered = ContentRenderer.render(merged, style: .full)
        let addedChars = max(0, mergedRendered.count - previousRendered.count)
        let removedChars = max(0, previousRendered.count - mergedRendered.count)
        let isFirst = previous == nil

        switch merged {
        case .conversation(let current):
            let old = previousMessages(previous)
            let oldIDs = Set(old.map(\.id))
            let currentIDs = Set(current.messages.map(\.id))
            return CaptureDelta(
                addedMessages: current.messages.filter { !oldIDs.contains($0.id) },
                removedCount: old.filter { !currentIDs.contains($0.id) }.count,
                addedChars: addedChars, removedChars: removedChars, isFirstCapture: isFirst)
        case .terminal(let current):
            let old = previousSegments(previous)
            let appended = isSegmentPrefix(old, current.segments)
            return CaptureDelta(
                addedSegments: appended ? Array(current.segments.dropFirst(old.count)) : [],
                removedCount: appended ? 0 : old.count,
                addedChars: addedChars, removedChars: removedChars, isFirstCapture: isFirst)
        case .document(let current):
            return blockDelta(old: previousDocumentBlocks(previous), new: current.blocks,
                              addedChars: addedChars, removedChars: removedChars, isFirst: isFirst)
        case .generic(let current):
            // Only `.main` counts: chrome churns constantly and would drown the signal. A
            // `.dialog` region appearing is reported separately, in `dialogBlocks`.
            var delta = blockDelta(old: previousMainBlocks(previous), new: mainBlocks(current),
                                   addedChars: addedChars, removedChars: removedChars,
                                   isFirst: isFirst)
            let dialog = appearingDialogBlocks(previous: previous, merged: merged)
            if !dialog.isEmpty {
                delta = CaptureDelta(
                    addedBlocks: delta.addedBlocks, addedMessages: delta.addedMessages,
                    addedSegments: delta.addedSegments, removedCount: delta.removedCount,
                    addedChars: delta.addedChars, removedChars: delta.removedChars,
                    isFirstCapture: delta.isFirstCapture, dialogBlocks: dialog)
            }
            return delta
        case .tasks, .calendar:
            return CaptureDelta(addedChars: addedChars, removedChars: removedChars,
                                isFirstCapture: isFirst)
        }
    }

    static func blockDelta(old: [Block], new: [Block], addedChars: Int, removedChars: Int,
                           isFirst: Bool) -> CaptureDelta {
        let oldTexts = Set(old.map(\.text))
        let newTexts = Set(new.map(\.text))
        return CaptureDelta(
            addedBlocks: new.filter { !oldTexts.contains($0.text) },
            removedCount: old.filter { !newTexts.contains($0.text) }.count,
            addedChars: addedChars, removedChars: removedChars, isFirstCapture: isFirst)
    }

    static func mainBlocks(_ page: GenericPage) -> [Block] {
        page.regions.filter { $0.kind == .main }.flatMap(\.blocks)
    }

    /// A `.dialog` region present in `merged` but absent from `previous`. `previous == nil` counts
    /// as absent, so the first capture of a window that already has a sheet on it reports it.
    static func appearingDialogBlocks(previous: CapturedContent?, merged: CapturedContent) -> [Block] {
        guard case .generic(let current) = merged,
              let dialog = current.regions.first(where: { $0.kind == .dialog }),
              !dialog.blocks.isEmpty else { return [] }
        if case .generic(let old) = previous, old.regions.contains(where: { $0.kind == .dialog }) {
            return []
        }
        return dialog.blocks
    }

    static func previousMessages(_ previous: CapturedContent?) -> [Message] {
        if case .conversation(let value) = previous { return value.messages }
        return []
    }

    static func previousSegments(_ previous: CapturedContent?) -> [TerminalSegment] {
        if case .terminal(let value) = previous { return value.segments }
        return []
    }

    static func previousDocumentBlocks(_ previous: CapturedContent?) -> [Block] {
        if case .document(let value) = previous { return value.blocks }
        return []
    }

    static func previousMainBlocks(_ previous: CapturedContent?) -> [Block] {
        if case .generic(let value) = previous { return mainBlocks(value) }
        return []
    }

    /// Prefix under `(command, output)` equality — `isRunning` is volatile and never compared.
    static func isSegmentPrefix(_ prefix: [TerminalSegment], _ whole: [TerminalSegment]) -> Bool {
        guard prefix.count <= whole.count else { return false }
        for (index, segment) in prefix.enumerated() {
            if segment.command != whole[index].command || segment.output != whole[index].output {
                return false
            }
        }
        return true
    }
}
