import XCTest
@testable import MaxMiUI

final class CapturePrivacyCopyTests: XCTestCase {
    /// MaxMi's only unasked deletion is stated in the UI, verbatim (spec 5b, 12 Q5).
    func testEventRetentionNoteIsExactAndNamesTheWindow() {
        XCTAssertEqual(CapturePrivacyCopy.eventRetentionNote,
                       "Activity events are kept for 30 days.")
    }
}
