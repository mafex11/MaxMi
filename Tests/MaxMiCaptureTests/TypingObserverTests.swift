import XCTest
@testable import MaxMiCapture
import MaxMiCore

final class TypingObserverTests: XCTestCase {
    private let t0 = EpochMs(1_800_000_000_000)

    private func key(_ bundleID: String = "com.example.chat",
                     windowID: UInt32? = 42,
                     identifier: String? = "composer") -> FocusedFieldKey {
        FocusedFieldKey(bundleID: bundleID, windowID: windowID, windowTitle: nil,
                        role: "AXTextArea", identifier: identifier)
    }

    private func field(_ value: String?, isSecure: Bool = false) -> FocusedElement {
        FocusedElement(role: "AXTextArea", identifier: "composer", value: value,
                       selectedText: nil, isSecure: isSecure)
    }

    private func observer(eligible: Bool = true) -> TypingObserver {
        TypingObserver(isEligible: { _ in eligible })
    }

    // MARK: - TypingDiff

    func testPureAppendIsAnInsertion() throws {
        let change = try XCTUnwrap(TypingDiff.diff(old: "hello", new: "hello world",
                                                   maxReplacedTailChars: 500))
        XCTAssertEqual(change.insertedText, " world")
        XCTAssertFalse(change.replaced)
    }

    func testSingleMidStringInsertionIsAnInsertion() throws {
        let change = try XCTUnwrap(TypingDiff.diff(old: "ship it", new: "ship all of it",
                                                   maxReplacedTailChars: 500))
        XCTAssertEqual(change.insertedText, "all of ")
        XCTAssertFalse(change.replaced)
    }

    func testPasteOverASelectionIsAReplacementCarryingTheTail() throws {
        let old = "draft text"
        let new = String(repeating: "p", count: 900)
        let change = try XCTUnwrap(TypingDiff.diff(old: old, new: new, maxReplacedTailChars: 500))
        XCTAssertTrue(change.replaced)
        XCTAssertEqual(change.insertedText.count, 500)
        XCTAssertEqual(change.insertedText, String(new.suffix(500)))
    }

    func testLongPureInsertionCarriesOnlyTheTail() throws {
        let inserted = String(repeating: "a", count: 1_500) + String(repeating: "b", count: 500)
        let change = try XCTUnwrap(
            TypingDiff.diff(old: "", new: inserted, maxReplacedTailChars: 500)
        )
        XCTAssertEqual(change.insertedText.count, 500)
        XCTAssertEqual(change.insertedText, String(inserted.suffix(500)))
        XCTAssertFalse(change.replaced)
    }

    func testClearingTheFieldIsAReplacementWithAnEmptyTail() throws {
        let change = try XCTUnwrap(TypingDiff.diff(old: "abc", new: "", maxReplacedTailChars: 500))
        XCTAssertTrue(change.replaced)
        XCTAssertEqual(change.insertedText, "")
    }

    func testBackspaceIsAReplacement() throws {
        let change = try XCTUnwrap(TypingDiff.diff(old: "hello", new: "hell",
                                                   maxReplacedTailChars: 500))
        XCTAssertTrue(change.replaced)
        XCTAssertEqual(change.insertedText, "hell")
    }

    func testIdenticalValuesProduceNoChange() {
        XCTAssertNil(TypingDiff.diff(old: "same", new: "same", maxReplacedTailChars: 500))
        XCTAssertNil(TypingDiff.diff(old: "", new: "", maxReplacedTailChars: 500))
    }

    func testRepeatedCharactersDoNotOverlapPrefixAndSuffix() throws {
        // Naive prefix+suffix counting would claim 3+3 of a 4-character string.
        let change = try XCTUnwrap(TypingDiff.diff(old: "aaa", new: "aaaa",
                                                   maxReplacedTailChars: 500))
        XCTAssertEqual(change.insertedText, "a")
        XCTAssertFalse(change.replaced)
    }

    // MARK: - TypingObserver

    func testFirstSightingEstablishesTheBaselineAndEmitsNothing() async {
        let observer = observer()
        let result = await observer.observe(field("hello"), key: key(), nowMs: t0)
        XCTAssertNil(result)
    }

