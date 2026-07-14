import Foundation

public enum CaptureContentKind: String, Sendable, Codable, CaseIterable {
    case webpage
    case conversation
    case document
    case terminal
    case email
    case generic
}

public enum CaptureAccumulationPolicy: String, Sendable, Codable, CaseIterable {
    /// The new snapshot completely supersedes the previous raw context.
    case replace
    /// Merge ordered line-like items, preserving older and newly revealed items.
    case appendItems
    /// Merge overlapping visible text windows into a bounded rolling document.
    case rollingText
}

public enum OffscreenCaptureMode: String, Sendable, Codable, CaseIterable {
    case visibleOnly
    case accessibilityScroll
}

/// Parser-owned bounds for future off-screen probing and current raw-context retention.
public struct OffscreenCapturePolicy: Sendable, Codable, Equatable {
    public let mode: OffscreenCaptureMode
    public let maxSteps: Int
    public let maxCharacters: Int

    public init(mode: OffscreenCaptureMode, maxSteps: Int, maxCharacters: Int) {
        self.mode = mode
        self.maxSteps = max(0, maxSteps)
        self.maxCharacters = max(1_000, maxCharacters)
    }

    public static func visibleOnly(maxCharacters: Int = 32_000) -> Self {
        Self(mode: .visibleOnly, maxSteps: 0, maxCharacters: maxCharacters)
    }

    public static func accessibilityScroll(maxSteps: Int, maxCharacters: Int = 64_000) -> Self {
        Self(mode: .accessibilityScroll, maxSteps: maxSteps, maxCharacters: maxCharacters)
    }
}

/// Versioned, structured result of one parser pass. Raw content remains encrypted at rest.
public struct CaptureEnvelope: Sendable, Equatable {
    public let sourceApp: String
    public let sourceKey: String
    public let sourceTitle: String?
    public let content: String
    public let contentKind: CaptureContentKind
    public let parserID: String
    public let parserVersion: Int
    public let accumulationPolicy: CaptureAccumulationPolicy
    public let offscreenPolicy: OffscreenCapturePolicy
    public let trigger: CaptureTrigger
    public let truncated: Bool

    public init(
        sourceApp: String,
        sourceKey: String,
        sourceTitle: String?,
        content: String,
        contentKind: CaptureContentKind,
        parserID: String,
        parserVersion: Int,
        accumulationPolicy: CaptureAccumulationPolicy,
        offscreenPolicy: OffscreenCapturePolicy,
        trigger: CaptureTrigger,
        truncated: Bool
    ) {
        self.sourceApp = sourceApp
        self.sourceKey = sourceKey
        self.sourceTitle = sourceTitle
        self.content = content
        self.contentKind = contentKind
        self.parserID = parserID
        self.parserVersion = max(1, parserVersion)
        self.accumulationPolicy = accumulationPolicy
        self.offscreenPolicy = offscreenPolicy
        self.trigger = trigger
        self.truncated = truncated
    }

    public static func legacy(
        sourceApp: String,
        sourceKey: String,
        sourceTitle: String?,
        content: String
    ) -> Self {
        Self(
            sourceApp: sourceApp,
            sourceKey: sourceKey,
            sourceTitle: sourceTitle,
            content: content,
            contentKind: .generic,
            parserID: "legacy",
            parserVersion: 1,
            accumulationPolicy: .replace,
            offscreenPolicy: .visibleOnly(),
            trigger: .unknown,
            truncated: false
        )
    }
}

public struct CaptureAccumulationResult: Sendable, Equatable {
    public let content: String
    public let changed: Bool
    public let addedItemCount: Int
}

/// Pure, deterministic accumulator used before versioning and fact extraction.
public enum CaptureAccumulator {
    public static func merge(
        previous: String?,
        incoming: String,
        policy: CaptureAccumulationPolicy,
        maxCharacters: Int
    ) -> CaptureAccumulationResult {
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = previous?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cap = max(1_000, maxCharacters)

        guard !previous.isEmpty else {
            let bounded = bound(incoming, to: cap)
            return CaptureAccumulationResult(
                content: bounded,
                changed: !bounded.isEmpty,
                addedItemCount: nonemptyLines(bounded).count
            )
        }

        let merged: String
        let added: Int
        switch policy {
        case .replace:
            merged = incoming
            added = incoming == previous ? 0 : nonemptyLines(incoming).count
        case .appendItems:
            let result = mergeItems(previous: previous, incoming: incoming)
            merged = result.content
            added = result.added
        case .rollingText:
            let result = mergeRollingText(previous: previous, incoming: incoming)
            merged = result.content
            added = result.added
        }

        let bounded = bound(merged, to: cap)
        return CaptureAccumulationResult(
            content: bounded,
            changed: bounded != previous,
            addedItemCount: added
        )
    }

