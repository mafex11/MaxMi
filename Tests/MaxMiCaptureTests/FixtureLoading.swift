import XCTest
import MaxMiCore
@testable import MaxMiCapture

private struct FixtureLoadingError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// The one AX fixture loader. Spec §7d names six duplicates; this branch also had Task 1's copy
/// and a private ComposerDraftTests copy — all fourteen are deleted in favour of this function.
func fixture(_ name: String) throws -> AXNode {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json",
                                      subdirectory: "Fixtures") else {
        throw FixtureLoadingError(message: "missing fixture Fixtures/\(name).json")
    }
    return try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
}

/// A golden `CapturedContent`, stored as a `CapturedContentEnvelope` JSON string so the file on
/// disk is exactly what the store would persist.
func goldenCapturedContent(_ name: String) throws -> CapturedContent {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json",
                                      subdirectory: "Fixtures") else {
        throw FixtureLoadingError(message: "missing golden Fixtures/\(name).json")
    }
    let json = try String(contentsOf: url, encoding: .utf8)
    guard let content = CapturedContentEnvelope.decode(json) else {
        throw FixtureLoadingError(
            message: "Fixtures/\(name).json is not a CapturedContentEnvelope"
        )
    }
    return content
}

/// Deterministic bytes for a `CapturedContent`, for writing a golden the first time:
/// `print(try goldenJSON(content))`, hand-scrub it, then save it as the golden file.
func goldenJSON(_ content: CapturedContent) throws -> String {
    try CapturedContentEnvelope.encode(content)
}

func assertGolden(
    _ content: CapturedContent,
    matches name: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let expected = try goldenCapturedContent(name)
        XCTAssertEqual(content, expected, "golden \(name) mismatch", file: file, line: line)
        if content != expected {
            // Printed on failure only, so a drifting parser is one copy-paste away from a fix.
            print("--- actual \(name) ---\n\((try? goldenJSON(content)) ?? "<unencodable>")")
        }
    } catch {
        XCTFail("golden \(name) unavailable: \(error)", file: file, line: line)
    }
}