    func testSecondSightingEmitsTheInsertion() async throws {
        let observer = observer()
        _ = await observer.observe(field("hello"), key: key(), nowMs: t0)
        let result = await observer.observe(field("hello world"), key: key(), nowMs: t0 + 1_000)
        let event = try XCTUnwrap(result)
        XCTAssertEqual(event.insertedText, " world")
        XCTAssertEqual(event.fieldRole, "AXTextArea")
        XCTAssertEqual(event.fieldIdentifier, "composer")
        XCTAssertEqual(event.totalLength, 11)
        XCTAssertFalse(event.replaced)
    }

    func testIdenticalValueEmitsNothing() async {
        let observer = observer()
        _ = await observer.observe(field("hello"), key: key(), nowMs: t0)
        let result = await observer.observe(field("hello"), key: key(), nowMs: t0 + 1_000)
        XCTAssertNil(result)
    }

    func testDebounceSuppressesASecondEventInsideTheWindow() async {
        let observer = observer()
        _ = await observer.observe(field("a"), key: key(), nowMs: t0)
        let firstEvent = await observer.observe(field("ab"), key: key(), nowMs: t0 + 1_000)
        XCTAssertNotNil(firstEvent)
        let suppressedEvent = await observer.observe(field("abc"), key: key(), nowMs: t0 + 1_100)
        XCTAssertNil(suppressedEvent)
    }

    /// The suppressed characters are not lost: the baseline is not advanced inside the window, so
    /// the next accepted call reports the whole burst.
    func testSuppressedCharactersAppearInTheNextAcceptedEvent() async throws {
        let observer = observer()
        _ = await observer.observe(field("a"), key: key(), nowMs: t0)
        _ = await observer.observe(field("ab"), key: key(), nowMs: t0 + 1_000)
        _ = await observer.observe(field("abc"), key: key(), nowMs: t0 + 1_100)
        let result = await observer.observe(field("abcd"), key: key(), nowMs: t0 + 2_000)
        let event = try XCTUnwrap(result)
        XCTAssertEqual(event.insertedText, "cd")
    }

    func testDebounceIsPerKey() async {
        let observer = observer()
        let other = key(windowID: 43)
        _ = await observer.observe(field("a"), key: key(), nowMs: t0)
        _ = await observer.observe(field("a"), key: other, nowMs: t0)
        let firstEvent = await observer.observe(field("ab"), key: key(), nowMs: t0 + 1_000)
        XCTAssertNotNil(firstEvent)
        let secondEvent = await observer.observe(field("ab"), key: other, nowMs: t0 + 1_010)
        XCTAssertNotNil(secondEvent)
    }

    func testSecureFieldNeverEmits() async {
        let observer = observer()
        _ = await observer.observe(field("hunter", isSecure: true), key: key(), nowMs: t0)
        let result = await observer.observe(field("hunter2", isSecure: true), key: key(),
                                            nowMs: t0 + 1_000)
        XCTAssertNil(result)
    }

    func testSensitiveAppNeverEmits() async {
        let observer = observer()
        let sensitive = key("com.apple.systempreferences")
        _ = await observer.observe(field("a"), key: sensitive, nowMs: t0)
        let result = await observer.observe(field("ab"), key: sensitive, nowMs: t0 + 1_000)
        XCTAssertNil(result)
    }

    /// Consent and per-app exclusion reach the observer as the injected predicate: `AppWiring`
    /// composes them in `isActivityEligible`.
    func testIneligibleAppNeverEmits() async {
        let observer = observer(eligible: false)
        _ = await observer.observe(field("a"), key: key(), nowMs: t0)
        let result = await observer.observe(field("ab"), key: key(), nowMs: t0 + 1_000)
        XCTAssertNil(result)
    }

    func testPersistenceDecisionDropsObservedEventWhenConsentIsRevokedAfterAwait() async throws {
        let observer = observer()
        var consentGranted = true
        _ = await observer.observe(field("a"), key: key(), nowMs: t0)
        let result = await observer.observe(field("ab"), key: key(), nowMs: t0 + 1_000)
        let observed = try XCTUnwrap(result)
        XCTAssertTrue(consentGranted)
        consentGranted = false

        let persisted = TypingEventPersistenceDecision.eventToPersist(
            observed,
            isActivityEligible: consentGranted,
            isObserverActive: true,
            isCaptureLifecycleActive: true
        )

        XCTAssertNil(persisted)
    }

