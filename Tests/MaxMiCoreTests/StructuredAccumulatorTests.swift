import XCTest
@testable import MaxMiCore

final class StructuredAccumulatorTests: XCTestCase {
    func message(_ sender: String, _ text: String, time: String? = nil,
                 isUser: Bool = false, isDraft: Bool = false) -> Message {
        Message(id: Message.makeID(sender: sender, timeString: time, text: text),
                sender: sender, text: text, timestamp: nil, timeString: time,
                isUser: isUser, isDraft: isDraft)
    }

    func conversation(_ messages: [Message], channel: String = "#dev") -> CapturedContent {
        .conversation(Conversation(channel: channel, isGroup: true, messages: messages))
    }

    func merge(_ previous: CapturedContent?, _ incoming: CapturedContent,
               policy: CaptureAccumulationPolicy = .appendItems,
               maxCharacters: Int = 10_000) -> StructuredAccumulationResult {
        CaptureAccumulator.merge(previous: previous, incoming: incoming,
                                 policy: policy, maxCharacters: maxCharacters)
    }

    func testFirstCaptureIsTheIncomingValueAndIsMarkedFirst() {
        let incoming = conversation([message("Ana", "one")])
        let result = merge(nil, incoming)
        XCTAssertEqual(result.content, incoming)
        XCTAssertEqual(result.rendered, ContentRenderer.render(incoming, style: .full))
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.delta.isFirstCapture)
        XCTAssertEqual(result.delta.addedMessages.map(\.text), ["one"])
        XCTAssertEqual(result.delta.removedCount, 0)
    }

    func testConversationUnionsByMessageIdPreservingOrder() {
        let previous = conversation([message("Ana", "one"), message("Bo", "two")])
        let incoming = conversation([message("Bo", "two"), message("Cy", "three")])
        let result = merge(previous, incoming)
        guard case .conversation(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.messages.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(result.delta.addedMessages.map(\.text), ["three"])
        XCTAssertEqual(result.delta.removedCount, 0)
        XCTAssertFalse(result.delta.isFirstCapture)
        XCTAssertTrue(result.changed)
    }

    func testConversationUnchangedIncomingReportsNoChangeAndEmptyDelta() {
        let previous = conversation([message("Ana", "one")])
        let result = merge(previous, conversation([message("Ana", "one")]))
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.delta.isEmpty)
    }

    func testOnlyTheIncomingDraftSurvivesPerSenderAndAlwaysSitsLast() {
        let previous = conversation([
            message("Ana", "one"),
            message("Sudhanshu", "old draft", isUser: true, isDraft: true),
        ])
        let incoming = conversation([
            message("Ana", "one"),
            message("Sudhanshu", "new draft", isUser: true, isDraft: true),
        ])
        guard case .conversation(let merged) = merge(previous, incoming).content else { return XCTFail() }
        XCTAssertEqual(merged.messages.map(\.text), ["one", "new draft"])
        XCTAssertEqual(merged.messages.filter(\.isDraft).count, 1, "a draft is a live edit, not history")
    }

    func testReplacePolicyDropsPreviousMessagesAndCountsThemRemoved() {
        let previous = conversation([message("Ana", "one"), message("Bo", "two")])
        let incoming = conversation([message("Cy", "three")])
        let result = merge(previous, incoming, policy: .replace)
        guard case .conversation(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.messages.map(\.text), ["three"])
        XCTAssertEqual(result.delta.removedCount, 2)
        XCTAssertEqual(result.delta.addedMessages.map(\.text), ["three"])
    }

    func testTerminalAppendsWhenCwdMatchesAndPreviousIsAPrefix() {
        let previous = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift build", output: "ok", isRunning: false),
        ]))
        let incoming = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift build", output: "ok", isRunning: false),
            TerminalSegment(command: "swift test", output: "2 failures", isRunning: true),
        ]))
        let result = merge(previous, incoming)
        guard case .terminal(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.segments.map(\.command), ["swift build", "swift test"])
        XCTAssertEqual(merged.segments.last?.isRunning, true, "isRunning always comes from incoming")
        XCTAssertEqual(result.delta.addedSegments.map(\.command), ["swift test"])
    }

    func testTerminalReplacesOnCwdChangeOrDivergentHistory() {
        let previous = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "swift build", output: "ok", isRunning: false),
        ]))
        let otherDir = CapturedContent.terminal(TerminalSession(cwd: "yuki", segments: [
            TerminalSegment(command: "ls", output: "a", isRunning: false),
        ]))
        guard case .terminal(let replaced) = merge(previous, otherDir).content else { return XCTFail() }
        XCTAssertEqual(replaced.segments.map(\.command), ["ls"])

        let divergent = CapturedContent.terminal(TerminalSession(cwd: "maxmi", segments: [
            TerminalSegment(command: "clear", output: "", isRunning: false),
        ]))
        let result = merge(previous, divergent)
        guard case .terminal(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.segments.map(\.command), ["clear"])
        XCTAssertTrue(result.delta.addedSegments.isEmpty, "a replace appends nothing")
        XCTAssertEqual(result.delta.removedCount, 1)
    }

    func testDocumentAndGenericReplaceAndReportAddedMainBlocks() {
        let previous = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "old line")]),
            Region(kind: .sidebar, blocks: [Block(type: .label, text: "Chrome churn A")]),
        ], focused: nil, url: nil))
        let incoming = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .main, blocks: [Block(type: .paragraph, text: "old line"),
                                         Block(type: .paragraph, text: "new line")]),
            Region(kind: .sidebar, blocks: [Block(type: .label, text: "Chrome churn B")]),
        ], focused: nil, url: nil))
        let result = merge(previous, incoming, policy: .rollingText)
        XCTAssertEqual(result.content, incoming, ".generic replaces with incoming")
        XCTAssertEqual(result.delta.addedBlocks.map(\.text), ["new line"],
                       "non-main regions are ignored for delta purposes")
    }

    func testDocumentDeltaUsesItsOwnBlocks() {
        let previous = CapturedContent.document(Document(
            title: "Notes", blocks: [Block(type: .paragraph, text: "a")], author: .user, url: nil))
        let incoming = CapturedContent.document(Document(
            title: "Notes", blocks: [Block(type: .paragraph, text: "a"),
                                     Block(type: .paragraph, text: "b")], author: .user, url: nil))
        let result = merge(previous, incoming, policy: .rollingText)
        XCTAssertEqual(result.content, incoming)
        XCTAssertEqual(result.delta.addedBlocks.map(\.text), ["b"])
    }

    func testTasksAndCalendarReplaceAndOnlyReportCharCounts() {
        let previous = CapturedContent.tasks([
            TaskItem(title: "one", status: .open, due: nil, dueString: nil, project: nil, tags: [], notes: nil),
        ])
        let incoming = CapturedContent.tasks([
            TaskItem(title: "one", status: .completed, due: nil, dueString: nil, project: nil, tags: [], notes: nil),
            TaskItem(title: "two", status: .open, due: nil, dueString: nil, project: nil, tags: [], notes: nil),
        ])
        let result = merge(previous, incoming, policy: .replace)
        XCTAssertEqual(result.content, incoming)
        XCTAssertTrue(result.delta.addedBlocks.isEmpty)
        XCTAssertTrue(result.delta.addedMessages.isEmpty)
        XCTAssertTrue(result.delta.addedSegments.isEmpty)
        XCTAssertGreaterThan(result.delta.addedChars, 0, "something changed is still visible")

        let calendarPrevious = CapturedContent.calendar([
            CalendarEvent(title: "Sync", dateString: "Mon 09:00", start: nil, end: nil,
                          organizer: nil, location: nil, hasConference: false, notes: nil),
        ])
        XCTAssertEqual(merge(calendarPrevious, calendarPrevious).content, calendarPrevious)
    }

    func testShapeChangeIsAlwaysAReplace() {
        let previous = conversation([message("Ana", "one")])
        let incoming = CapturedContent.terminal(TerminalSession(cwd: nil, segments: [
            TerminalSegment(command: "ls", output: "a", isRunning: false),
        ]))
        let result = merge(previous, incoming)
        XCTAssertEqual(result.content, incoming)
        XCTAssertEqual(result.delta.addedSegments.count, 1)
    }

    func testBoundingTrimsWholeMessagesFromTheFrontAndNeverSplitsOne() {
        let messages = (0..<40).map { message("Ana", "message number \($0)") }
        let result = merge(nil, conversation(messages), maxCharacters: 300)
        guard case .conversation(let merged) = result.content else { return XCTFail() }
        XCTAssertLessThanOrEqual(result.rendered.count, 300)
        XCTAssertLessThan(merged.messages.count, 40)
        XCTAssertEqual(merged.messages.last?.text, "message number 39", "oldest go first")
        for rendered in merged.messages.map(ContentRenderer.renderMessage) {
            XCTAssertTrue(result.rendered.contains(rendered), "no message is cut mid-way")
        }
    }

    func testBoundingKeepsAtLeastOneItem() {
        let long = String(repeating: "x", count: 5_000)
        let result = merge(nil, conversation([message("Ana", long)]), maxCharacters: 1_000)
        guard case .conversation(let merged) = result.content else { return XCTFail() }
        XCTAssertEqual(merged.messages.count, 1, "never trim below one whole item")
    }

    func testLegacyShapedGenericStillAccumulatesForUnmigratedParsers() {
        let previous = LegacyContentAdapter.adapt(renderedContent: "Alice: one\nBob: two",
                                                  kind: .conversation)
        let incoming = LegacyContentAdapter.adapt(renderedContent: "Bob: two\nCarol: three",
                                                  kind: .conversation)
        XCTAssertTrue(previous.isLegacyShaped)
        let result = merge(previous, incoming)
        XCTAssertEqual(result.rendered, "Alice: one\nBob: two\nCarol: three",
                       "an unmigrated parser's declared policy still accumulates")
        XCTAssertEqual(result.delta.addedBlocks.map(\.text), ["Carol: three"])
        XCTAssertTrue(result.changed)
        XCTAssertFalse(result.delta.isFirstCapture)
    }

    func testStructuredGenericPageStillReplaces() {
        let previous = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .main, blocks: [Block(type: .heading(level: 1), text: "Docs"),
                                         Block(type: .paragraph, text: "old line")]),
        ], focused: nil, url: "https://example.com/docs"))
        let incoming = CapturedContent.generic(GenericPage(regions: [
            Region(kind: .main, blocks: [Block(type: .heading(level: 1), text: "Docs"),
                                         Block(type: .paragraph, text: "new line")]),
        ], focused: nil, url: "https://example.com/docs"))
        XCTAssertFalse(previous.isLegacyShaped)
        let result = merge(previous, incoming)
        XCTAssertEqual(result.content, incoming, "a structured page replaces, it never accumulates")
        XCTAssertEqual(result.delta.addedBlocks.map(\.text), ["new line"])
        XCTAssertEqual(result.delta.removedCount, 1)
    }

    func testCaptureDeltaEmptyAndCharCounts() {
        XCTAssertTrue(CaptureDelta.empty.isEmpty)
        XCTAssertFalse(CaptureDelta.empty.isFirstCapture)
        let previous = conversation([message("Ana", "one"), message("Bo", "two")])
        let delta = CaptureDelta.between(previous: previous, merged: conversation([message("Ana", "one")]))
        XCTAssertEqual(delta.removedCount, 1)
        XCTAssertGreaterThan(delta.removedChars, 0)
        XCTAssertEqual(delta.addedChars, 0)
    }
}
