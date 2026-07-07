import Foundation
import GRDB

public enum StoreError: Error {
    case dimensionMismatch(expected: Int, got: Int)
}

extension Store {
    public func insertEmbedding(derivativeID: String, vector: [Float]) throws {
        guard vector.count == 1536 else {
            throw StoreError.dimensionMismatch(expected: 1536, got: vector.count)
        }
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }  // little-endian f32, vec0's raw format
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO derivative_embeddings (derivative_id, embedding) VALUES (?, ?)",
                          arguments: [derivativeID, blob])
        }
    }

    public func nearestDerivatives(to vector: [Float], limit: Int) throws -> [(derivativeID: String, distance: Double)] {
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        return try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT derivative_id, distance FROM derivative_embeddings
                WHERE embedding MATCH ? AND k = ? ORDER BY distance
                """, arguments: [blob, limit])
                .map { ($0["derivative_id"], $0["distance"]) }
        }
    }
}