    func testLRUEvictsBeyondThirtyTwoFields() async {
        let observer = observer()
        for index in 0..<(TypingObserver.maxTrackedFields + 8) {
            _ = await observer.observe(field("v\(index)"), key: key(windowID: UInt32(index)),
                                      nowMs: t0 + EpochMs(index))
        }
        let trackedFieldCount = await observer.trackedFieldCount
        XCTAssertEqual(trackedFieldCount, TypingObserver.maxTrackedFields)
        // The oldest key was evicted, so it is a first sighting again.
        let result = await observer.observe(field("v0 changed"), key: key(windowID: 0),
                                            nowMs: t0 + 10_000)
        XCTAssertNil(result)
    }

    // MARK: - Key identity

    /// One window discriminator, not two fields: the id when the app exposes one, otherwise the
    /// title. An id and a title for the same window therefore collapse to the same key.
    func testWindowIDWinsOverTheTitle() {
        let withTitle = FocusedFieldKey(bundleID: "b", windowID: 7, windowTitle: "Draft",
                                        role: "AXTextArea", identifier: nil)
        let withoutTitle = FocusedFieldKey(bundleID: "b", windowID: 7, windowTitle: nil,
                                           role: "AXTextArea", identifier: nil)
        XCTAssertEqual(withTitle, withoutTitle)
        XCTAssertEqual(withTitle.window, "id:7")
    }

