import XCTest
@testable import MaxMiCore

final class MockStore: MemoryStore, @unchecked Sendable {
    var work: [PipelineVersion] = []
    var insertedFacts: [String] = []
    var newDerivatives: [PipelineDerivative] = []      // what insertDerivatives returns
    var stillPending: [PipelineDerivative] = []
    var embedded: [String] = []
    var vectors: [String: [Float]] = [:]
    var extractedOK: [(String, String)] = []
    var markExtractedResult = true
    var failed: [String] = []
    var retries: [(kind: String, versionID: String?, error: String)] = []
    var due: [(id: String, kind: String, versionID: String?, derivativeID: String?)] = []
    var cleared: [String] = []

    func pendingWork(nowMs: EpochMs, idleThresholdMs: EpochMs) throws -> [PipelineVersion] { work }
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
    func enqueueRetry(kind: String, versionID: String?, derivativeID: String?, error: String, nowMs: EpochMs) throws {
        retries.append((kind, versionID, error))
    }
    func dueRetries(nowMs: EpochMs) throws -> [(id: String, kind: String, versionID: String?, derivativeID: String?)] { due }
    func clearRetry(id: String) throws { cleared.append(id) }
}

final class MockRelay: MemoryRelay, @unchecked Sendable {
    var extractResult: Result<[String], Error> = .success([])
    var embedResult: Result<[Float], Error> = .success(Array(repeating: 0.1, count: 1536))
    var extractCalls: [(new: String, prev: String?)] = []
    var embedCalls: [String] = []
    func extract(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) async throws -> [String] {
        extractCalls.append((newContent, previousContent)); return try extractResult.get()
    }
    func embed(text: String) async throws -> [Float] {
        embedCalls.append(text); return try embedResult.get()
    }
}

final class PipelineTests: XCTestCase {
    func version(_ id: String = "v1", prev: String? = nil) -> PipelineVersion {
        PipelineVersion(id: id, threadID: "t1", content: "page text", contentHash: "hash1",
                        sourceApp: "Web", sourceKey: "https://e.com", previousFrozenContent: prev)
    }
    func makeSUT() -> (CapturePipeline, MockStore, MockRelay) {
        let s = MockStore(); let r = MockRelay()
        return (CapturePipeline(store: s, relay: r, clock: { 1_000_000 }), s, r)
    }

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
    func testPreviousFrozenContentPassedAsBaseline() async {
        let (p, s, r) = makeSUT()
        s.work = [version(prev: "old frozen text")]
        await p.tick()
        XCTAssertEqual(r.extractCalls.first?.prev, "old frozen text")
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
}
