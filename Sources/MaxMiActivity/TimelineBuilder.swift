import Foundation
import MaxMiCore

/// One coalesced stretch of activity: an app visit plus whatever capture events landed inside it.
public struct TimelineEntry: Codable, Sendable, Equatable {
    public let startMs: EpochMs
    public let endMs: EpochMs
    public let appLabel: String
    public let threadID: String?
    public let sourceTitle: String?
    public let url: String?
    public let kind: CaptureContentKind
    /// Terminal threads only.
    public let cwd: String?
    /// At most `TimelineBuilder.deltaSummaryCap` characters of the added content, rendered and
    /// flattened to one line. Never a full dump.
    public let deltaSummary: String?
    /// `addedMessages + addedBlocks + addedSegments` summed over this entry's content deltas.
    public let newItemCount: Int
    public let typedCount: Int
    /// At most `TimelineBuilder.typedSampleCap` characters from the LAST typing event.
    public let typedSample: String?

    public init(startMs: EpochMs, endMs: EpochMs, appLabel: String, threadID: String?,
                sourceTitle: String?, url: String?, kind: CaptureContentKind, cwd: String?,
                deltaSummary: String?, newItemCount: Int, typedCount: Int, typedSample: String?) {
        self.startMs = startMs
        self.endMs = endMs
        self.appLabel = appLabel
        self.threadID = threadID
        self.sourceTitle = sourceTitle
        self.url = url
        self.kind = kind
        self.cwd = cwd
        self.deltaSummary = deltaSummary
        self.newItemCount = newItemCount
        self.typedCount = typedCount
        self.typedSample = typedSample
    }
}

public struct ActivityTimeline: Codable, Sendable, Equatable {
    public let fromMs: EpochMs
    public let toMs: EpochMs
    public let entries: [TimelineEntry]

    public init(fromMs: EpochMs, toMs: EpochMs, entries: [TimelineEntry]) {
        self.fromMs = fromMs
        self.toMs = toMs
        self.entries = entries.enumerated().sorted {
            if $0.element.startMs != $1.element.startMs {
                return $0.element.startMs < $1.element.startMs
            }
            if $0.element.endMs != $1.element.endMs {
                return $0.element.endMs < $1.element.endMs
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }
}

/// One decrypted `capture_events` row, shape-agnostic. The adapter decodes the payload; this
/// module never sees JSON.
public struct TimelineRawEvent: Sendable, Equatable {
    public let kind: CaptureEventKind
    /// Bundle identifier of the app that emitted the event. An event belongs only to a visit with
    /// this same bundle identifier when one is available.
    public let appBundle: String?
    public let atMs: EpochMs
    public let threadID: String?
    public let trigger: CaptureTrigger
    /// `kind == .contentDelta` only.
    public let delta: CaptureDelta?
    /// `kind == .typing` only.
    public let typing: TypingEvent?
    /// `kind == .navigation` only.
    public let toURL: String?

    public init(kind: CaptureEventKind, atMs: EpochMs, threadID: String?,
                trigger: CaptureTrigger, delta: CaptureDelta?, typing: TypingEvent?, toURL: String?,
                appBundle: String? = nil) {
        self.kind = kind
        self.appBundle = appBundle
        self.atMs = atMs
        self.threadID = threadID
        self.trigger = trigger
        self.delta = delta
        self.typing = typing
        self.toURL = toURL
    }
}

/// Per-thread metadata from `threads` + `latest_contexts`.
public struct TimelineThreadMeta: Sendable, Equatable {
    public let sourceApp: String
    public let sourceTitle: String?
    public let kind: CaptureContentKind
    public let url: String?
    public let cwd: String?

    public init(sourceApp: String, sourceTitle: String?, kind: CaptureContentKind,
                url: String?, cwd: String?) {
        self.sourceApp = sourceApp
        self.sourceTitle = sourceTitle
        self.kind = kind
        self.url = url
        self.cwd = cwd
    }
}

/// `MaxMiActivity` depends only on `MaxMiCore`, so the database is reached through this protocol
/// and never directly — the same pattern `ActivitySummaryRepository` and `AgentRepository` use.
public protocol TimelineRepository: Sendable {
    func appVisits(fromMs: EpochMs, toMs: EpochMs)
        throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)]
    func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [TimelineRawEvent]
    func threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta]
}

