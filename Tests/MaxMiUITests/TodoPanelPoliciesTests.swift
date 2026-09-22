import CoreGraphics
import XCTest
@testable import MaxMiUI

final class TodoPanelPlacementTests: XCTestCase {
    func testTodoPanelPlacementCentersWithinVisibleScreenFrame() {
        XCTAssertEqual(
            TodoPanelPlacement.centeredFrame(
                panelSize: CGSize(width: 520, height: 400),
                screenVisibleFrame: CGRect(x: 100, y: 40, width: 1_440, height: 900)
            ),
            CGRect(x: 560, y: 290, width: 520, height: 400)
        )
    }
}

final class OutsideClickPolicyTests: XCTestCase {
    func testOutsideClickPolicyClosesOnlyForPointsOutsidePanelFrame() {
        let panelFrame = CGRect(x: 100, y: 200, width: 520, height: 400)

        XCTAssertFalse(
            OutsideClickPolicy.shouldClose(
                clickLocation: CGPoint(x: 300, y: 400),
                panelFrame: panelFrame
            )
        )
        XCTAssertTrue(
            OutsideClickPolicy.shouldClose(
                clickLocation: CGPoint(x: 99, y: 400),
                panelFrame: panelFrame
            )
        )
    }
}
