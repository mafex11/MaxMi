import XCTest
@testable import MaxMiUI

@MainActor
final class MeetingHistoryViewModelTests: XCTestCase {
    func testMapsMeetingAndVoiceNoteHistory() async {
        let now: Int64 = 2_000_000
        let viewModel = MeetingHistoryViewModel(
            load: {
                [
                    MeetingHistoryDTO(
                        id: "voice", appLabel: "Voice Note", title: "Idea",
                        startedAtMs: now - 65_000, endedAtMs: now - 5_000,
                        captureMode: "voice-note-mic", transcriptionStatus: "complete"
                    ),
                    MeetingHistoryDTO(
                        id: "meeting", appLabel: "Zoom", title: "Standup",
                        startedAtMs: now - 3_600_000, endedAtMs: now - 3_300_000,
                        captureMode: "system+mic", transcriptionStatus: "partial"
                    ),
                ]
            },
            now: { now }
        )
        await viewModel.refresh()
        XCTAssertEqual(viewModel.rows.count, 2)
        XCTAssertTrue(viewModel.rows[0].isVoiceNote)
        XCTAssertEqual(viewModel.rows[0].duration, "1m 0s")
        XCTAssertEqual(viewModel.rows[0].timeAgo, "1m ago")
        XCTAssertEqual(viewModel.rows[1].source, "Zoom")
        XCTAssertEqual(viewModel.rows[1].status, "Partial")
    }

    func testEmptyTitleGetsKindFallback() async {
        let viewModel = MeetingHistoryViewModel(
            load: {
                [MeetingHistoryDTO(
                    id: "v", appLabel: "Voice Note", title: nil,
                    startedAtMs: 0, endedAtMs: 1_000,
                    captureMode: "voice-note-mic", transcriptionStatus: "complete"
                )]
            },
            now: { 1_000 }
        )
        await viewModel.refresh()
        XCTAssertEqual(viewModel.rows.first?.title, "Voice note")
    }
}