/// Deterministic: the same rows always produce the same timeline and the same text.
public struct TimelineBuilder: Sendable {
    public static let deltaSummaryCap = 200
    public static let typedSampleCap = 120
    public static let urlCap = 60
    public static let omissionLine = "(earlier activity omitted)"

    private let repo: any TimelineRepository

    public init(repo: any TimelineRepository) {
        self.repo = repo
    }

    /// Every visit in the window becomes one or more chronological entries — a focused app with
    /// no capture events is still activity — and every event is attached only to the visit with
    /// the same bundle whose span contains it. A visit is split whenever its event stream changes
    /// thread, so deltas and titles cannot be attributed to a different tab/chat in the same app.
    /// Adjacent entries of the same bundle and thread (or, when neither has a thread, the same
    /// bundle) are coalesced.
    ///
    /// Visits never overlap in practice: `AppWiring.handleFocusChange` closes all open visits
    /// before opening one. An event inside two overlapping visits would be attached to both,
    /// which is the honest answer for a state that cannot occur.
    public func build(fromMs: EpochMs, toMs: EpochMs) throws -> ActivityTimeline {
        let visits = (try repo.appVisits(fromMs: fromMs, toMs: toMs)).enumerated().sorted {
            if $0.element.startedAt != $1.element.startedAt {
                return $0.element.startedAt < $1.element.startedAt
            }
            let leftEndMs = $0.element.endedAt ?? toMs
            let rightEndMs = $1.element.endedAt ?? toMs
            if leftEndMs != rightEndMs {
                return leftEndMs < rightEndMs
            }
            if $0.element.bundleID != $1.element.bundleID {
                return $0.element.bundleID < $1.element.bundleID
            }
            return $0.offset < $1.offset
        }.map(\.element)
        let events = Self.stablySorted(try repo.captureEvents(fromMs: fromMs, toMs: toMs)) {
            $0.atMs
        }
        let metadata = try repo.threadMetadata(
            threadIDs: Array(Set(events.compactMap(\.threadID))).sorted())

        let raw = visits.flatMap { visit -> [BuiltEntry] in
            // An open visit runs to the end of the window, not to "now": a timeline must not
            // depend on when it was rendered.
            let endMs = visit.endedAt ?? toMs
            let visitEvents = events.filter {
                ($0.appBundle == nil || $0.appBundle == visit.bundleID)
                    && $0.atMs >= visit.startedAt
                    && $0.atMs <= endMs
            }
            let segments = Self.threadSegments(visitEvents)
            guard !segments.isEmpty else {
                return [
                    BuiltEntry(
                        bundleID: visit.bundleID,
                        entry: Self.entry(
                            appLabel: visit.appLabel, startMs: visit.startedAt, endMs: endMs,
                            events: [], metadata: metadata
                        )
                    ),
                ]
            }
            return segments.enumerated().map { index, segment in
                let startMs = index == 0 ? visit.startedAt : segment.events[0].atMs
                let segmentEndMs = index + 1 < segments.count
                    ? segments[index + 1].events[0].atMs
                    : endMs
                return BuiltEntry(
                    bundleID: visit.bundleID,
                    entry: Self.entry(
                        appLabel: visit.appLabel,
                        startMs: startMs,
                        endMs: segmentEndMs,
                        events: segment.events,
                        metadata: metadata
                    )
                )
            }
        }
        let entries = Self.stablySorted(Self.coalesce(raw)) { $0.startMs }
        return ActivityTimeline(fromMs: fromMs, toMs: toMs, entries: entries)
    }

