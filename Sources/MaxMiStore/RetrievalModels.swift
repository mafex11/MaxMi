import Foundation
import MaxMiCore

/// A fixed read boundary plus optional filters shared by read-only retrieval APIs.
/// `endAtMs` is inclusive; callers should set it to their page's stable `as_of` value.
public struct RetrievalFilter: Sendable, Equatable {
    public let sourceApps: [String]
    public let startAtMs: EpochMs?
    public let endAtMs: EpochMs
    public let contentKinds: [CaptureContentKind]

    public init(
        sourceApps: [String] = [],
        startAtMs: EpochMs? = nil,
        endAtMs: EpochMs,
        contentKinds: [CaptureContentKind] = []
    ) {
        self.sourceApps = sourceApps
        self.startAtMs = startAtMs
        self.endAtMs = endAtMs
        self.contentKinds = contentKinds
    }
}

public struct RetrievalPage<Element: Sendable>: Sendable {
    public let records: [Element]
    public let hasMore: Bool

    public init(records: [Element], hasMore: Bool) {
        self.records = records
        self.hasMore = hasMore
    }
}

