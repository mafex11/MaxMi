import Foundation
import MaxMiCore

/// Identity of one text field across captures: bundle id + one window discriminator + role +
/// identifier.
///
/// The window is ONE stored field, not a `windowID`/`windowTitle` pair, because there are two
/// write paths (the capture path and the AX-notification path) and both must arrive at the same
/// key or nothing is ever emitted. `AXReader.focusedWindowID(pid:)` returns nil for any focused
/// window that exposes no `CGWindowID`, so the id alone is not enough and the title alone is not
/// stable — the rule is "the id when there is one, otherwise the title". Both paths therefore pass
/// the SAME `(windowID, windowTitle)` pair and let this initializer decide; neither path is allowed
/// to pass `windowTitle: nil` as a shortcut.
public struct FocusedFieldKey: Hashable, Sendable {
    public let bundleID: String
    /// `"id:<CGWindowID>"`, else `"title:<window title>"`, else nil. Prefixed so an app that names
    /// a window `"7"` cannot collide with window id 7.
    public let window: String?
    public let role: String
    public let identifier: String?

    public init(bundleID: String, windowID: UInt32?, windowTitle: String?,
                role: String, identifier: String?) {
        self.bundleID = bundleID
        if let windowID {
            self.window = "id:\(windowID)"
        } else if let windowTitle, !windowTitle.isEmpty {
            self.window = "title:\(windowTitle)"
        } else {
            self.window = nil
        }
        self.role = role
        self.identifier = identifier
    }

    /// `AppInfo` carries both inputs — `AppWiring` builds it with the AXReader window title and
    /// `AXReader.focusedWindowID(pid:)` — so the capture path has nothing to resolve itself.
    public init(app: AppInfo, focused: FocusedElement) {
        self.init(bundleID: app.bundleID, windowID: app.windowID, windowTitle: app.windowTitle,
                  role: focused.role, identifier: focused.identifier)
    }
}

/// Thread attribution identity for typing: the app and focused window, deliberately excluding the
/// focused field's role and identifier. A capture establishes the current thread for its window;
/// later value notifications may come from a different field in that same window.
public struct TypingThreadKey: Hashable, Sendable {
    public let bundleID: String
    public let window: String?

    public init(fieldKey: FocusedFieldKey) {
        bundleID = fieldKey.bundleID
        window = fieldKey.window
    }
}

/// Resolves a typing event's thread without coupling the executable's LRU storage to field
/// identity. The capture's direct attribution wins; notification-only events use the most recent
/// capture for the same app window.
public enum TypingThreadAttribution {
    public static func resolve(
        explicitThreadID: String?,
        rememberedThreadIDs: [TypingThreadKey: String],
        for key: TypingThreadKey
    ) -> String? {
        explicitThreadID ?? rememberedThreadIDs[key]
    }
}

/// Final write gate for a typing event after `TypingObserver.observe` resumes. The eligibility
/// state may have changed while the actor was suspended, so an observed event is not persistable
/// unless the activity gate and capture lifecycle are still active.
public enum TypingEventPersistenceDecision {
    public static func eventToPersist(
        _ event: TypingEvent,
        isActivityEligible: Bool,
        isObserverActive: Bool,
        isCaptureLifecycleActive: Bool
    ) -> TypingEvent? {
        guard isActivityEligible, isObserverActive, isCaptureLifecycleActive else { return nil }
        return event
    }
}

/// Pre-read time gate for `kAXValueChangedNotification`, keyed per app.
///
/// `FocusObserver.onAXNotification` fires for EVERY notification the app-level `AXObserver`
/// delivers, and it fires *ahead of* `FocusObserver`'s own capture debounce. Progress bars, clocks
/// and live regions all emit value changes. Without this gate each one would run a full
/// `AXReader.focusedElementSnapshot(pid:)` on the main actor — an `AXManualAccessibility` write, a
/// `kAXFocusedUIElementAttribute` read and up to 64 node conversions, several AX round trips each.
/// `TypingObserver.debounceMs` cannot help: it suppresses the emitted EVENT, and the read has
/// already happened by then.
///
/// A value type driven entirely by an injected `nowMs`, so every branch is a unit test with no
/// clock and no sleeping. `AppWiring` owns one on the main actor.
public struct TypingPollGate: Sendable {
    /// The same 800 ms as the emit debounce: a read that could not produce an event is wasted work.
    public static let intervalMs: EpochMs = TypingObserver.debounceMs
    /// A key unseen for this long is forgotten, so the map is bounded by *recently* active apps
    /// rather than by every app ever focused.
    public static let staleAfterMs: EpochMs = 60_000

    public enum Decision: Equatable, Sendable {
        /// Read now.
        case read
        /// Too soon. Read once after this delay — the burst is coalesced into a single TRAILING
        /// read, so the last value of the burst is still seen rather than dropped.
        case schedule(afterMs: EpochMs)
        /// Too soon, and a trailing read for this key is already pending. Do nothing.
        case alreadyScheduled
    }

    private var lastReadAtMs: [String: EpochMs] = [:]
    private var pending: Set<String> = []

    public init() {}

    public var trackedKeyCount: Int { lastReadAtMs.count }

    public mutating func admit(key: String, nowMs: EpochMs) -> Decision {
        lastReadAtMs = lastReadAtMs.filter { nowMs - $0.value < Self.staleAfterMs }
        pending.formIntersection(Set(lastReadAtMs.keys))
        guard let last = lastReadAtMs[key] else {
            lastReadAtMs[key] = nowMs
            return .read
        }
        let elapsed = nowMs - last
        guard elapsed < Self.intervalMs else {
            lastReadAtMs[key] = nowMs
            pending.remove(key)
            return .read
        }
        guard !pending.contains(key) else { return .alreadyScheduled }
        pending.insert(key)
        return .schedule(afterMs: Self.intervalMs - elapsed)
    }

