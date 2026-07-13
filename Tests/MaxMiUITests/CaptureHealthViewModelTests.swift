import XCTest
@testable import MaxMiUI
import MaxMiCore

@MainActor
final class CaptureHealthViewModelTests: XCTestCase {
    func testRefreshSortsAndSummarizesOutcomes() async {
        let now: EpochMs = 2_000_000
        let events = [
            event(id: "old", atMs: now - 120_000, outcome: .captured, characters: 42),
            event(id: "new", atMs: now - 5_000, outcome: .failed, reason: "parserFailed"),
            event(id: "skip", atMs: now - 60_000, outcome: .skipped, reason: "noWindow"),
            event(id: "same", atMs: now - 30_000, outcome: .deduplicated, characters: 42),
        ]
        let vm = CaptureHealthViewModel(load: { events }, now: { now })

        await vm.refresh()

        XCTAssertEqual(vm.rows.map(\.id), ["new", "same", "skip", "old"])
        XCTAssertEqual(vm.summary, CaptureHealthSummary(captured: 1, deduplicated: 1, skipped: 1, failed: 1))
        XCTAssertEqual(vm.rows[0].detail, "Parser failed")
        XCTAssertEqual(vm.rows[0].timeAgo, "5s ago")
    }

    func testSuccessfulRowsExposeOnlyDiagnosticMetadata() async {
        let now: EpochMs = 2_000_000
        let dto = event(id: "one", atMs: now, outcome: .captured, characters: 8_000, truncated: true)
        let vm = CaptureHealthViewModel(load: { [dto] }, now: { now })

        await vm.refresh()

        XCTAssertEqual(vm.rows[0].detail, "8000 characters · truncated")
        XCTAssertEqual(vm.rows[0].parser, "BrowserTabExtractor")
        XCTAssertEqual(vm.rows[0].trigger, "App activated")
    }

    private func event(
        id: String,
        atMs: EpochMs,
        outcome: CaptureOutcomeKind,
        reason: String? = nil,
        characters: Int = 0,
        truncated: Bool = false
    ) -> CaptureHealthDTO {
        CaptureHealthDTO(
            id: id,
            atMs: atMs,
            appLabel: "Safari",
            trigger: .appActivated,
            parser: "BrowserTabExtractor",
            outcome: outcome,
            reason: reason,
            characterCount: characters,
            durationMs: 12,
            truncated: truncated
        )
    }
}
