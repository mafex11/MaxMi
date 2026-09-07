import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class QueryAPITests: XCTestCase {
    var store: Store!
    var db: MaxMiDatabase!
    let t0 = EpochMs(495_442) * 3_600_000

    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory()
        store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }

    func unit(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0.0, count: 1536); v[hot] = 1.0; return v
    }

    @discardableResult
    func seedThread(url: String, title: String?, facts: [(String, Int)], at: EpochMs) throws -> String {
        guard case .committed(let vid, _, _) = try store.commitCapture(
            CaptureInput(sourceApp: "Web", sourceKey: url, sourceTitle: title, content: "content for \(url)"),
            nowMs: at) else { fatalError() }
        let tid = try db.dbQueue.read { try String.fetchOne($0,
            sql: "SELECT thread_id FROM versions WHERE id=?", arguments: [vid])! }
        var when = at
        for (fact, hot) in facts {
            when += 1000
            let inserted = try store.insertDerivatives(versionID: vid, threadID: tid, facts: [fact], nowMs: when)
            try store.insertEmbedding(derivativeID: inserted[0].id, vector: unit(hot))
        }
        return tid
    }

    func testFactHitsJoinsThreadAndOrdersByDistance() throws {
        try seedThread(url: "https://a.com", title: "A", facts: [("Fact near.", 0), ("Fact far.", 900)], at: t0)
        let hits = try store.factHits(near: unit(0), limit: 5)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].content, "Fact near.")
        XCTAssertEqual(hits[0].sourceTitle, "A")
        XCTAssertEqual(hits[0].sourceKey, "https://a.com")
        XCTAssertLessThan(hits[0].distance, hits[1].distance)
    }

    func testFactHitsHonorsLimit() throws {
        try seedThread(url: "https://a.com", title: "A",
                       facts: [("F1.", 1), ("F2.", 2), ("F3.", 3)], at: t0)
        XCTAssertEqual(try store.factHits(near: unit(1), limit: 2).count, 2)
    }

    func testRecentThreadsOrderAndPerThreadFacts() throws {
        try seedThread(url: "https://old.com", title: "Old",
                       facts: [("O1.", 10), ("O2.", 11), ("O3.", 12), ("O4.", 13)], at: t0)
        try seedThread(url: "https://new.com", title: "New", facts: [("N1.", 20)], at: t0 + 60_000)
        let threads = try store.recentThreads(limit: 10)
        XCTAssertEqual(threads.map(\.sourceKey), ["https://new.com", "https://old.com"])
        XCTAssertEqual(threads[1].recentFacts, ["O4.", "O3.", "O2."], "own 3 latest, newest first")
        XCTAssertEqual(threads[0].recentFacts, ["N1."])
    }

    func testZeroFactThreadStillListed() throws {
        _ = try store.commitCapture(CaptureInput(sourceApp: "Web", sourceKey: "https://empty.com",
                                                 sourceTitle: "E", content: "x"), nowMs: t0)
        let threads = try store.recentThreads(limit: 10)
        XCTAssertEqual(threads.count, 1)
        XCTAssertTrue(threads[0].recentFacts.isEmpty)
    }

    func testTotalFactCount() throws {
        try seedThread(url: "https://a.com", title: "A", facts: [("F1.", 1), ("F2.", 2)], at: t0)
        XCTAssertEqual(try store.totalFactCount(), 2)
    }

    func testFactHitsReturnsCosineDistanceNotRawL2() throws {
        // Regression: vec0 table uses L2 distance by default, but the similarity floor
        // and all client code expect cosine distance. Verify the conversion at read boundary.

        // Build unit vector B at known angle to stored vectors:
        // B = [0.6, 0.8, 0, ...] (already normalized: 0.6² + 0.8² = 1.0)
        var b = [Float](repeating: 0.0, count: 1536)
        b[0] = 0.6  // component along axis 0
        b[1] = 0.8  // component along axis 1

        // Store facts with unit vectors along axis 0 and axis 1
        try seedThread(url: "https://test.com", title: "Test",
                       facts: [("Axis-0 fact.", 0), ("Axis-1 fact.", 1)],
                       at: t0)

        // Query with vector B
        let hits = try store.factHits(near: b, limit: 5)
        XCTAssertEqual(hits.count, 2)

        // First hit should be axis-1 (0.8 similarity, 0.2 distance) - CLOSEST
        XCTAssertEqual(hits[0].content, "Axis-1 fact.")
        // dot(B, [0,1,0,...]) = 0.8 → cosine_distance = 1 - 0.8 = 0.2
        XCTAssertEqual(hits[0].distance, 0.2, accuracy: 0.01, "axis-1 component dominates in B")

        // Second hit should be axis-0 (0.6 similarity, 0.4 distance)
        XCTAssertEqual(hits[1].content, "Axis-0 fact.")
        // dot(B, [1,0,0,...]) = 0.6 → cosine_distance = 1 - 0.6 = 0.4
        // If factHits returned raw L2, we'd see L2 = sqrt(2 - 2·0.6) = sqrt(0.8) ≈ 0.894
        XCTAssertEqual(hits[1].distance, 0.4, accuracy: 0.01, "factHits must return cosine distance, not raw L2")

        // Verify ordering: smaller distance comes first
        XCTAssertLessThan(hits[0].distance, hits[1].distance, "results ordered by distance ascending")
    }

    func testContextEmbeddingRoundTrip() throws {
        try store.insertContextEmbedding(versionID: "context-a", vector: unit(0))
        try store.insertContextEmbedding(versionID: "context-b", vector: unit(500))

        let hits = try store.nearestContexts(to: unit(500), limit: 1)

        XCTAssertEqual(hits.map(\.versionID), ["context-b"])
    }

    func testContextHitsConvertL2ToCosineAndRenderCompactSnippetSource() throws {
        let versionID = try seedStructuredVersion(
            sourceApp: "Web",
            sourceKey: "https://context.example",
            title: "Context page",
            content: "A phrase absent from derivatives but present in raw captured context."
        )
        try store.insertContextEmbedding(versionID: versionID, vector: unit(0))
        let hits = try store.contextHits(
            near: unit(0),
            filter: RetrievalFilter(endAtMs: t0 + 1_000),
            limit: 5
        )
        let first = try XCTUnwrap(hits.first)

        XCTAssertEqual(first.distance, 0, accuracy: 0.001)
        XCTAssertEqual(first.sourceTitle, "Context page")
        XCTAssertTrue(first.compactContent.contains("phrase absent from derivatives"))
    }

    func testContextHitsHonorRetrievalFilter() throws {
        let webVersionID = try seedStructuredVersion(
            sourceApp: "Web",
            sourceKey: "https://web-context.example",
            title: "Web context",
            content: "Web raw context.",
            committedAt: t0
        )
        let slackVersionID = try seedStructuredVersion(
            sourceApp: "Slack",
            sourceKey: "slack:context",
            title: "Slack context",
            content: "Slack raw context.",
            committedAt: t0 + 1
        )
        try store.insertContextEmbedding(versionID: webVersionID, vector: unit(1))
        try store.insertContextEmbedding(versionID: slackVersionID, vector: unit(1))

        let hits = try store.contextHits(
            near: unit(1),
            filter: RetrievalFilter(sourceApps: ["slack"], endAtMs: t0 + 1_000),
            limit: 5
        )

        XCTAssertEqual(hits.map(\.versionID), [slackVersionID])
    }

    func testContextHitsExcludeUserBlockedDomain() throws {
        let versionID = try seedStructuredVersion(
            sourceApp: "Web",
            sourceKey: "https://private-context.example",
            title: "Private context",
            content: "Raw context from a user-blocked domain."
        )
        try store.insertContextEmbedding(versionID: versionID, vector: unit(2))
        _ = try store.setDomain("private-context.example", blocked: true, nowMs: t0 + 1)

        let hits = try store.contextHits(
            near: unit(2),
            filter: RetrievalFilter(endAtMs: t0 + 1_000),
            limit: 5
        )

        XCTAssertFalse(hits.map(\.versionID).contains(versionID))
    }

    func testContextHitsExcludePausedThread() throws {
        let sourceKey = "slack:paused-context"
        let versionID = try seedStructuredVersion(
            sourceApp: "Slack",
            sourceKey: sourceKey,
            title: "Paused context",
            content: "Raw context from a paused thread."
        )
        try store.insertContextEmbedding(versionID: versionID, vector: unit(3))
        try store.setThreadPaused(sourceKey, paused: true, nowMs: t0 + 1)

        let hits = try store.contextHits(
            near: unit(3),
            filter: RetrievalFilter(endAtMs: t0 + 1_000),
            limit: 5
        )

        XCTAssertFalse(hits.map(\.versionID).contains(versionID))
    }

    func testContextHitsExcludeLocalOnlySource() throws {
        let versionID = try seedStructuredVersion(
            sourceApp: "Slack",
            sourceKey: "slack:local-context",
            title: "Local context",
            content: "Raw context from a local-only source."
        )
        try store.insertContextEmbedding(versionID: versionID, vector: unit(4))
        try store.setCloudProcessing("Slack", allowed: false, nowMs: t0 + 1)

        let hits = try store.contextHits(
            near: unit(4),
            filter: RetrievalFilter(endAtMs: t0 + 1_000),
            limit: 5
        )

        XCTAssertFalse(hits.map(\.versionID).contains(versionID))
    }

    func testPendingContextEmbeddingWorkUsesLegacyCompactContentAndHonorsMarkerAndBackoff() throws {
        let oldVersionID = try seedContextVersion(
            sourceKey: "fixture:pre-marker",
            content: "Pre-marker synthetic captured content.",
            committedAt: 1
        )
        let legacyContent = "Post-marker synthetic legacy content that is long enough to embed."
        let postVersionID = try seedContextVersion(
            sourceKey: "fixture:post-marker",
            content: legacyContent,
            committedAt: 3
        )
        try store.setContextEmbeddingSinceMs(2)
        try db.dbQueue.write { d in
            try d.execute(
                sql: "UPDATE versions SET structured_ciphertext=NULL WHERE id=?",
                arguments: [postVersionID]
            )
        }

        let initial = try store.pendingContextEmbeddingWork(nowMs: 3)
        let pending = try XCTUnwrap(initial.first { $0.id == postVersionID })
        let expected = ContentRenderer.render(
            LegacyContentAdapter.adapt(renderedContent: legacyContent, kind: .generic),
            style: .compact(maxChars: 6_000)
        )
        XCTAssertEqual(pending.compactContent, expected)
        XCTAssertFalse(initial.map(\.id).contains(oldVersionID))

        try store.enqueueRetry(
            kind: "embed_version",
            versionID: postVersionID,
            derivativeID: nil,
            error: "offline",
            nowMs: 3
        )
        let gated = try store.pendingContextEmbeddingWork(nowMs: 30_002)
        XCTAssertFalse(gated.map(\.id).contains(postVersionID))

        let afterBackoff = try store.pendingContextEmbeddingWork(nowMs: 30_003)
        XCTAssertTrue(afterBackoff.map(\.id).contains(postVersionID))
    }

    func testPendingContextEmbeddingWorkRequiresSourceCloudEligibility() throws {
        let versionID = try seedContextVersion(
            sourceApp: "Slack",
            sourceKey: "slack:fixture",
            content: "Synthetic source content that is long enough for a context embedding.",
            committedAt: t0
        )
        try store.setContextEmbeddingSinceMs(t0 - 1)

        try store.setCloudProcessing("Slack", allowed: false, nowMs: t0 + 1)
        let localOnly = try store.pendingContextEmbeddingWork(nowMs: t0 + 2)
        XCTAssertFalse(localOnly.map(\.id).contains(versionID))

        try store.setCloudProcessing("Slack", allowed: true, nowMs: t0 + 3)
        let approved = try store.pendingContextEmbeddingWork(nowMs: t0 + 4)
        XCTAssertTrue(approved.map(\.id).contains(versionID))

        let gatedEligibility = SourceCloudEligibility(
            reviewedSourceApps: ["Web"],
            localOnlySourceApps: [],
            reviewGateEnabled: true
        )
        XCTAssertFalse(gatedEligibility.allowsCloudProcessing(for: "Slack"))
    }

    private func seedContextVersion(
        sourceApp: String = "FixtureWeb",
        sourceKey: String,
        content: String,
        committedAt: EpochMs
    ) throws -> String {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(
                sourceApp: sourceApp,
                sourceKey: sourceKey,
                sourceTitle: "Fixture",
                content: content
            ),
            nowMs: committedAt
        ) else {
            throw FixtureError.captureDidNotCommit
        }
        return versionID
    }

    private func seedStructuredVersion(
        sourceApp: String,
        sourceKey: String,
        title: String,
        content: String,
        committedAt: EpochMs? = nil
    ) throws -> String {
        guard case .committed(let versionID, _, _) = try store.commitCapture(
            CaptureInput(
                sourceApp: sourceApp,
                sourceKey: sourceKey,
                sourceTitle: title,
                content: content
            ),
            nowMs: committedAt ?? t0
        ) else {
            throw FixtureError.captureDidNotCommit
        }
        return versionID
    }

    private enum FixtureError: Error {
        case captureDidNotCommit
    }
}
