import XCTest
@testable import MaxMiRelay
import MaxMiCore

final class HostedRelayClientTests: XCTestCase {
    private func config(url: String = "https://relay.example.test", token: String? = "install-token-1234")
        -> EnvConfig
    {
        EnvConfig(
            geminiAPIKey: nil,
            extractModel: "extract-model",
            embedModel: "embed-model",
            embedDims: 3,
            relayURL: URL(string: url),
            relayToken: token
        )
    }

    private func client(maximumRequestBytes: Int = 128 * 1_024) -> HostedRelayClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        return HostedRelayClient(
            config: config(),
            session: URLSession(configuration: sessionConfig),
            maximumRequestBytes: maximumRequestBytes
        )!
    }

    func testGenerateUsesScopedBearerContractAndNeverProviderKeyHeader() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/generate")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer install-token-1234")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-MaxMi-Relay-Protocol"), "1")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            return (200, Data(#"{"text":"summary"}"#.utf8))
        }
        let text = try await client().generateContent(model: "model", prompt: "controlled")
        XCTAssertEqual(text, "summary")
    }

    func testEmbeddingValidatesDimensionsAndNormalizes() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/embed")
            return (200, Data(#"{"values":[2,2,2]}"#.utf8))
        }
        let values = try await client().embed(text: "controlled")
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(sqrt(values.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 0.001)
    }

    func testOversizedRequestFailsBeforeNetwork() async {
        StubProtocol.handler = { _ in
            XCTFail("network must not be called")
            return (500, Data())
        }
        do {
            _ = try await client(maximumRequestBytes: 32)
                .generateContent(model: "model", prompt: String(repeating: "x", count: 128))
            XCTFail("expected requestTooLarge")
        } catch RelayError.requestTooLarge {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPartialOrInsecureHostedConfigurationFailsClosed() async {
        for invalid in [
            config(url: "http://relay.example.test"),
            config(token: nil),
        ] {
            let relay = RelayClientFactory.make(config: invalid)
            do {
                _ = try await relay.embed(text: "controlled")
                XCTFail("expected notConfigured")
            } catch RelayError.notConfigured {
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
    }
}
