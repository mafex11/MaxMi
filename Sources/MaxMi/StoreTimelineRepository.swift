import Foundation
import MaxMiActivity
import MaxMiCore
import MaxMiStore

/// The concrete `TimelineRepository`. This is the only type that knows both `MaxMiStore` and
/// `MaxMiActivity`, so it also owns the payload JSON decode: `TimelineBuilder` never sees JSON.
///
/// `@unchecked Sendable` for the same reason `StoreActivitySummaryRepository` is: `Store` wraps a
/// GRDB `DatabaseQueue`, which serialises its own access.
struct StoreTimelineRepository: TimelineRepository, @unchecked Sendable {
    let store: Store

    func appVisits(fromMs: EpochMs, toMs: EpochMs)
        throws -> [(bundleID: String, appLabel: String, startedAt: EpochMs, endedAt: EpochMs?)] {
        try store.appVisits(fromMs: fromMs, toMs: toMs).map {
            (bundleID: $0.appBundle, appLabel: $0.appLabel,
             startedAt: $0.startedAtMs, endedAt: $0.endedAtMs)
        }
    }

    /// A payload that cannot be decrypted or decoded is dropped: without a trustworthy payload,
    /// the event cannot contribute safely to a timeline.
    func captureEvents(fromMs: EpochMs, toMs: EpochMs) throws -> [TimelineRawEvent] {
        let decoder = CapturedContentEnvelope.makeDecoder()
        return try store.captureEvents(fromMs: fromMs, toMs: toMs).compactMap { record in
            guard let payloadJSON = record.payloadJSON else { return nil }
            let data = Data(payloadJSON.utf8)

            switch record.kind {
            case .contentDelta:
                guard let delta = try? decoder.decode(CaptureDelta.self, from: data) else {
                    return nil
                }
                return TimelineRawEvent(
                    kind: record.kind, atMs: record.atMs, threadID: record.threadID,
                    trigger: record.trigger, delta: delta, typing: nil, toURL: nil,
                    appBundle: record.appBundle
                )
            case .typing:
                guard let typing = try? decoder.decode(TypingEvent.self, from: data) else {
                    return nil
                }
                return TimelineRawEvent(
                    kind: record.kind, atMs: record.atMs, threadID: record.threadID,
                    trigger: record.trigger, delta: nil, typing: typing, toURL: nil,
                    appBundle: record.appBundle
                )
            case .navigation:
                guard let navigation = try? decoder.decode(NavigationEventPayload.self, from: data) else {
                    return nil
                }
                return TimelineRawEvent(
                    kind: record.kind, atMs: record.atMs, threadID: record.threadID,
                    trigger: record.trigger, delta: nil, typing: nil, toURL: navigation.toURL,
                    appBundle: record.appBundle
                )
            case .focus:
                guard (try? decoder.decode(FocusEventPayload.self, from: data)) != nil else {
                    return nil
                }
            case .dialog:
                guard (try? decoder.decode(DialogEventPayload.self, from: data)) != nil else {
                    return nil
                }
            }

            return TimelineRawEvent(
                kind: record.kind, atMs: record.atMs, threadID: record.threadID,
                trigger: record.trigger, delta: nil, typing: nil, toURL: nil,
                appBundle: record.appBundle
            )
        }
    }

    /// `kind` comes from `latest_contexts.content_kind`, which is authoritative and overridable
    /// (spec 12 Q3) — never from the structured shape. Only `url` and `cwd` are read out of the
    /// shape, because no column carries them.
    func threadMetadata(threadIDs: [String]) throws -> [String: TimelineThreadMeta] {
        try store.latestContextRecords(threadIDs: threadIDs).mapValues { record in
            var url: String?
            var cwd: String?
            switch record.structured {
            case .generic(let page):   url = page.url
            case .document(let value): url = value.url
            case .terminal(let value): cwd = value.cwd
            default:                   break
            }
            return TimelineThreadMeta(
                sourceApp: record.sourceApp,
                sourceTitle: record.sourceTitle,
                kind: record.contentKind,
                url: url,
                cwd: cwd
            )
        }
    }
}
