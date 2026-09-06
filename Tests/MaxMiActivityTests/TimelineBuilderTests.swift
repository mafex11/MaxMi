import XCTest
@testable import MaxMiActivity
import MaxMiCore

/// Deterministic stub. Not an actor: `TimelineRepository` is synchronous and throwing, matching
/// the store reads it adapts.
struct StubTimelineRepository: TimelineRepository {
    var visits: [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)] = []
    var events: [TimelineRawEvent] = []
    var metadata: [String: TimelineThreadMeta] = [:]

    func appVisits(fromMs: EpochMs, toMs: EpochMs)
        throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)] {
        visits
    }
    func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [TimelineRawEvent] { events }
    func threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta] {
        metadata.filter { threadIDs.contains($0.key) }
    }
}

final class TimelineBuilderTests: XCTestCase {
    /// 2026-09-07 09:00:00 UTC. Every `render` assertion below compares against times formatted
    /// in the CURRENT time zone, computed the same way the renderer does, so the test is
    /// timezone-independent.
    private let t0 = EpochMs(1_788_512_400_000)

    private func hhmm(_ ms: EpochMs) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func deltaEvent(atMs: EpochMs, threadID: String?, delta: CaptureDelta) -> TimelineRawEvent {
        TimelineRawEvent(kind: .contentDelta, atMs: atMs, threadID: threadID, trigger: .periodic,
                         delta: delta, typing: nil, toURL: nil)
    }

    private func typingEvent(atMs: EpochMs, threadID: String?, text: String) -> TimelineRawEvent {
        TimelineRawEvent(
            kind: .typing, atMs: atMs, threadID: threadID, trigger: .accessibilityChanged,
            delta: nil,
            typing: TypingEvent(insertedText: text, fieldRole: "AXTextArea",
                                fieldIdentifier: "composer", totalLength: text.count,
                                replaced: false),
            toURL: nil)
    }

    private func message(_ sender: String, _ text: String) -> Message {
        Message(id: Message.makeID(sender: sender, timeString: "09:20", text: text),
                sender: sender, text: text, timestamp: nil, timeString: "09:20",
                isUser: false, isDraft: false)
    }

    // MARK: - build

