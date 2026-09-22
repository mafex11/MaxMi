import AppKit
import XCTest
@testable import MaxMiActivity
import MaxMiCore

final class OptionEventMapperTests: XCTestCase {
    func testMapsOptionStateTransitions() {
        XCTAssertEqual(
            OptionEventMapper.map(flags: [.option], isOptionDown: false, timestampMs: 100),
            .optionDown(100)
        )
        XCTAssertEqual(
            OptionEventMapper.map(flags: [], isOptionDown: true, timestampMs: 150),
            .optionUp(150)
        )
    }

    func testIgnoresDuplicateFlagsChangedState() {
        XCTAssertNil(OptionEventMapper.map(flags: [.option], isOptionDown: true, timestampMs: 100))
        XCTAssertNil(OptionEventMapper.map(flags: [], isOptionDown: false, timestampMs: 100))
    }

    func testOtherModifierFlagsResetTheDetector() {
        for flags: NSEvent.ModifierFlags in [
            [.option, .shift], [.option, .control], [.option, .command], [.option, .function],
        ] {
            XCTAssertEqual(
                OptionEventMapper.map(flags: flags, isOptionDown: true, timestampMs: 100),
                .otherKeyOrModifier(100)
            )
        }
    }
}