    func testWindowTitleDistinguishesKeysWhenNoWindowIDIsKnown() {
        let a = FocusedFieldKey(bundleID: "b", windowID: nil, windowTitle: "One",
                                role: "AXTextArea", identifier: nil)
        let b = FocusedFieldKey(bundleID: "b", windowID: nil, windowTitle: "Two",
                                role: "AXTextArea", identifier: nil)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.window, "title:One")
    }

    /// The bug this shape exists to prevent. `AXReader.focusedWindowID(pid:)` returns nil for any
    /// app whose focused window exposes no `CGWindowID`. The capture path passes a real window
    /// title; if the AX-notification path passed nil, the two paths would mint DIFFERENT keys for
    /// the same field, every notification would be a first sighting, and no typing event would
    /// ever be emitted for that app. Both paths pass the same `(windowID, windowTitle)` pair, so
    /// the keys agree — and the last assertion shows the failure mode is loud, not silent.
    func testBothWritePathsMintTheSameKeyWhenNoWindowIDIsAvailable() {
        let captureSide = FocusedFieldKey(
            app: AppInfo(bundleID: "com.example.chat", name: "Chat", windowTitle: "General",
                         windowID: nil),
            focused: field("x"))
        let pollSide = FocusedFieldKey(bundleID: "com.example.chat", windowID: nil,
                                       windowTitle: "General", role: "AXTextArea",
                                       identifier: "composer")
        XCTAssertEqual(captureSide, pollSide)
        XCTAssertEqual(captureSide.window, "title:General")
        XCTAssertNotEqual(
            captureSide,
            FocusedFieldKey(bundleID: "com.example.chat", windowID: nil, windowTitle: nil,
                            role: "AXTextArea", identifier: "composer"),
            "a poll path that forgot the title must not silently agree")
    }

    func testTypingThreadAttributionFallsBackAcrossFieldsInTheSameWindow() {
        let composerField = key(identifier: "composer")
        let searchField = key(identifier: "search")
        XCTAssertNotEqual(composerField, searchField)
        let composer = TypingThreadKey(fieldKey: composerField)
        let search = TypingThreadKey(fieldKey: searchField)
        XCTAssertEqual(composer, search)
        let remembered = [composer: "thread-general"]

        XCTAssertEqual(
            TypingThreadAttribution.resolve(
                explicitThreadID: nil,
                rememberedThreadIDs: remembered,
                for: search
            ),
            "thread-general"
        )
    }

    // MARK: - TypingPollGate

    func testPollGateAdmitsTheFirstNotificationForAKey() {
        var gate = TypingPollGate()
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0), .read)
    }

    /// Progress bars, clocks and live regions all fire `kAXValueChangedNotification`, so a burst
    /// is the normal case. It must cost ONE AX read, taken at the end.
    func testPollGateCoalescesABurstIntoOneTrailingRead() {
        var gate = TypingPollGate()
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0), .read)
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0 + 100),
                       .schedule(afterMs: TypingPollGate.intervalMs - 100))
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0 + 200), .alreadyScheduled)
        XCTAssertEqual(gate.admit(key: "com.example.chat", nowMs: t0 + 700), .alreadyScheduled)

        gate.completeScheduled(key: "com.example.chat", nowMs: t0 + TypingPollGate.intervalMs)
        XCTAssertEqual(
            gate.admit(key: "com.example.chat", nowMs: t0 + TypingPollGate.intervalMs + 1),
            .schedule(afterMs: TypingPollGate.intervalMs - 1),
            "the trailing read reset the window, so the next burst schedules again")
    }

    func testPollGateIsPerKeyAndReopensAfterTheInterval() {
        var gate = TypingPollGate()
        XCTAssertEqual(gate.admit(key: "a", nowMs: t0), .read)
        XCTAssertEqual(gate.admit(key: "b", nowMs: t0), .read, "a different app is not gated")
        XCTAssertEqual(gate.admit(key: "a", nowMs: t0 + TypingPollGate.intervalMs), .read)
    }

    func testPollGateForgetsKeysItHasNotSeenRecently() {
        var gate = TypingPollGate()
        XCTAssertEqual(gate.admit(key: "a", nowMs: t0), .read)
        XCTAssertEqual(gate.admit(key: "b", nowMs: t0 + TypingPollGate.staleAfterMs + 1), .read)
        XCTAssertEqual(gate.trackedKeyCount, 1, "the stale key is forgotten, so the map is bounded")
    }

    func testPollGateForgetsAnAbandonedScheduledRead() {
        var gate = TypingPollGate()
        XCTAssertEqual(gate.admit(key: "a", nowMs: t0), .read)
        XCTAssertEqual(gate.admit(key: "a", nowMs: t0 + 1),
                       .schedule(afterMs: TypingPollGate.intervalMs - 1))

        XCTAssertEqual(gate.admit(key: "b", nowMs: t0 + TypingPollGate.staleAfterMs + 1), .read)
        XCTAssertEqual(gate.trackedKeyCount, 1, "cleanup must remove all state for stale key a")

        XCTAssertEqual(gate.admit(key: "a", nowMs: t0 + TypingPollGate.staleAfterMs + 1), .read)
        XCTAssertEqual(gate.admit(key: "a", nowMs: t0 + TypingPollGate.staleAfterMs + 2),
                       .schedule(afterMs: TypingPollGate.intervalMs - 1),
                       "cleanup must also remove a stale pending trailing read")
    }

    func testKeyFromAppInfoAndFocusedElement() {
        let app = AppInfo(bundleID: "com.example.chat", name: "Chat", windowTitle: "General",
                          windowID: 9)
        let built = FocusedFieldKey(app: app, focused: field("x"))
        XCTAssertEqual(built, FocusedFieldKey(bundleID: "com.example.chat", windowID: 9,
                                              windowTitle: nil, role: "AXTextArea",
                                              identifier: "composer"))
    }

    func testFocusedElementFromAXNodeMasksASecureField() {
        let secure = AXNode(role: "AXTextField", value: nil, title: nil, url: nil, frame: nil,
                            focused: true, children: [], identifier: "password",
                            subrole: "AXSecureTextField")
        let element = FocusedElement(node: secure)
        XCTAssertTrue(element.isSecure)
        XCTAssertNil(element.value)
        XCTAssertNil(element.selectedText)

        let plain = AXNode(role: "AXTextArea", value: "hello", title: nil, url: nil, frame: nil,
                           focused: true, children: [], identifier: "composer",
                           selectedText: "he")
        let plainElement = FocusedElement(node: plain)
        XCTAssertFalse(plainElement.isSecure)
        XCTAssertEqual(plainElement.value, "hello")
        XCTAssertEqual(plainElement.selectedText, "he")
    }

    // MARK: - Exit criterion 5

    /// Spec 11 criterion 5, grep-asserted: typing must never come from an event tap.
    func testNoEventTapAnywhereInSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let banned = ["CGEvent.tapCreate", "CGEventTapCreate", "addGlobalMonitorForEvents",
                      "IOHIDManager"]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "no Swift sources found under \(root.path)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in banned {
                XCTAssertFalse(text.contains(token), "\(token) found in \(file.lastPathComponent)")
            }
        }
    }
}
