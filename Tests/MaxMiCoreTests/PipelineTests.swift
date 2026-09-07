import XCTest
@testable import MaxMiCore

final class MockStore: MemoryStore, @unchecked Sendable {
    var work: [PipelineVersion] = []
    var contextWork: [PipelineVersion] = []
    var insertedFacts: [String] = []
    var newDerivatives: [PipelineDerivative] = []      // what insertDerivatives returns
    var stillPending: [PipelineDerivative] = []
    var embedded: [String] = []
    var vectors: [String: [Float]] = [:]
    var contextEmbeddingVersionIDs: [String] = []
    var extractedOK: [(String, String)] = []
    var markExtractedResult = true
    var failed: [String] = []
    var retries: [(kind: String, versionID: String?, error: String)] = []
    var due: [(id: String, kind: String, versionID: String?, derivativeID: String?)] = []
    var cleared: [String] = []

    func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PipelineVersion] { work }
    func pendingContextEmbeddingWork(nowMs: EpochMs) throws -> [PipelineVersion] { contextWork }
    func insertDerivatives(versionID: String, threadID: String, facts: [String], nowMs: EpochMs) throws -> [PipelineDerivative] {
        insertedFacts.append(contentsOf: facts); return newDerivatives
    }
    func pendingDerivatives(versionID: String) throws -> [PipelineDerivative] { stillPending }
    func markExtracted(versionID: String, contentHashRead: String) throws -> Bool {
        extractedOK.append((versionID, contentHashRead)); return markExtractedResult
    }
    func markExtractFailed(versionID: String) throws { failed.append(versionID) }
    func markEmbedded(derivativeID: String) throws { embedded.append(derivativeID) }
    func insertEmbedding(derivativeID: String, vector: [Float]) throws { vectors[derivativeID] = vector }
    func insertContextEmbedding(versionID: String, vector: [Float]) throws {
        contextEmbeddingVersionIDs.append(versionID)
    }
    func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws {
        retries.append((kind, versionID, error))
    }
    func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)] { due }
    func clearRetry(id: String) throws { cleared.append(id) }
}

final class MockRelay: MemoryRelay, @unchecked Sendable {
    var extractResult: Result<[String], Error> = .success([])
    var embedResult: Result<[Float], Error> = .success(Array(repeating: 0.1, count: 1536))
    var embedResults: [Result<[Float], Error>] = []
    var extractCalls: [(new: String, previous: String?)] = []
    var extractMetadata: [ExtractMetadata] = []
    var embedCalls: [String] = []
    func extract(
        newContent: String,
        previousContent: String?,
        metadata: ExtractMetadata
    ) async throws -> [String] {
        extractCalls.append((newContent, previousContent))
        extractMetadata.append(metadata)
        return try extractResult.get()
    }
    func embed(text: String) async throws -> [Float] {
        embedCalls.append(text)
        let result = embedResults.isEmpty ? embedResult : embedResults.removeFirst()
        return try result.get()
    }
}

final class PipelineTests: XCTestCase {
    func version(
        _ id: String = "v1",
        content: String = "page text",
        renderedDelta: String = "page delta",
        previousCompactContent: String? = nil,
        compactContent: String? = nil
    ) -> PipelineVersion {
        PipelineVersion(
            id: id,
            threadID: "t1",
            content: content,
            contentHash: "hash1",
            sourceApp: "Web",
            sourceKey: "https://e.com",
            sourceTitle: "Example",
            url: "https://e.com",
            contentKind: .document,
            capturedAt: 1_800_000_000_000,
            renderedDelta: renderedDelta,
            previousCompactContent: previousCompactContent,
            compactContent: compactContent ?? content
        )
    }
    func makeSUT() -> (CapturePipeline, MockStore, MockRelay) {
        let s = MockStore(); let r = MockRelay()
        return (CapturePipeline(store: s, relay: r, clock: { 1_000_000 }), s, r)
    }
    var unitVector: [Float] { Array(repeating: 0.1, count: 1536) }