    func testVisitWithoutEventsIsStillAnEntry() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "com.example.reader", appLabel: "Reader",
             startedAt: t0, endedAt: t0 + 60_000),
        ])
        let timeline = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000)
        XCTAssertEqual(timeline.fromMs, t0)
        XCTAssertEqual(timeline.toMs, t0 + 600_000)
        XCTAssertEqual(timeline.entries.count, 1)
        let entry = try XCTUnwrap(timeline.entries.first)
        XCTAssertEqual(entry.appLabel, "Reader")
        XCTAssertNil(entry.threadID)
        XCTAssertEqual(entry.kind, .generic)
        XCTAssertEqual(entry.newItemCount, 0)
        XCTAssertNil(entry.deltaSummary)
    }

    func testOpenVisitEndsAtTheWindowEnd() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "com.example.reader", appLabel: "Reader", startedAt: t0, endedAt: nil),
        ])
        let timeline = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000)
        XCTAssertEqual(timeline.entries.first?.endMs, t0 + 600_000)
    }

    func testEntriesAreChronologicalRegardlessOfRepositoryOrder() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "c", appLabel: "Third", startedAt: t0 + 200_000, endedAt: t0 + 300_000),
            (bundleID: "a", appLabel: "First", startedAt: t0, endedAt: t0 + 100_000),
            (bundleID: "b", appLabel: "Second", startedAt: t0 + 100_000, endedAt: t0 + 200_000),
        ])
        let timeline = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000)
        XCTAssertEqual(timeline.entries.map(\.appLabel), ["First", "Second", "Third"])
    }

    func testEventsAttachToTheVisitContainingThem() throws {
        let repo = StubTimelineRepository(
            visits: [
                (bundleID: "a", appLabel: "First", startedAt: t0, endedAt: t0 + 100_000),
                (bundleID: "b", appLabel: "Second", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
            ],
            events: [
                deltaEvent(atMs: t0 + 50_000, threadID: "t1",
                           delta: CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "one")],
                                               addedChars: 3)),
                deltaEvent(atMs: t0 + 150_000, threadID: "t2",
                           delta: CaptureDelta(addedMessages: [message("Ana", "hello")],
                                               addedChars: 5)),
            ],
            metadata: [
                "t1": TimelineThreadMeta(sourceApp: "Reader", sourceTitle: "A doc",
                                         kind: .document, url: nil, cwd: nil),
                "t2": TimelineThreadMeta(sourceApp: "Chat", sourceTitle: "#invented",
                                         kind: .conversation, url: nil, cwd: nil),
            ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.map(\.threadID), ["t1", "t2"])
        XCTAssertEqual(entries.map(\.kind), [.document, .conversation])
        XCTAssertEqual(entries.map(\.sourceTitle), ["A doc", "#invented"])
        XCTAssertEqual(entries.map(\.newItemCount), [1, 1])
    }

    func testEventsOutsideEveryVisitAreDropped() throws {
        let repo = StubTimelineRepository(
            visits: [(bundleID: "a", appLabel: "First", startedAt: t0, endedAt: t0 + 10_000)],
            events: [deltaEvent(atMs: t0 + 500_000, threadID: "t1",
                                delta: CaptureDelta(addedChars: 9))])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.threadID)
    }

    func testAdjacentSameThreadVisitsCoalesce() throws {
        let repo = StubTimelineRepository(
            visits: [
                (bundleID: "a", appLabel: "Editor", startedAt: t0, endedAt: t0 + 100_000),
                (bundleID: "a", appLabel: "Editor", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
            ],
            events: [
                deltaEvent(atMs: t0 + 50_000, threadID: "t1",
                           delta: CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "one")],
                                               addedChars: 3)),
                typingEvent(atMs: t0 + 60_000, threadID: "t1", text: "abc"),
                deltaEvent(atMs: t0 + 150_000, threadID: "t1",
                           delta: CaptureDelta(addedBlocks: [Block(type: .paragraph, text: "two")],
                                               addedChars: 3)),
                typingEvent(atMs: t0 + 160_000, threadID: "t1", text: "def"),
            ],
            metadata: ["t1": TimelineThreadMeta(sourceApp: "Editor", sourceTitle: "Draft",
                                                kind: .document, url: nil, cwd: nil)])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.startMs, t0)
        XCTAssertEqual(entry.endMs, t0 + 200_000)
        XCTAssertEqual(entry.newItemCount, 2)
        XCTAssertEqual(entry.typedCount, 2)
        XCTAssertEqual(entry.typedSample, "def", "the latest sample wins")
        XCTAssertEqual(entry.deltaSummary, "two", "the latest delta summary wins")
    }

    func testAdjacentThreadlessVisitsOfTheSameAppCoalesce() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "a", appLabel: "Reader", startedAt: t0, endedAt: t0 + 100_000),
            (bundleID: "a", appLabel: "Reader", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
        ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.endMs, t0 + 200_000)
    }

    /// Spec 5d coalesces threadless entries by BUNDLE ID, not by display name. Two bundles that
    /// present the same name — a release and a beta channel, two Electron builds of one product —
    /// are two apps, and merging them would invent a stretch of activity that never happened.
    func testThreadlessVisitsOfDifferentBundlesWithTheSameLabelDoNotCoalesce() throws {
        let repo = StubTimelineRepository(visits: [
            (bundleID: "com.example.browser", appLabel: "Browser",
             startedAt: t0, endedAt: t0 + 100_000),
            (bundleID: "com.example.browser.beta", appLabel: "Browser",
             startedAt: t0 + 100_001, endedAt: t0 + 200_000),
        ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.count, 2, "one display name, two bundles, two entries")
        XCTAssertEqual(entries.map(\.startMs), [t0, t0 + 100_001])
    }

    func testDifferentThreadsInTheSameAppDoNotCoalesce() throws {
        let repo = StubTimelineRepository(
            visits: [
                (bundleID: "a", appLabel: "Chat", startedAt: t0, endedAt: t0 + 100_000),
                (bundleID: "a", appLabel: "Chat", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
            ],
            events: [
                deltaEvent(atMs: t0 + 50_000, threadID: "t1", delta: CaptureDelta(addedChars: 1)),
                deltaEvent(atMs: t0 + 150_000, threadID: "t2", delta: CaptureDelta(addedChars: 1)),
            ],
            metadata: [
                "t1": TimelineThreadMeta(sourceApp: "Chat", sourceTitle: "#one",
                                         kind: .conversation, url: nil, cwd: nil),
                "t2": TimelineThreadMeta(sourceApp: "Chat", sourceTitle: "#two",
                                         kind: .conversation, url: nil, cwd: nil),
            ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.map(\.threadID), ["t1", "t2"])
    }

    func testDeltaSummaryIsCappedAtTwoHundredCharactersAndSingleLine() throws {
        let long = (0..<20).map { Block(type: .paragraph, text: "paragraph number \($0) of a long addition") }
        let repo = StubTimelineRepository(
            visits: [(bundleID: "a", appLabel: "Editor", startedAt: t0, endedAt: t0 + 100_000)],
            events: [deltaEvent(atMs: t0 + 10_000, threadID: "t1",
                                delta: CaptureDelta(addedBlocks: long, addedChars: 900))],
            metadata: ["t1": TimelineThreadMeta(sourceApp: "Editor", sourceTitle: "Draft",
                                                kind: .document, url: nil, cwd: nil)])
        let summary = try XCTUnwrap(
            TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries.first?.deltaSummary)
        XCTAssertLessThanOrEqual(summary.count, TimelineBuilder.deltaSummaryCap)
        XCTAssertFalse(summary.contains("\n"), "a timeline line is one line")
        XCTAssertEqual(summary.prefix(9), "paragraph")
    }

    func testTypedSampleIsCappedAtOneHundredAndTwentyCharacters() throws {
        let repo = StubTimelineRepository(
            visits: [(bundleID: "a", appLabel: "Chat", startedAt: t0, endedAt: t0 + 100_000)],
            events: [typingEvent(atMs: t0 + 10_000, threadID: nil,
                                 text: String(repeating: "t", count: 400))])
        let sample = try XCTUnwrap(
            TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries.first?.typedSample)
        XCTAssertEqual(sample.count, TimelineBuilder.typedSampleCap)
    }

    func testTerminalAndConversationDeltasCountTheirOwnShapes() throws {
        let repo = StubTimelineRepository(
            visits: [
                (bundleID: "a", appLabel: "Terminal", startedAt: t0, endedAt: t0 + 100_000),
                (bundleID: "b", appLabel: "Chat", startedAt: t0 + 100_001, endedAt: t0 + 200_000),
            ],
            events: [
                deltaEvent(atMs: t0 + 10_000, threadID: "t1", delta: CaptureDelta(
                    addedSegments: [
                        TerminalSegment(command: "swift test", output: "2 failures", isRunning: false),
                        TerminalSegment(command: "git status", output: "clean", isRunning: false),
                    ], addedChars: 40)),
                deltaEvent(atMs: t0 + 110_000, threadID: "t2", delta: CaptureDelta(
                    addedMessages: [message("Ana", "one"), message("Bo", "two")], addedChars: 6)),
            ],
            metadata: [
                "t1": TimelineThreadMeta(sourceApp: "Terminal", sourceTitle: "shell",
                                         kind: .terminal, url: nil, cwd: "~/code/project"),
                "t2": TimelineThreadMeta(sourceApp: "Chat", sourceTitle: "#invented",
                                         kind: .conversation, url: nil, cwd: nil),
            ])
        let entries = try TimelineBuilder(repo: repo).build(fromMs: t0, toMs: t0 + 600_000).entries
        XCTAssertEqual(entries.map(\.newItemCount), [2, 2])
        XCTAssertEqual(entries.first?.cwd, "~/code/project")
    }

    // MARK: - render

    func testRenderedTerminalLineNamesTheKindAndCwd() throws {
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 600_000, appLabel: "Terminal", threadID: "t1",
            sourceTitle: "shell", url: nil, kind: .terminal, cwd: "~/code/project",
            deltaSummary: "ran swift test", newItemCount: 3, typedCount: 3, typedSample: nil)
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 600_000, entries: [entry]),
            budgetChars: 4_000)
        XCTAssertEqual(
            text,
            "\(hhmm(t0))–\(hhmm(t0 + 600_000)) Terminal (terminal ~/code/project): "
                + "ran swift test; new since last: 3 segments; typed 3 edits")
    }

    func testRenderedWebLineQuotesTheTitleAndTruncatesTheURL() throws {
        let url = "https://example.invalid/" + String(repeating: "p", count: 120)
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 60_000, appLabel: "Browser", threadID: "t1",
            sourceTitle: "An invented page", url: url, kind: .webpage, cwd: nil,
            deltaSummary: nil, newItemCount: 4, typedCount: 0, typedSample: nil)
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [entry]), budgetChars: 4_000)
        XCTAssertTrue(text.contains("Browser \"An invented page\" ("), text)
        XCTAssertTrue(text.contains("new since last: 4 paragraphs"), text)
        XCTAssertFalse(text.contains(url), "the full url must be truncated")
        XCTAssertTrue(text.contains(String(url.prefix(TimelineBuilder.urlCap))), text)
    }

    func testRenderedConversationLineQuotesTheTypedSample() throws {
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 60_000, appLabel: "Chat", threadID: "t1",
            sourceTitle: "#invented", url: nil, kind: .conversation, cwd: nil,
            deltaSummary: "2 new lines", newItemCount: 2, typedCount: 1,
            typedSample: "shipping today")
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [entry]), budgetChars: 4_000)
        XCTAssertTrue(text.hasSuffix("new since last: 2 msgs; typed 1 edits \"shipping today\""), text)
    }

    func testEntryWithNoFactsRendersOnlyItsHead() {
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 60_000, appLabel: "Reader", threadID: nil,
            sourceTitle: nil, url: nil, kind: .generic, cwd: nil,
            deltaSummary: nil, newItemCount: 0, typedCount: 0, typedSample: nil)
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [entry]), budgetChars: 4_000)
        XCTAssertEqual(text, "\(hhmm(t0))–\(hhmm(t0 + 60_000)) Reader")
    }

    func testRenderIsChronologicalOneLinePerEntry() {
        let entries = (0..<3).map { index in
            TimelineEntry(startMs: t0 + EpochMs(index) * 60_000,
                          endMs: t0 + EpochMs(index + 1) * 60_000,
                          appLabel: "App\(index)", threadID: nil, sourceTitle: nil, url: nil,
                          kind: .generic, cwd: nil, deltaSummary: nil, newItemCount: 0,
                          typedCount: 0, typedSample: nil)
        }
        let lines = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 600_000, entries: entries),
            budgetChars: 4_000).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("App0"))
        XCTAssertTrue(lines[2].hasSuffix("App2"))
    }

    func testBudgetDropsOldestFirstAndAddsTheOmissionLine() {
        let entries = (0..<10).map { index in
            TimelineEntry(startMs: t0 + EpochMs(index) * 60_000,
                          endMs: t0 + EpochMs(index + 1) * 60_000,
                          appLabel: "App\(index)", threadID: nil, sourceTitle: nil, url: nil,
                          kind: .generic, cwd: nil,
                          deltaSummary: String(repeating: "s", count: 60), newItemCount: 0,
                          typedCount: 0, typedSample: nil)
        }
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 600_000, entries: entries), budgetChars: 300)
        XCTAssertTrue(text.hasPrefix(TimelineBuilder.omissionLine + "\n"), text)
        XCTAssertLessThanOrEqual(text.count, 300)
        XCTAssertFalse(text.contains("App0"), "the oldest entry is dropped first")
        XCTAssertTrue(text.contains("App9"), "the newest entry always survives")
    }

    func testBudgetNeverDropsTheLastEntry() {
        let entry = TimelineEntry(
            startMs: t0, endMs: t0 + 60_000, appLabel: "Reader", threadID: nil,
            sourceTitle: nil, url: nil, kind: .generic, cwd: nil,
            deltaSummary: String(repeating: "s", count: 900), newItemCount: 0,
            typedCount: 0, typedSample: nil)
        let text = TimelineBuilder.render(
            ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [entry]), budgetChars: 10)
        XCTAssertTrue(text.contains("Reader"), "an over-budget single entry is still reported")
    }

    func testEmptyTimelineRendersEmpty() {
        XCTAssertEqual(
            TimelineBuilder.render(ActivityTimeline(fromMs: t0, toMs: t0 + 1, entries: []),
                                   budgetChars: 4_000),
            "")
    }

    func testTimelineIsCodableRoundTrippable() throws {
        let timeline = ActivityTimeline(fromMs: t0, toMs: t0 + 60_000, entries: [
            TimelineEntry(startMs: t0, endMs: t0 + 60_000, appLabel: "Chat", threadID: "t1",
                          sourceTitle: "#invented", url: nil, kind: .conversation, cwd: nil,
                          deltaSummary: "two lines", newItemCount: 2, typedCount: 1,
                          typedSample: "hi"),
        ])
        let data = try CapturedContentEnvelope.makeEncoder().encode(timeline)
        XCTAssertEqual(
            try CapturedContentEnvelope.makeDecoder().decode(ActivityTimeline.self, from: data),
            timeline)
    }
}
