import Foundation

/// The rules for hold-to-talk, double-tap and Esc, with no audio or UI in it.
///
/// Recording starts the moment the hotkey goes down, to catch the first word.
/// Only on release do we know what the press meant:
///
///   long press               -> hold-to-talk: transcribe on release
///   short tap, then nothing  -> accidental tap: throw the audio away
///   short tap, then a press  -> hands-free: keeps recording until one more tap
///
/// Esc during a recording pauses the mic and offers a short undo window:
/// pressing the hotkey again resumes the same audio (hands-free, so it is
/// finished with one more tap and never by a release), and letting the window
/// run out throws the audio away, as Esc always did.
public struct DictationMachine {
    public enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        case awaitingSecondTap
        case handsFree
        /// Esc was pressed while recording: mic is off, audio kept in memory
        /// for a few seconds in case the undo is wanted.
        case awaitingUndo
        case processing
    }

    public enum Event: Equatable {
        case hotkeyDown(at: TimeInterval)
        case hotkeyUp(at: TimeInterval)
        /// Another key was pressed while a modifier hotkey was down, e.g. fn+arrow.
        case otherKey(at: TimeInterval)
        case escape
        case secondTapTimedOut
        /// The undo window after Esc closed; the audio is now gone.
        case undoWindowTimedOut
        case recordingLimitReached
        case recordingFailed
        case processingFinished
        /// Turned off from the menu, or the Mac is going to sleep.
        case shutDown
    }

    public enum Effect: Equatable {
        case startRecording
        case finishRecording
        case discardRecording
        /// Esc offered an undo: stop capturing, keep the audio in memory.
        case pauseRecording
        /// Undo was chosen: carry on recording into the same audio.
        case resumeRecording
        case cancelProcessing
        case startSecondTapTimer(TimeInterval)
        case cancelSecondTapTimer
        case startUndoTimer(TimeInterval)
        case cancelUndoTimer
    }

    /// A press shorter than this counts as a tap rather than a hold.
    public var tapMaxSeconds: TimeInterval
    /// How long after a tap the second tap can arrive.
    public var doubleTapWindowSeconds: TimeInterval
    /// A key chord this soon after pressing the hotkey means the user wanted the
    /// chord (fn+arrow, right-cmd+C), not dictation.
    public var chordCancelSeconds: TimeInterval
    /// How long after Esc the undo is still possible.
    public var undoWindowSeconds: TimeInterval

    public private(set) var state: State = .idle

    public init(tapMaxSeconds: TimeInterval = 0.25,
                doubleTapWindowSeconds: TimeInterval = 0.35,
                chordCancelSeconds: TimeInterval = 1.0,
                undoWindowSeconds: TimeInterval = 5.0) {
        self.tapMaxSeconds = tapMaxSeconds
        self.doubleTapWindowSeconds = doubleTapWindowSeconds
        self.chordCancelSeconds = chordCancelSeconds
        self.undoWindowSeconds = undoWindowSeconds
    }

    /// True while the mic is capturing. The undo window has the mic off, even
    /// though the recording can still be resumed.
    public var isRecording: Bool {
        switch state {
        case .holding, .awaitingSecondTap, .handsFree: return true
        case .idle, .awaitingUndo, .processing: return false
        }
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .hotkeyDown(let time)):
            state = .holding(since: time)
            return [.startRecording]

        case (.holding(let since), .hotkeyUp(let time)):
            if time - since < tapMaxSeconds {
                state = .awaitingSecondTap
                return [.startSecondTapTimer(doubleTapWindowSeconds)]
            }
            state = .processing
            return [.finishRecording]

        case (.holding(let since), .otherKey(let time)):
            guard time - since < chordCancelSeconds else { return [] }
            state = .idle
            return [.discardRecording]

        case (.awaitingSecondTap, .hotkeyDown):
            state = .handsFree
            return [.cancelSecondTapTimer]

        case (.awaitingSecondTap, .secondTapTimedOut):
            state = .idle
            return [.discardRecording]

        case (.handsFree, .hotkeyDown):
            state = .processing
            return [.finishRecording]

        case (.holding, .recordingLimitReached), (.handsFree, .recordingLimitReached):
            state = .processing
            return [.finishRecording]

        case (.awaitingSecondTap, .recordingLimitReached):
            state = .processing
            return [.cancelSecondTapTimer, .finishRecording]

        case (.holding, .escape), (.handsFree, .escape):
            // Off goes the mic, and a window opens to take the undo back.
            state = .awaitingUndo
            return [.pauseRecording, .startUndoTimer(undoWindowSeconds)]

        case (.awaitingSecondTap, .escape):
            state = .awaitingUndo
            return [.cancelSecondTapTimer, .pauseRecording, .startUndoTimer(undoWindowSeconds)]

        case (.awaitingUndo, .hotkeyDown):
            // The hotkey again during the window takes the undo: the recording
            // resumes hands-free, so one more tap finishes and transcribes it,
            // and a release can never sneak a paste in after Esc.
            state = .handsFree
            return [.cancelUndoTimer, .resumeRecording]

        case (.awaitingUndo, .escape):
            state = .idle
            return [.cancelUndoTimer, .discardRecording]

        case (.awaitingUndo, .undoWindowTimedOut):
            state = .idle
            return [.discardRecording]

        case (.awaitingUndo, .recordingLimitReached):
            // The limit clock keeps running while paused, so the undo window
            // cannot be used to record for longer.
            state = .idle
            return [.cancelUndoTimer, .discardRecording]

        case (.holding, .recordingFailed), (.handsFree, .recordingFailed),
             (.holding, .shutDown), (.handsFree, .shutDown):
            state = .idle
            return [.discardRecording]

        case (.awaitingSecondTap, .recordingFailed),
             (.awaitingSecondTap, .shutDown):
            state = .idle
            return [.cancelSecondTapTimer, .discardRecording]

        case (.awaitingUndo, .recordingFailed), (.awaitingUndo, .shutDown):
            state = .idle
            return [.cancelUndoTimer, .discardRecording]

        case (.processing, .escape), (.processing, .shutDown):
            state = .idle
            return [.cancelProcessing]

        case (.processing, .processingFinished):
            state = .idle
            return []

        default:
            // Everything else is deliberately ignored. For example, the release
            // after a hands-free stop tap, a press while still transcribing, or
            // the release of a key still held during the undo window.
            return []
        }
    }
}