    static func stablySorted<T>(_ values: [T], startMs: (T) -> EpochMs) -> [T] {
        values.enumerated().sorted {
            if startMs($0.element) != startMs($1.element) {
                return startMs($0.element) < startMs($1.element)
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    /// A built entry plus the bundle id it came from. `TimelineEntry`'s field list is pinned by
    /// spec 5d and carries no bundle id, but coalescing requires exact bundle identity for every
    /// pair, so it rides alongside and is dropped as soon as coalescing is done.
    struct BuiltEntry: Equatable {
        let bundleID: String
        let entry: TimelineEntry
    }

    /// Consecutive events with one thread identity form one segment. `nil` is a real identity:
    /// focus-only activity stays threadless rather than inheriting a neighbouring tab's title.
    struct ThreadSegment {
        var threadID: String?
        var events: [TimelineRawEvent]
    }

    static func threadSegments(_ events: [TimelineRawEvent]) -> [ThreadSegment] {
        var segments: [ThreadSegment] = []
        for event in events {
            if let last = segments.last, last.threadID == event.threadID {
                segments[segments.count - 1].events.append(event)
            } else {
                segments.append(ThreadSegment(threadID: event.threadID, events: [event]))
            }
        }
        return segments
    }

    static func entry(appLabel: String, startMs: EpochMs, endMs: EpochMs,
                      events: [TimelineRawEvent],
                      metadata: [String: TimelineThreadMeta]) -> TimelineEntry {
        let threadID = events.compactMap(\.threadID).first
        let meta = threadID.flatMap { metadata[$0] }
        let deltas = events.compactMap(\.delta)
        let typings = events.compactMap(\.typing)
        return TimelineEntry(
            startMs: startMs,
            endMs: endMs,
            appLabel: appLabel,
            threadID: threadID,
            sourceTitle: meta?.sourceTitle,
            url: meta?.url,
            kind: meta?.kind ?? .generic,
            cwd: meta?.cwd,
            deltaSummary: deltas.last.flatMap(summary(of:)),
            newItemCount: deltas.reduce(0) { $0 + itemCount(of: $1) },
            typedCount: typings.count,
            typedSample: typings.last.map { String($0.insertedText.prefix(typedSampleCap)) }
        )
    }

    static func itemCount(of delta: CaptureDelta) -> Int {
        delta.addedMessages.count + delta.addedBlocks.count + delta.addedSegments.count
    }

    /// Rendered added content, flattened to one line and capped.
    static func summary(of delta: CaptureDelta) -> String? {
        let flattened = CaptureDeltaRenderer.render(delta, maxChars: deltaSummaryCap)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.isEmpty ? nil : flattened
    }

    static func coalesce(_ built: [BuiltEntry]) -> [TimelineEntry] {
        var out: [BuiltEntry] = []
        for candidate in built {
            guard let previous = out.last, mergeable(previous, candidate) else {
                out.append(candidate)
                continue
            }
            // `mergeable` requires equal bundle IDs, so either bundle ID is valid for the merged
            // entry.
            out[out.count - 1] = BuiltEntry(bundleID: candidate.bundleID,
                                            entry: merge(previous.entry, candidate.entry))
        }
        return out.map(\.entry)
    }

    /// Entries must have the same bundle. Within one bundle, they merge for the same thread or,
    /// when NEITHER has a thread, for the same app visit. A threadless entry never absorbs a
    /// threaded one: "the user was in the editor" and "the user edited this document" are
    /// different facts.
    ///
    /// The bundle id, not `appLabel`: `activity_app_visits` stores the pair per visit, not 1:1
    /// across apps, so two bundles can present one display name and must stay two entries
    /// (spec 5d).
    static func mergeable(_ lhs: BuiltEntry, _ rhs: BuiltEntry) -> Bool {
        guard lhs.bundleID == rhs.bundleID else { return false }
        if let left = lhs.entry.threadID, let right = rhs.entry.threadID { return left == right }
        if lhs.entry.threadID == nil, rhs.entry.threadID == nil {
            return true
        }
        return false
    }

    /// The later entry wins every single-valued field: a timeline reports the latest state of a
    /// stretch, not its first observation. Counts add.
    static func merge(_ lhs: TimelineEntry, _ rhs: TimelineEntry) -> TimelineEntry {
        TimelineEntry(
            startMs: min(lhs.startMs, rhs.startMs),
            endMs: max(lhs.endMs, rhs.endMs),
            appLabel: rhs.appLabel,
            threadID: rhs.threadID ?? lhs.threadID,
            sourceTitle: rhs.sourceTitle ?? lhs.sourceTitle,
            url: rhs.url ?? lhs.url,
            kind: rhs.threadID != nil ? rhs.kind : lhs.kind,
            cwd: rhs.cwd ?? lhs.cwd,
            deltaSummary: rhs.deltaSummary ?? lhs.deltaSummary,
            newItemCount: lhs.newItemCount + rhs.newItemCount,
            typedCount: lhs.typedCount + rhs.typedCount,
            typedSample: rhs.typedSample ?? lhs.typedSample
        )
    }

    // MARK: - Rendering

    /// One line per entry, chronological. When `budgetChars` is exceeded, whole entries are
    /// dropped OLDEST first and `omissionLine` is prepended. The last remaining entry is never
    /// dropped: an over-budget single entry is still reported, the same soft-cap rule Phase A's
    /// budgeting applies to a page's first block.
    public static func render(_ timeline: ActivityTimeline, budgetChars: Int) -> String {
        var lines = timeline.entries.map(line)
        guard !lines.isEmpty else { return "" }
        var omitted = false
        while lines.count > 1, joined(lines, omitted: omitted).count > max(0, budgetChars) {
            lines.removeFirst()
            omitted = true
        }
        return joined(lines, omitted: omitted)
    }

    static func joined(_ lines: [String], omitted: Bool) -> String {
        (omitted ? [omissionLine] + lines : lines).joined(separator: "\n")
    }

    /// `"HH:mm–HH:mm <app>"`, then the terminal's cwd or the quoted source title, then the
    /// truncated url, then `": "` and the semicolon-joined facts. Absent parts are omitted, and
    /// an entry with no facts is just its head.
    static func line(_ entry: TimelineEntry) -> String {
        var head = "\(hhmm(entry.startMs))–\(hhmm(entry.endMs)) \(entry.appLabel)"
        if entry.kind == .terminal {
            head += entry.cwd.map { " (terminal \($0))" } ?? " (terminal)"
        } else if let title = entry.sourceTitle, !title.isEmpty {
            head += " \"\(title)\""
        }
        if let url = entry.url, !url.isEmpty {
            head += " (\(String(url.prefix(urlCap))))"
        }
        var facts: [String] = []
        if let summary = entry.deltaSummary, !summary.isEmpty { facts.append(summary) }
        if entry.newItemCount > 0 {
            facts.append("new since last: \(entry.newItemCount) \(unit(for: entry.kind))")
        }
        if entry.typedCount > 0 {
            var typed = "typed \(entry.typedCount) edits"
            if let sample = entry.typedSample, !sample.isEmpty { typed += " \"\(sample)\"" }
            facts.append(typed)
        }
        return facts.isEmpty ? head : head + ": " + facts.joined(separator: "; ")
    }

    /// Fixed plurals. A rendered line has to be byte-stable across locales and counts, so there is
    /// no pluralisation and no localisation here.
    static func unit(for kind: CaptureContentKind) -> String {
        switch kind {
        case .conversation, .email: return "msgs"
        case .terminal:             return "segments"
        case .task, .calendar:      return "rows"
        default:                    return "paragraphs"
        }
    }

    static func hhmm(_ ms: EpochMs) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// `DateFormatter` is thread-safe for formatting on macOS, and a timeline can carry hundreds
    /// of entries — the same reasoning `ContentRenderer.timestampFormatter` records.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
