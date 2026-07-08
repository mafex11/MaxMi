import XCTest
@testable import MaxMiCapture

final class DocumentExtractionTests: XCTestCase {
    func n(_ role: String, _ value: String? = nil, _ x: CGFloat = 0, _ y: CGFloat = 0, _ kids: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: nil, url: nil,
               frame: CGRect(x: x, y: y, width: 10, height: 10), focused: false, children: kids)
    }
    func testCollectsTextAreaAndStaticTextInVisualOrder() {
        let root = n("AXGroup", nil, 0, 0, [
            n("AXStaticText", "second", 0, 100),
            n("AXTextArea", "first", 0, 10),
            n("AXStaticText", "third", 0, 200),
        ])
        XCTAssertEqual(DocumentExtraction.bodyText(in: root), "first\nsecond\nthird")
    }
    func testEmptyWhenNoText() {
        XCTAssertEqual(DocumentExtraction.bodyText(in: n("AXGroup", nil, 0, 0, [n("AXButton")])), "")
    }
    func testHardCapNewestAnchored() {
        // 400 lines of ~50 chars each, oldest y=0..newest y=399
        var kids: [AXNode] = []
        for i in 0..<400 { kids.append(n("AXStaticText", "line \(i) " + String(repeating: "x", count: 40), 0, CGFloat(i))) }
        let out = DocumentExtraction.bodyText(in: n("AXGroup", nil, 0, 0, kids))
        XCTAssertLessThanOrEqual(out.count, 8000)
        XCTAssertTrue(out.contains("line 399"), "newest kept")
        XCTAssertFalse(out.contains("line 0 "), "oldest dropped")
    }
}
