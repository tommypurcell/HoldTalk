import XCTest
@testable import HoldTalkKit

/// Only the decision is tested here, so nothing is ever pasted into another app.
@MainActor
final class TextInserterTests: XCTestCase {
    private func space(_ before: TextInserter.TextBefore, _ text: String = "Next sentence.", recent: Bool = false) -> Bool {
        TextInserter.needsSpace(before: before, adding: text, recentlyPastedHere: recent)
    }

    func testAddsASpaceAfterTextSoDictationsDontRunTogether() {
        XCTAssertTrue(space(.character(".")))
        XCTAssertTrue(space(.character("k")))
        XCTAssertTrue(space(.character("7")))
    }

    func testNeverDoublesASpaceOrIndentsANewLine() {
        XCTAssertFalse(space(.character(" ")))
        XCTAssertFalse(space(.character("\n")))
        XCTAssertFalse(space(.character("\t")))
    }

    func testNoSpaceAtTheStartOfAField() {
        XCTAssertFalse(space(.startOfField))
        XCTAssertFalse(space(.startOfField, recent: true), "A known empty field beats the last paste")
    }

    func testNoSpaceAfterAnOpeningBracketOrQuote() {
        for character: Character in ["(", "[", "{", "\"", "'", "“", "‘"] {
            XCTAssertFalse(space(.character(character)), String(character))
        }
    }

    func testNoSpaceBeforePunctuation() {
        XCTAssertFalse(space(.character("k"), ", and then"))
        XCTAssertFalse(space(.character("k"), "."))
        XCTAssertFalse(space(.unknown, "?", recent: true))
    }

    func testAppsThatWontShareTheCursorUseTheLastPaste() {
        XCTAssertTrue(space(.unknown, recent: true))
        XCTAssertFalse(space(.unknown, recent: false))
    }
}
