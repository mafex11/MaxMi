import XCTest
@testable import MaxMiCore

final class CaptureDeltaSignalsTests: XCTestCase {
    private func page(_ regions: [Region], url: String? = nil) -> CapturedContent {
        .generic(GenericPage(regions: regions, focused: nil, url: url))
    }

    private func main(_ texts: [String]) -> Region {
        Region(kind: .main, blocks: texts.map { Block(type: .paragraph, text: $0) })
    }

    /// The whole reason `hasRecordableChange` exists: a Reminders capture carries no arrays and
    /// no `removedCount`, so `isEmpty` is true even though the list visibly changed.
    func testTaskDeltaIsEmptyButHasRecordableChange() {
        let before = CapturedContent.tasks([
            TaskItem(title: "Ship M8 Phase B", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        let after = CapturedContent.tasks([
            TaskItem(title: "Ship M8 Phase B", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
            TaskItem(title: "Write the timeline builder", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        let delta = CaptureDelta.between(previous: before, merged: after)
        XCTAssertTrue(delta.isEmpty, "tasks deltas carry no arrays; this is the trap")
        XCTAssertGreaterThan(delta.addedChars, 0)
        XCTAssertTrue(delta.hasRecordableChange)
    }

    func testSameLengthTaskCompletionIsRecordable() {
        let before = CapturedContent.tasks([
            TaskItem(title: "Ship M8 Phase B", status: .open, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])
        let after = CapturedContent.tasks([
            TaskItem(title: "Ship M8 Phase B", status: .completed, due: nil, dueString: nil,
                     project: nil, tags: [], notes: nil),
        ])

        let delta = CaptureDelta.between(previous: before, merged: after)

        XCTAssertTrue(delta.isEmpty)
        XCTAssertEqual(delta.addedChars, 0)
        XCTAssertEqual(delta.removedChars, 0)
        XCTAssertTrue(delta.contentChanged)
        XCTAssertTrue(delta.hasRecordableChange)
    }

    func testCalendarDeltaHasRecordableChangeOnShrink() {
        let event = CalendarEvent(title: "Design review", dateString: "Mon 10:00",
                                 start: nil, end: nil, organizer: nil, location: nil,
                                 hasConference: false, notes: nil)
        let delta = CaptureDelta.between(previous: .calendar([event, event]), merged: .calendar([event]))
        XCTAssertGreaterThan(delta.removedChars, 0)
        XCTAssertTrue(delta.hasRecordableChange)
    }

    func testIdenticalContentHasNoRecordableChange() {
        let content = page([main(["one", "two"])])
        let delta = CaptureDelta.between(previous: content, merged: content)
        XCTAssertFalse(delta.hasRecordableChange)
        XCTAssertTrue(delta.dialogBlocks.isEmpty)
    }

    func testAddedBlocksHaveRecordableChange() {
        let delta = CaptureDelta.between(previous: page([main(["one"])]),
                                         merged: page([main(["one", "two"])]))
        XCTAssertEqual(delta.addedBlocks.map(\.text), ["two"])
        XCTAssertTrue(delta.hasRecordableChange)
    }

    func testNewDialogRegionIsReportedInDialogBlocks() {
        let dialog = Region(kind: .dialog, blocks: [
            Block(type: .heading(level: 2), text: "Quit without saving?"),
            Block(type: .label, text: "Cancel"),
        ])
        let delta = CaptureDelta.between(previous: page([main(["one"])]),
                                         merged: page([main(["one"]), dialog]))
        XCTAssertEqual(delta.dialogBlocks.map(\.text), ["Quit without saving?", "Cancel"])
    }

    func testDialogAlreadyPresentIsNotReportedAgain() {
        let dialog = Region(kind: .dialog, blocks: [Block(type: .label, text: "OK")])
        let delta = CaptureDelta.between(previous: page([main(["one"]), dialog]),
                                         merged: page([main(["one", "two"]), dialog]))
        XCTAssertTrue(delta.dialogBlocks.isEmpty)
    }

    func testFirstCaptureWithADialogReportsIt() {
        let dialog = Region(kind: .dialog, blocks: [Block(type: .label, text: "Allow")])
        let delta = CaptureDelta.between(previous: nil, merged: page([main(["body"]), dialog]))
        XCTAssertTrue(delta.isFirstCapture)
        XCTAssertEqual(delta.dialogBlocks.map(\.text), ["Allow"])
    }

    func testNonGenericShapesNeverCarryDialogBlocks() {
        let message = Message(id: "m1", sender: "Ana", text: "hi", timestamp: nil,
                              timeString: "10:01", isUser: false, isDraft: false)
        let delta = CaptureDelta.between(
            previous: nil,
            merged: .conversation(Conversation(channel: "#maxmi", isGroup: true, messages: [message])))
        XCTAssertTrue(delta.dialogBlocks.isEmpty)
    }

    /// A payload written by a build that did not know about `dialogBlocks` must still decode.
    func testDecodesPayloadWithoutDialogBlocks() throws {
        let json = """
        {"addedBlocks":[],"addedChars":12,"addedMessages":[],"addedSegments":[],\
        "isFirstCapture":false,"removedChars":0,"removedCount":0}
        """
        let delta = try CapturedContentEnvelope.makeDecoder()
            .decode(CaptureDelta.self, from: Data(json.utf8))
        XCTAssertTrue(delta.dialogBlocks.isEmpty)
        XCTAssertFalse(delta.contentChanged)
        XCTAssertTrue(delta.hasRecordableChange)
    }

    /// Ruling 6: bounding sheds `.dialog` last, but it does shed it. The delta describes what
    /// CHANGED, not what fit, so a sheet that appeared on an over-cap page must still produce a
    /// `dialog` event even though the stored content no longer contains the dialog region.
    func testDialogSurvivesIntoTheDeltaEvenWhenBoundingDropsIt() {
        let body = (0..<40).map { Block(type: .paragraph, text: "paragraph \($0) " + String(repeating: "b", count: 120)) }
        let previous = page([Region(kind: .main, blocks: body)])
        let incoming = page([
            Region(kind: .main, blocks: body),
            Region(kind: .dialog, blocks: [Block(type: .label, text: "Discard changes?")]),
        ])
        // A cap far below the page's rendered size, so `bound` sheds the dialog region entirely.
        let result = CaptureAccumulator.merge(previous: previous, incoming: incoming,
                                              policy: .replace, maxCharacters: 300)
        guard case .generic(let stored) = result.content else { return XCTFail("expected generic") }
        XCTAssertFalse(stored.regions.contains { $0.kind == .dialog },
                       "bounding dropped the dialog region from the STORED content")
        XCTAssertEqual(result.delta.dialogBlocks.map(\.text), ["Discard changes?"],
                       "but the delta still reports it")
    }

    func testRoundTripsThroughDeterministicEncoder() throws {
        let delta = CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "x")],
                                addedChars: 1, isFirstCapture: true,
                                dialogBlocks: [Block(type: .label, text: "OK")])
        let encoder = CapturedContentEnvelope.makeEncoder()
        let first = try encoder.encode(delta)
        let decoded = try CapturedContentEnvelope.makeDecoder().decode(CaptureDelta.self, from: first)
        XCTAssertEqual(decoded, delta)
        XCTAssertEqual(try encoder.encode(decoded), first)
    }
}
