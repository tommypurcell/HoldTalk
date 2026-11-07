import XCTest
@testable import HoldTalkKit

final class DictationMachineTests: XCTestCase {
    private var machine = DictationMachine(tapMaxSeconds: 0.25, doubleTapWindowSeconds: 0.35)

    override func setUp() {
        machine = DictationMachine(tapMaxSeconds: 0.25, doubleTapWindowSeconds: 0.35)
    }

    func testLongHoldRecordsThenTranscribesOnRelease() {
        XCTAssertEqual(machine.handle(.hotkeyDown(at: 10)), [.startRecording])
        XCTAssertEqual(machine.state, .holding(since: 10))
        XCTAssertEqual(machine.handle(.hotkeyUp(at: 12)), [.finishRecording])
        XCTAssertEqual(machine.state, .processing)
        XCTAssertEqual(machine.handle(.processingFinished), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testSingleQuickTapIsThrownAway() {
        _ = machine.handle(.hotkeyDown(at: 10))
        XCTAssertEqual(machine.handle(.hotkeyUp(at: 10.1)), [.startSecondTapTimer(0.35)])
        XCTAssertTrue(machine.isRecording)
        XCTAssertEqual(machine.handle(.secondTapTimedOut), [.discardRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testDoubleTapStartsHandsFreeAndOneMoreTapStops() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.hotkeyUp(at: 10.1))
        XCTAssertEqual(machine.handle(.hotkeyDown(at: 10.2)), [.cancelSecondTapTimer])
        XCTAssertEqual(machine.state, .handsFree)

        XCTAssertEqual(machine.handle(.hotkeyUp(at: 10.3)), [], "Releasing the second tap must not stop it")
        XCTAssertEqual(machine.state, .handsFree)

        XCTAssertEqual(machine.handle(.hotkeyDown(at: 40)), [.finishRecording])
        XCTAssertEqual(machine.state, .processing)
        XCTAssertEqual(machine.handle(.hotkeyUp(at: 40.1)), [], "Releasing the stop tap does nothing")
    }

    func testHandsFreeAutoStopsAtLimitAndTranscribes() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.hotkeyUp(at: 10.1))
        _ = machine.handle(.hotkeyDown(at: 10.2))
        XCTAssertEqual(machine.handle(.recordingLimitReached), [.finishRecording])
        XCTAssertEqual(machine.state, .processing)
    }

    func testStuckHoldAlsoStopsAtLimit() {
        _ = machine.handle(.hotkeyDown(at: 10))
        XCTAssertEqual(machine.handle(.recordingLimitReached), [.finishRecording])
        XCTAssertEqual(machine.handle(.hotkeyUp(at: 400)), [], "A late release does nothing")
        XCTAssertEqual(machine.state, .processing)
    }

    func testEscapeDuringHoldOffersUndoThenTimesOut() {
        _ = machine.handle(.hotkeyDown(at: 10))
        XCTAssertEqual(machine.handle(.escape), [.pauseRecording, .startUndoTimer(5.0)])
        XCTAssertEqual(machine.state, .awaitingUndo)
        XCTAssertFalse(machine.isRecording, "The mic is off while undo is offered")
        XCTAssertEqual(machine.handle(.hotkeyUp(at: 11)), [], "Release during the window does nothing")

        XCTAssertEqual(machine.handle(.undoWindowTimedOut), [.discardRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testEscapeDuringAwaitingSecondTapOffersUndo() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.hotkeyUp(at: 10.1))
        XCTAssertEqual(machine.handle(.escape), [.cancelSecondTapTimer, .pauseRecording, .startUndoTimer(5.0)])
        XCTAssertEqual(machine.state, .awaitingUndo)
        XCTAssertEqual(machine.handle(.undoWindowTimedOut), [.discardRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testEscapeDuringHandsFreeOffersUndo() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.hotkeyUp(at: 10.1))
        _ = machine.handle(.hotkeyDown(at: 10.2))
        XCTAssertEqual(machine.handle(.escape), [.pauseRecording, .startUndoTimer(5.0)])
        XCTAssertEqual(machine.state, .awaitingUndo)
    }

    func testUndoResumesHandsFreeAndATapFinishes() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.escape)
        XCTAssertEqual(machine.handle(.hotkeyDown(at: 12)), [.cancelUndoTimer, .resumeRecording])
        XCTAssertEqual(machine.state, .handsFree)
        XCTAssertTrue(machine.isRecording)

        XCTAssertEqual(machine.handle(.hotkeyUp(at: 12.1)), [], "Release after undo must not finish")
        XCTAssertEqual(machine.handle(.hotkeyDown(at: 20)), [.finishRecording])
        XCTAssertEqual(machine.state, .processing)
    }

    func testUndoAfterTapKeepsEarlierAudioAndTranscribesOnStop() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.hotkeyUp(at: 10.1))
        _ = machine.handle(.escape)
        _ = machine.handle(.hotkeyDown(at: 11))
        XCTAssertEqual(machine.state, .handsFree)
        XCTAssertEqual(machine.handle(.hotkeyDown(at: 20)), [.finishRecording])
    }

    func testSecondEscapeDuringUndoWindowDiscardsNow() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.escape)
        XCTAssertEqual(machine.handle(.escape), [.cancelUndoTimer, .discardRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testUndoKeepsTheRecordingLimit() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.escape)
        _ = machine.handle(.hotkeyDown(at: 12))
        XCTAssertEqual(machine.handle(.recordingLimitReached), [.finishRecording])
        XCTAssertEqual(machine.state, .processing)
    }

    func testLimitDuringUndoWindowDiscards() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.escape)
        XCTAssertEqual(machine.handle(.recordingLimitReached), [.cancelUndoTimer, .discardRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testShutDownDuringUndoWindowDiscards() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.escape)
        XCTAssertEqual(machine.handle(.shutDown), [.cancelUndoTimer, .discardRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testMicFailureDuringUndoWindowDiscards() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.escape)
        XCTAssertEqual(machine.handle(.recordingFailed), [.cancelUndoTimer, .discardRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testEscapeKillsRunningTranscription() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.hotkeyUp(at: 12))
        XCTAssertEqual(machine.handle(.escape), [.cancelProcessing])
        XCTAssertEqual(machine.state, .idle)
    }

    func testEscapeWhileIdleDoesNothing() {
        XCTAssertEqual(machine.handle(.escape), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testPressWhileTranscribingIsIgnored() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.hotkeyUp(at: 12))
        XCTAssertEqual(machine.handle(.hotkeyDown(at: 13)), [])
        XCTAssertEqual(machine.handle(.hotkeyUp(at: 14)), [])
        XCTAssertEqual(machine.state, .processing)
    }

    func testLateTimerCannotDropHandsFree() {
        _ = machine.handle(.hotkeyDown(at: 10))
        _ = machine.handle(.hotkeyUp(at: 10.1))
        _ = machine.handle(.hotkeyDown(at: 10.2))
        XCTAssertEqual(machine.handle(.secondTapTimedOut), [])
        XCTAssertEqual(machine.state, .handsFree)
    }

    func testChordSoonAfterPressCancels() {
        _ = machine.handle(.hotkeyDown(at: 10))
        XCTAssertEqual(machine.handle(.otherKey(at: 10.4)), [.discardRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testKeyLongAfterPressKeepsRecording() {
        _ = machine.handle(.hotkeyDown(at: 10))
        XCTAssertEqual(machine.handle(.otherKey(at: 13)), [])
        XCTAssertEqual(machine.state, .holding(since: 10))
    }

    func testMicFailureReturnsToIdle() {
        _ = machine.handle(.hotkeyDown(at: 10))
        XCTAssertEqual(machine.handle(.recordingFailed), [.discardRecording])
        XCTAssertEqual(machine.state, .idle)
    }

    func testShutDownStopsEverything() {
        _ = machine.handle(.hotkeyDown(at: 10))
        XCTAssertEqual(machine.handle(.shutDown), [.discardRecording])
        _ = machine.handle(.hotkeyDown(at: 20))
        _ = machine.handle(.hotkeyUp(at: 22))
        XCTAssertEqual(machine.handle(.shutDown), [.cancelProcessing])
        XCTAssertEqual(machine.state, .idle)
    }
}