    private static func mergeItems(previous: String, incoming: String) -> (content: String, added: Int) {
        let old = nonemptyLines(previous)
        let new = nonemptyLines(incoming)
        guard !new.isEmpty else { return (previous, 0) }
        let oldKeys = old.map(normalize)
        let newKeys = new.map(normalize)

        if contains(haystack: oldKeys, needle: newKeys) { return (previous, 0) }
        if contains(haystack: newKeys, needle: oldKeys) { return (new.joined(separator: "\n"), max(0, new.count - old.count)) }

        let appendOverlap = overlap(left: oldKeys, right: newKeys)
        if appendOverlap > 0 {
            let additions = Array(new.dropFirst(appendOverlap))
            return ((old + additions).joined(separator: "\n"), additions.count)
        }

        let prependOverlap = overlap(left: newKeys, right: oldKeys)
        if prependOverlap > 0 {
            let additions = Array(new.dropLast(prependOverlap))
            return ((additions + old).joined(separator: "\n"), additions.count)
        }

        // Disjoint windows: append only occurrences not already represented. Counting
        // occurrences preserves a newly repeated "yes" while suppressing an identical window.
        var remaining = Dictionary(oldKeys.map { ($0, 1) }, uniquingKeysWith: +)
        var additions: [String] = []
        for (index, key) in newKeys.enumerated() {
            if let count = remaining[key], count > 0 {
                remaining[key] = count - 1
            } else {
                additions.append(new[index])
            }
        }
        guard !additions.isEmpty else { return (previous, 0) }
        return ((old + additions).joined(separator: "\n"), additions.count)
    }

    private static func mergeRollingText(previous: String, incoming: String) -> (content: String, added: Int) {
        let old = nonemptyLines(previous)
        let new = nonemptyLines(incoming)
        guard !new.isEmpty else { return (previous, 0) }
        let oldKeys = old.map(normalize)
        let newKeys = new.map(normalize)
        if contains(haystack: oldKeys, needle: newKeys) { return (previous, 0) }
        if contains(haystack: newKeys, needle: oldKeys) { return (new.joined(separator: "\n"), max(0, new.count - old.count)) }

        let appendOverlap = overlap(left: oldKeys, right: newKeys)
        if appendOverlap > 0 {
            let additions = Array(new.dropFirst(appendOverlap))
            return ((old + additions).joined(separator: "\n"), additions.count)
        }
        let prependOverlap = overlap(left: newKeys, right: oldKeys)
        if prependOverlap > 0 {
            let additions = Array(new.dropLast(prependOverlap))
            return ((additions + old).joined(separator: "\n"), additions.count)
        }
        // A mostly identical full document with edits in the middle is a replacement
        // of the same visible region, not a second off-screen segment. This prevents
        // active editors from concatenating near-duplicate whole-file snapshots.
        if overlapRatio(oldKeys, newKeys) >= 0.6 {
            return (new.joined(separator: "\n"), max(0, new.count - old.count))
        }
        return (previous + "\n\n" + incoming, new.count)
    }

    private static func nonemptyLines(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func contains(haystack: [String], needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    /// Count matching items at the end of `left` and beginning of `right`.
    private static func overlap(left: [String], right: [String]) -> Int {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        for count in stride(from: min(left.count, right.count), through: 1, by: -1) {
            if Array(left.suffix(count)) == Array(right.prefix(count)) { return count }
        }
        return 0
    }

    private static func overlapRatio(_ left: [String], _ right: [String]) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var counts = Dictionary(left.map { ($0, 1) }, uniquingKeysWith: +)
        var shared = 0
        for item in right {
            if let count = counts[item], count > 0 {
                shared += 1
                counts[item] = count - 1
            }
        }
        return Double(shared) / Double(min(left.count, right.count))
    }

    private static func bound(_ content: String, to limit: Int) -> String {
        guard content.count > limit else { return content }
        // Retain the identity-bearing beginning and the more recent tail.
        let headCount = limit / 3
        let tailCount = limit - headCount - 3
        return String(content.prefix(headCount)) + "\n…\n" + String(content.suffix(tailCount))
    }
}
