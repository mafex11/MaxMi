import XCTest
@testable import MaxMiCore

final class EnvConfigTests: XCTestCase {
    func write(_ s: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(".env")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
        return u
    }
    func testParsesKeysCommentsAndQuotes() throws {
        let u = try write("""
        # comment
        GEMINI_API_KEY="abc123"
        MAXMI_EMBED_DIMS=768

        MAXMI_EXTRACT_MODEL=gemini-2.5-flash-lite
        """)
        let c = EnvConfig.load(searchPaths: [u])
        XCTAssertEqual(c.geminiAPIKey, "abc123")
        XCTAssertEqual(c.embedDims, 768)
        XCTAssertEqual(c.extractModel, "gemini-2.5-flash-lite")
        XCTAssertEqual(c.embedModel, "gemini-embedding-001") // default survives
    }
    func testMissingFileYieldsDefaultsAndNilKey() {
        let c = EnvConfig.load(searchPaths: [URL(fileURLWithPath: "/nonexistent/.env")])
        XCTAssertNil(c.geminiAPIKey)
        XCTAssertEqual(c.embedDims, 1536)
        XCTAssertEqual(c.extractModel, "gemini-flash-lite-latest")
    }
    func testFirstExistingPathWins() throws {
        let a = try write("GEMINI_API_KEY=first")
        let b = try write("GEMINI_API_KEY=second")
        XCTAssertEqual(EnvConfig.load(searchPaths: [a, b]).geminiAPIKey, "first")
    }
    func testEmptyValueTreatedAsAbsent() throws {
        let u = try write("GEMINI_API_KEY=")
        let c = EnvConfig.load(searchPaths: [u])
        XCTAssertNil(c.geminiAPIKey, "empty-string value yields nil")
    }
    func testHostedRelayConfigurationIsLoadedWithoutProviderKey() throws {
        let u = try write("MAXMI_RELAY_URL=https://relay.example.test\nMAXMI_RELAY_TOKEN=install-token-1234")
        let c = EnvConfig.load(searchPaths: [u])
        XCTAssertEqual(c.relayURL?.absoluteString, "https://relay.example.test")
        XCTAssertEqual(c.relayToken, "install-token-1234")
        XCTAssertTrue(c.usesHostedRelay)
        XCTAssertTrue(c.aiServiceConfigured)
        XCTAssertNil(c.geminiAPIKey)
    }
}
