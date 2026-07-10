import XCTest
@testable import MaxMiRelay
import MaxMiCore

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GeminiClientTests: XCTestCase {
    func makeClient() -> GeminiClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let env = EnvConfig.load(searchPaths: [])  // defaults; then inject key via copy
        let keyed = EnvConfig(geminiAPIKey: "test-key", extractModel: env.extractModel,
                              embedModel: env.embedModel, embedDims: env.embedDims)
        return GeminiClient(config: keyed, session: URLSession(configuration: cfg))
    }
    func testExtractParsesFactsAndSendsKey() async throws {
        StubProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            XCTAssertTrue(req.url!.path.contains(":generateContent"))
            let resp = #"{"candidates":[{"content":{"parts":[{"text":"[\"Sudhanshu read the MaxMi spec.\"]"}]}}]}"#
            return (200, Data(resp.utf8))
        }
        let facts = try await makeClient().extract(newContent: "spec text", previousContent: nil,
                                                   sourceApp: "Web", sourceKey: "https://x.com")
        XCTAssertEqual(facts, ["Sudhanshu read the MaxMi spec."])
    }
    func testEmbedNormalizes() async throws {
        // 1536 values of 2.0 -> normalized magnitude 1
        let values = Array(repeating: 2.0, count: 1536)
        let json = try JSONSerialization.data(withJSONObject: ["embedding": ["values": values]])
        StubProtocol.handler = { _ in (200, json) }
        let v = try await makeClient().embed(text: "fact")
        XCTAssertEqual(v.count, 1536)
        let mag = sqrt(v.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(mag, 1.0, accuracy: 0.001)
    }
    func testHTTP429Throws() async {
        StubProtocol.handler = { _ in (429, Data()) }
        do {
            _ = try await makeClient().embed(text: "x")
            XCTFail("expected throw")
        } catch let e as RelayError {
            if case .httpStatus(let code) = e {
                XCTAssertEqual(code, 429)
            } else {
                XCTFail("wrong error case \(e)")
            }
        } catch {
            XCTFail("wrong error \(error)")
        }
    }
    func testNoKeyThrowsNotConfigured() async {
        let client = GeminiClient(config: EnvConfig.load(searchPaths: []),
                                  session: .shared)
        do { _ = try await client.embed(text: "x"); XCTFail() }
        catch RelayError.notConfigured {} catch { XCTFail("wrong error \(error)") }
    }
    func testGenerateContentReturnsText() async throws {
        StubProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
            XCTAssertTrue(req.url!.path.contains("gemini-2.5-flash-lite:generateContent"))
            let resp = #"{"candidates":[{"content":{"parts":[{"text":"Worked on the parser"}]}}]}"#
            return (200, Data(resp.utf8))
        }
        let text = try await makeClient().generateContent(model: "gemini-2.5-flash-lite", prompt: "Summarize this")
        XCTAssertEqual(text, "Worked on the parser")
    }
    func testGenerateContent429TriggersBackoffAndRetry() async throws {
        var callCount = 0
        StubProtocol.handler = { req in
            callCount += 1
            if callCount == 1 {
                return (429, Data())
            } else {
                let resp = #"{"candidates":[{"content":{"parts":[{"text":"success"}]}}]}"#
                return (200, Data(resp.utf8))
            }
        }
        let throttle = GeminiThrottle()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let env = EnvConfig.load(searchPaths: [])
        let keyed = EnvConfig(geminiAPIKey: "test-key", extractModel: env.extractModel,
                              embedModel: env.embedModel, embedDims: env.embedDims)
        let client = GeminiClient(config: keyed, session: URLSession(configuration: cfg), throttle: throttle)

        do {
            _ = try await client.generateContent(model: "gemini-2.5-flash-lite", prompt: "test")
            XCTFail("expected 429 to throw")
        } catch let e as RelayError {
            if case .httpStatus(let code) = e {
                XCTAssertEqual(code, 429)
            } else {
                XCTFail("wrong error case \(e)")
            }
        }

        XCTAssertEqual(callCount, 1)

        let text = try await client.generateContent(model: "gemini-2.5-flash-lite", prompt: "test")
        XCTAssertEqual(text, "success")
        XCTAssertEqual(callCount, 2, "retry after backoff should succeed")
    }
}
