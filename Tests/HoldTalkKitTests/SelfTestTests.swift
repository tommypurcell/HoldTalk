import XCTest
@testable import HoldTalkKit

final class SelfTestTests: XCTestCase {
    private func run(_ name: String = "test", matched: Double = 1, fallback: Bool = false) -> SelfTest.Run {
        SelfTest.Run(name: name, seconds: 0.1, matchedWords: matched, usedFallback: fallback, text: "text")
    }

    func testMatchingIgnoresCaseAndPunctuation() {
        XCTAssertEqual(SelfTest.matchedWords(expected: "Send the report.", actual: "send, THE report"), 1)
    }

    func testMatchingCountsMissingAndWrongWords() {
        XCTAssertEqual(SelfTest.matchedWords(expected: "one two three four", actual: "one two five"), 0.5)
        XCTAssertEqual(SelfTest.matchedWords(expected: "one two", actual: ""), 0)
    }

    func testMatchingDoesNotCountARepeatedWordTwice() {
        XCTAssertEqual(SelfTest.matchedWords(expected: "go go", actual: "go"), 0.5)
    }

    func testEmptyExpectedTextNeverPasses() {
        XCTAssertEqual(SelfTest.matchedWords(expected: "", actual: "anything"), 0)
    }

    func testGoodRunsHaveNoFailures() {
        XCTAssertEqual(SelfTest.failures(for: [run(), run(matched: 0.8)]), [])
    }

    func testPoorTranscriptionFails() {
        XCTAssertEqual(SelfTest.failures(for: [run("cli", matched: 0.5)]), ["cli: only 50% of the words matched"])
    }

    func testFallingBackFailsSoServerProblemsArentHidden() {
        XCTAssertEqual(SelfTest.failures(for: [run("server", fallback: true)]),
                       ["server: whisper-server failed and it fell back to whisper-cli"])
    }

    func testReportsEveryPermission() {
        XCTAssertEqual(Set(SelfTest.permissions().keys), ["microphone", "inputMonitoring", "accessibility"])
    }
}
