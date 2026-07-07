import XCTest
@testable import MaxMiStore
import MaxMiCore

final class VectorIndexTests: XCTestCase {
    func unit(_ hotIndex: Int) -> [Float] {
        var v = [Float](repeating: 0.001, count: 1536); v[hotIndex] = 1.0; return v
    }
    func testInsertAndNearestRoundTrip() throws {
        let db = try MaxMiDatabase.inMemory()
        let store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
        try store.insertEmbedding(derivativeID: "d-a", vector: unit(0))
        try store.insertEmbedding(derivativeID: "d-b", vector: unit(500))
        try store.insertEmbedding(derivativeID: "d-c", vector: unit(1000))
        let hits = try store.nearestDerivatives(to: unit(500), limit: 2)
        XCTAssertEqual(hits.first?.derivativeID, "d-b")
        XCTAssertEqual(hits.count, 2)
        XCTAssertLessThan(hits[0].distance, hits[1].distance)
    }
    func testDimensionMismatchThrows() throws {
        let store = Store(db: try MaxMiDatabase.inMemory(), cipher: AESGCMFieldCipher.testCipher)
        XCTAssertThrowsError(try store.insertEmbedding(derivativeID: "d-x", vector: [1, 2, 3]))
    }
}
