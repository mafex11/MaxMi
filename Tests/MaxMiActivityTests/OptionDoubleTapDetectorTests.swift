import XCTest
@testable import MaxMiActivity
import MaxMiCore

final class OptionDoubleTapDetectorTests: XCTestCase {
    func testTwoFastTapsFireOnce() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_100)))
        XCTAssertFalse(detector.consume(.optionDown(1_300)))
        XCTAssertTrue(detector.consume(.optionUp(1_350)))
        XCTAssertFalse(detector.consume(.optionUp(1_360)))
    }

    func testSecondDownAtFortyMillisecondsFires() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_020)))
        XCTAssertFalse(detector.consume(.optionDown(1_040)))
        XCTAssertTrue(detector.consume(.optionUp(1_060)))
    }

    func testSecondDownAtThirtyNineMillisecondsDoesNotFire() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_020)))
        XCTAssertFalse(detector.consume(.optionDown(1_039)))
        XCTAssertFalse(detector.consume(.optionUp(1_059)))
    }

    func testSecondDownAtThreeHundredFiftyOneMillisecondsDoesNotFire() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_100)))
        XCTAssertFalse(detector.consume(.optionDown(1_351)))
        XCTAssertFalse(detector.consume(.optionUp(1_400)))
    }

    func testHoldLongerThanTwoHundredFiftyMillisecondsIsNotATap() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_251)))
        XCTAssertFalse(detector.consume(.optionDown(1_500)))
        XCTAssertFalse(detector.consume(.optionUp(1_550)))
    }

    func testOtherModifierResetsTheDetector() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.otherKeyOrModifier(1_050)))
        XCTAssertFalse(detector.consume(.optionUp(1_100)))
        XCTAssertFalse(detector.consume(.optionDown(1_200)))
        XCTAssertFalse(detector.consume(.optionUp(1_250)))
    }

    func testThreeTapsFireOnceThenReset() {
        var detector = OptionDoubleTapDetector()

        XCTAssertFalse(detector.consume(.optionDown(1_000)))
        XCTAssertFalse(detector.consume(.optionUp(1_050)))
        XCTAssertFalse(detector.consume(.optionDown(1_200)))
        XCTAssertTrue(detector.consume(.optionUp(1_250)))
        XCTAssertFalse(detector.consume(.optionDown(1_400)))
        XCTAssertFalse(detector.consume(.optionUp(1_450)))
    }
}