    func testHappyPathExtractEmbedComplete() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .success(["Fact A.", "Fact B."])
        s.newDerivatives = [.init(id: "d1", content: "Fact A."), .init(id: "d2", content: "Fact B.")]
        await p.tick()
        XCTAssertEqual(s.insertedFacts, ["Fact A.", "Fact B."])
        XCTAssertEqual(r.embedCalls, ["Fact A.", "Fact B."])
        XCTAssertEqual(Set(s.embedded), ["d1", "d2"])
        XCTAssertEqual(s.vectors.count, 2)
        XCTAssertEqual(s.extractedOK.first?.0, "v1")
        XCTAssertEqual(s.extractedOK.first?.1, "hash1", "completes with the hash it READ")
        XCTAssertTrue(s.retries.isEmpty)
    }
    func testPreviousCompactContentPassedAsContext() async {
        let (p, s, r) = makeSUT()
        s.work = [version(previousCompactContent: "old compact text")]
        await p.tick()
        XCTAssertEqual(r.extractCalls.first?.previous, "old compact text")
    }
    func testNetworkErrorEnqueuesRetryNotFailed() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .failure(RelayError.httpStatus(429))
        await p.tick()
        XCTAssertEqual(s.retries.count, 1)
        XCTAssertEqual(s.retries.first?.kind, "extract")
        XCTAssertTrue(s.failed.isEmpty, "retryable != failed")
        XCTAssertTrue(s.extractedOK.isEmpty)
    }
    func testMalformedMarksFailedAndRetries() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .failure(RelayError.malformedResponse("garbage"))
        await p.tick()
        XCTAssertEqual(s.failed, ["v1"])
        XCTAssertEqual(s.retries.count, 1)
    }
    func testEmbedFailureLeavesVersionIncomplete() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .success(["Fact A."])
        s.newDerivatives = [.init(id: "d1", content: "Fact A.")]
        r.embedResult = .failure(RelayError.httpStatus(503))
        await p.tick()
        XCTAssertTrue(s.embedded.isEmpty)
        XCTAssertTrue(s.extractedOK.isEmpty, "version stays pending until derivatives embed")
        XCTAssertEqual(s.retries.count, 1)
    }
    func testDueRetriesAreClearedFirst() async {
        let (p, s, _) = makeSUT()
        s.due = [(id: "r1", kind: "extract", versionID: "v1", derivativeID: nil)]
        await p.tick()
        XCTAssertEqual(s.cleared, ["r1"])
    }
    func testEmptyFactArrayStillCompletes() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        r.extractResult = .success([])
        await p.tick()
        XCTAssertEqual(s.extractedOK.count, 1, "nothing meaningful on page is a valid outcome")
    }
    func testMalformedResponseDoesNotLeakContentIntoRetryQueue() async {
        let (p, s, r) = makeSUT()
        s.work = [version()]
        let sensitivePayload = String(repeating: "x", count: 200)
        r.extractResult = .failure(RelayError.malformedResponse(sensitivePayload))
        await p.tick()
        XCTAssertEqual(s.retries.count, 1)
        let errorStored = s.retries.first?.error ?? ""
        XCTAssertFalse(errorStored.contains(sensitivePayload),
                       "retry error must not contain response payload")
        XCTAssertEqual(errorStored, "malformedResponse", "should be the static kind label")
    }
    func testUnreadableMemoryMarkerSkipsProcessing() async {
        let (p, s, r) = makeSUT()
        let corrupt = version("v-bad", content: "[unreadable memory]")
        s.work = [corrupt]
        await p.tick()
        XCTAssertTrue(r.extractCalls.isEmpty, "should not send corruption marker to relay")
        XCTAssertEqual(s.failed, ["v-bad"], "should be marked as failed to prevent reprocessing")
        XCTAssertTrue(s.extractedOK.isEmpty, "should not be marked as extracted")
    }

    func testPipelineExtractsRenderedDeltaWithPreviousCompactContext() async {
        let (pipeline, store, relay) = makeSUT()
        store.work = [version(
            renderedDelta: "Added database migration.",
            previousCompactContent: "Earlier migration context."
        )]

        await pipeline.tick()

        let calls = await relay.extractCalls
        let metadata = await relay.extractMetadata
        XCTAssertEqual(calls.first?.new, "Added database migration.")
        XCTAssertEqual(calls.first?.previous, "Earlier migration context.")
        XCTAssertEqual(metadata.first?.kind, .document)
    }

    func testOneContextEmbeddingFollowsDerivativeEmbeddingsAndCompletesExtraction() async {
        let (pipeline, store, relay) = makeSUT()
        store.work = [version(compactContent: "A useful captured page that is longer than forty characters.")]
        store.newDerivatives = [.init(id: "d1", content: "Fact.")]

        await pipeline.tick()

        XCTAssertEqual(relay.embedCalls, [
            "Fact.",
            "Web · Example\nA useful captured page that is longer than forty characters.",
        ])
        XCTAssertEqual(store.contextEmbeddingVersionIDs, ["v1"])
        XCTAssertEqual(store.extractedOK.map(\.0), ["v1"])
    }

    func testShortContextContentIsNotEmbeddedOrRetried() async {
        let (pipeline, store, relay) = makeSUT()
        store.work = [version(compactContent: String(repeating: "x", count: 39))]

        await pipeline.tick()

        XCTAssertTrue(store.contextEmbeddingVersionIDs.isEmpty)
        XCTAssertFalse(store.retries.contains { $0.kind == "embed_version" })
        XCTAssertEqual(relay.embedCalls, [])
    }

    func testContextEmbedFailureEnqueuesEmbedVersionButDoesNotFailExtraction() async {
        let (pipeline, store, relay) = makeSUT()
        store.work = [version(compactContent: String(repeating: "x", count: 40))]
        store.newDerivatives = [.init(id: "d1", content: "Fact.")]
        relay.embedResults = [.success(unitVector), .failure(RelayError.httpStatus(429))]

        await pipeline.tick()

        XCTAssertTrue(store.retries.contains { $0.kind == "embed_version" && $0.versionID == "v1" })
        XCTAssertEqual(store.extractedOK.map(\.0), ["v1"])
        XCTAssertTrue(store.failed.isEmpty)
    }

    func testPendingContextEmbeddingWorkEmbedsWithoutExtractingAgain() async {
        let (pipeline, store, relay) = makeSUT()
        store.contextWork = [version(compactContent: String(repeating: "x", count: 40))]

        await pipeline.tick()

        XCTAssertEqual(store.contextEmbeddingVersionIDs, ["v1"])
        XCTAssertTrue(relay.extractCalls.isEmpty)
    }
}
