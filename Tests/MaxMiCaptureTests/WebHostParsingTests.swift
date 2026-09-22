import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class WebHostParsingTests: XCTestCase {
    func testSecureComposerNeverReturnsItsOwnOrDescendantText() {
        let secret = "secure composer secret"
        let composer = AXNode(
            role: "AXSecureTextField", value: secret, title: nil, url: nil,
            frame: CGRect(x: 0, y: 0, width: 500, height: 80), focused: false,
            children: [
                AXNode(
                    role: "AXStaticText", value: secret, title: nil, url: nil,
                    frame: CGRect(x: 0, y: 0, width: 300, height: 16), focused: false,
                    children: []
                ),
            ],
            identifier: nil, label: secret, subrole: "CustomSecureComposer",
            headingLevel: nil, selected: false, placeholder: nil, selectedText: secret,
            hidden: false, domClassList: nil, domIdentifier: nil
        )

        XCTAssertNil(WebHostParsing.text(of: composer))
        XCTAssertEqual(WebHostParsing.editorText(in: composer), "")
        XCTAssertNil(WebHostParsing.draft(in: composer))
    }
}
