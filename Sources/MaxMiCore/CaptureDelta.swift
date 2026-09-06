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

    public init(addedBlocks: [Block] = [], addedMessages: [Message] = [],
                addedSegments: [TerminalSegment] = [], removedCount: Int = 0,
                addedChars: Int = 0, removedChars: Int = 0, isFirstCapture: Bool = false) {
        self.addedBlocks = addedBlocks
        self.addedMessages = addedMessages
        self.addedSegments = addedSegments
        self.removedCount = removedCount
        self.addedChars = addedChars
        self.removedChars = removedChars
        self.isFirstCapture = isFirstCapture
    }

    public var isEmpty: Bool {
        addedBlocks.isEmpty && addedMessages.isEmpty && addedSegments.isEmpty
            && removedCount == 0
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
            // `.dialog` region appearing is reported as a dialog event in Phase B instead.
            return blockDelta(old: previousMainBlocks(previous), new: mainBlocks(current),
                              addedChars: addedChars, removedChars: removedChars, isFirst: isFirst)
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