    /// Called when a scheduled trailing read actually runs, so the window restarts from the read
    /// rather than from the notification that asked for it.
    public mutating func completeScheduled(key: String, nowMs: EpochMs) {
        pending.remove(key)
        lastReadAtMs[key] = nowMs
    }
}

/// The pure diff. No library, no dependency on the actor, so every branch is a unit test.
public enum TypingDiff {
    public struct Change: Sendable, Equatable {
        public let insertedText: String
        public let replaced: Bool

        public init(insertedText: String, replaced: Bool) {
            self.insertedText = insertedText
            self.replaced = replaced
        }
    }

    /// Common-prefix / common-suffix diff, with the suffix capped so prefix + suffix can never
    /// exceed the shorter string (otherwise "aaa" -> "aaaa" would claim six of four characters).
    ///
    /// - a pure insertion (including a plain append, where the common suffix is empty) reports
    ///   the inserted run with `replaced == false`
    /// - anything that also removed characters — paste over a selection, backspace, select-all
    ///   and retype, clear — reports `replaced == true` carrying the new value's trailing
    ///   `maxReplacedTailChars` characters, because there is no single "inserted run" to name
    /// - equal values report nil
    public static func diff(old: String, new: String, maxReplacedTailChars: Int) -> Change? {
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count,
              oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = min(oldChars.count, newChars.count) - prefix
        while suffix < maxSuffix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        let inserted = String(newChars[prefix..<(newChars.count - suffix)])
        let removed = String(oldChars[prefix..<(oldChars.count - suffix)])
        if removed.isEmpty {
            return inserted.isEmpty ? nil : Change(
                insertedText: String(inserted.suffix(max(0, maxReplacedTailChars))),
                replaced: false
            )
        }
        return Change(insertedText: String(newChars.suffix(max(0, maxReplacedTailChars))),
                      replaced: true)
    }
}

/// Tracks the value of focused text fields and reports meaningful changes.
///
/// **No `CGEventTap`. No global event monitor.** The only input is the accessibility value of the
/// focused element, which the caller reads from the capture it already took or from
/// `AXReader.focusedElementSnapshot(pid:)`.
///
/// Nothing is persisted: the LRU is in-actor memory and is gone on quit.
public actor TypingObserver {
    public static let debounceMs: EpochMs = 800
    public static let maxTrackedFields = 32
    public static let maxReplacedTailChars = 500

    struct Tracked {
        var value: String
        var lastEmittedAtMs: EpochMs?
    }

    /// Consent and per-app exclusion, injected because they are `throws` reads on a non-`Sendable`
    /// `Store`: `AppWiring` composes them in `isActivityEligible` and passes the denylist check
    /// here (spec 5c gates, plan Ruling 5).
    private let isEligible: @Sendable (String) -> Bool
    private var tracked: [FocusedFieldKey: Tracked] = [:]
    /// Least-recently-touched first.
    private var order: [FocusedFieldKey] = []

    public init(isEligible: @escaping @Sendable (String) -> Bool) {
        self.isEligible = isEligible
    }

    public var trackedFieldCount: Int { order.count }

    /// An event when the focused field's value changed meaningfully, else nil.
    ///
    /// The FIRST sighting of a field never emits: its current value is a baseline, not something
    /// the user just typed in front of us.
    public func observe(_ focused: FocusedElement, key: FocusedFieldKey,
                        nowMs: EpochMs) -> TypingEvent? {
        // A secure field has no value to diff — Phase A never read it. Checked first so the
        // field is not even tracked.
        guard !focused.isSecure,
              !Denylist.isSensitiveApp(key.bundleID),
              isEligible(key.bundleID) else { return nil }
        let value = focused.value ?? ""
        guard let existing = touch(key, value: value) else { return nil }
        guard existing.value != value else { return nil }
        if let last = existing.lastEmittedAtMs, nowMs - last < Self.debounceMs {
            // Suppressed — and the baseline is deliberately NOT advanced, so the characters typed
            // inside the window are reported by the next accepted call rather than lost.
            return nil
        }
        guard let change = TypingDiff.diff(old: existing.value, new: value,
                                           maxReplacedTailChars: Self.maxReplacedTailChars) else {
            tracked[key]?.value = value
            return nil
        }
        tracked[key] = Tracked(value: value, lastEmittedAtMs: nowMs)
        return TypingEvent(
            insertedText: change.insertedText,
            fieldRole: focused.role,
            fieldIdentifier: focused.identifier,
            totalLength: value.count,
            replaced: change.replaced
        )
    }

    /// Marks `key` most-recently-used and returns its previous state, or nil when this is the
    /// first sighting (whose value becomes the baseline).
    private func touch(_ key: FocusedFieldKey, value: String) -> Tracked? {
        order.removeAll { $0 == key }
        order.append(key)
        if let existing = tracked[key] { return existing }
        tracked[key] = Tracked(value: value, lastEmittedAtMs: nil)
        evictIfNeeded()
        return nil
    }

    private func evictIfNeeded() {
        while order.count > Self.maxTrackedFields {
            let evicted = order.removeFirst()
            tracked[evicted] = nil
        }
    }
}

extension FocusedElement {
    /// The focused `AXNode` as the typed shape. A secure field's `value` and `selectedText` are
    /// already nil in `AXNode` — `AXReader.convert` never reads them — and `FocusedElement.init`
    /// nils them again, so there is no path by which a secret reaches this type.
    public init(node: AXNode) {
        self.init(
            role: node.role,
            identifier: node.identifier,
            value: node.value,
            selectedText: node.selectedText,
            isSecure: node.subrole == GenericPageExtractor.secureSubrole
        )
    }
}
