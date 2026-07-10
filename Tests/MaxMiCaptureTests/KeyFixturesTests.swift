import XCTest
@testable import MaxMiCapture

/// Golden fixtures: real-shaped capture samples per app -> assert derived key is clean + stable.
/// Adding a parser? Add a case here proving two varied captures of the SAME entity share one clean key.
final class KeyFixturesTests: XCTestCase {
    func cap(_ app: String, _ key: String) -> ParsedCapture {
        ParsedCapture(sourceApp: app, sourceKey: key, sourceTitle: nil, content: "x")
    }
    // "clean" = lowercased scheme, no whitespace, no trailing punctuation/ellipsis, no file-ext leaf, bounded.
    func assertClean(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(key.isEmpty, "key empty", file: file, line: line)
        XCTAssertFalse(key.contains(" "), "key has whitespace: \(key)", file: file, line: line)
        XCTAssertFalse(key.contains("…"), "key has ellipsis: \(key)", file: file, line: line)
        XCTAssertNil(key.rangeOfCharacter(from: CharacterSet(charactersIn: ")]}")), "key has bracket junk: \(key)", file: file, line: line)
        XCTAssertLessThanOrEqual(key.count, 200, file: file, line: line)
    }

    // Each tuple: (app, [varied raw keys for the SAME entity]) -> must all derive equal + clean.
    func testKeysAreCleanAndStablePerApp() {
        let groups: [(String, [String])] = [
            ("Web", ["https://www.google.com/maps/@13.0,77.7,2550m/data=!3?entry=ttu",
                     "https://www.google.com/maps/@12.9,77.7,2070m/data=!3?entry=ttu"]),
            ("Web", ["https://docs.google.com/document/d/1c2FmyTgJkbfr-TheZE0-GARJivubEj3COWYKs38xiGg/edit?tab=t.6xoj",
                     "https://docs.google.com/document/d/1c2FmyTgJkbfr-TheZE0-GARJivubEj3COWYKs38xiGg/edit?tab=t.p2vx"]),
            // Same cwd, only whitespace noise differs -> one key. (A filename-shaped segment
            // like "maxmi.app)." is build-OUTPUT garbage, NOT a cwd; it correctly coarsens to
            // the app level, so it is asserted separately below, not grouped here.)
            ("Warp", ["terminal:warp/maxmi", "terminal:warp/maxmi  ", "terminal:warp/maxmi/"]),
            ("Slack", ["slack:acme/general", "slack:acme/general"]),
            ("Mail", ["mail:inbox", "mail:inbox"]),
            ("Notion", ["notion:june-lp", "notion:june-lp"]),
        ]
        for (app, keys) in groups {
            let derived = keys.map { ThreadKeyDeriver.derive(cap(app, $0)) }
            for k in derived { assertClean(k) }
            XCTAssertEqual(Set(derived).count, 1, "\(app): varied captures must share ONE key, got \(Set(derived))")
        }
    }

    /// Garbage keys (filename-shaped or bracket-junk segments from pre-prompt-anchored capture)
    /// must coarsen to a clean app-level key — coarse-but-stable, never a fractured file key.
    func testGarbageKeysCoarsenCleanly() {
        for garbage in ["terminal:warp/maxmi.app).", "terminal:warp/inspect2.mjs", "terminal:warp/layer…)"] {
            let k = ThreadKeyDeriver.derive(cap("Warp", garbage))
            assertClean(k)
            XCTAssertFalse(k.contains(".mjs") || k.contains(".app"), "file-ext leaf must be coarsened away: \(k)")
        }
    }
}
